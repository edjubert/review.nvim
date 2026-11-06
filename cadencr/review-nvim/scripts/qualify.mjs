import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { cp, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import { digest, platforms, sourceInputs, treeDigests } from "./receipts.mjs";
import { requireCleanSource } from "./source.mjs";

const root = fileURLToPath(new URL("../", import.meta.url));
const repositoryRoot = fileURLToPath(new URL("../../../", import.meta.url));
const target = process.argv[2];
assert.deepEqual(platforms[target], [process.platform, process.arch],
  "Qualification must run natively on the declared target.");
const source = requireCleanSource(repositoryRoot,
  JSON.parse(await readFile(`${root}/dist/runtime/source.json`, "utf8")));
const directory = `${root}/bin/${target}`;
const evidence = `${directory}/evidence`;
await mkdir(evidence, { recursive: true });

function run(program, args, cwd = root) {
  const result = spawnSync(program, args, {
    cwd, encoding: "utf8", timeout: 240_000, maxBuffer: 16 * 1024 * 1024,
  });
  if (result.error) throw result.error;
  process.stdout.write(result.stdout);
  process.stderr.write(result.stderr);
  assert.equal(result.status, 0, `${program} ${args.join(" ")} failed`);
  return result.stdout + result.stderr;
}

const build = run("go", ["version", "-m", `${directory}/review-nvim`]);
assert.ok(build.includes(`vcs.revision=${source.commit}`), "The binary must embed the exact source commit.");
assert.ok(build.includes("vcs.modified=false"), "The binary must come from a clean tree.");
await writeFile(`${evidence}/go-build.txt`, build);

const commands = [
  ["runtime", "npm", ["test"], root],
  ["backend", "go", ["-C", "backend", "test", "-mod=readonly", "-race", "-count=1", "-json", "./..."], root],
  ["lua", process.env.NVIM ?? "nvim", ["--headless", "-u", "NONE", "-i", "NONE", "-l", "tests/run.lua"], repositoryRoot],
  ["browser", "npm", ["run", "test:ui"], root],
];
for (const [name, program, args, cwd] of commands) {
  await writeFile(`${evidence}/${name}.txt`, run(program, args, cwd));
}

// Exercise the compiled executable's protocol, in addition to the source-level
// Go tests and the browser tests that launch this executable with real Neovim.
const state = await mkdtemp(`${tmpdir()}/review-native-`);
try {
  const smoke = spawnSync(`${directory}/review-nvim`, [], {
    encoding: "utf8", timeout: 5000,
    input: [
      JSON.stringify({ type: "hello", protocol: 1, worktree: state, state_dir: state }),
      JSON.stringify({ type: "request", id: 1, method: "qualification.unknown", params: {} }), "",
    ].join("\n"),
  });
  assert.equal(smoke.error, undefined);
  assert.equal(smoke.status, 0, smoke.stderr);
  const [ready, response] = smoke.stdout.trim().split("\n").map((line) => JSON.parse(line));
  assert.deepEqual(ready, { protocol: 1, type: "ready" });
  assert.equal(response.id, 1);
  assert.equal(response.error.code, "METHOD_NOT_FOUND");
  await writeFile(`${evidence}/compiled-protocol.txt`, smoke.stdout);
} finally { await rm(state, { recursive: true, force: true }); }

requireCleanSource(repositoryRoot, source);
await cp(`${root}/dist/LICENSES/go`, `${directory}/notices`, { recursive: true });
await writeFile(`${directory}/build-receipt.json`, JSON.stringify({
  schema_version: 1, source, target,
  native: { platform: process.platform, architecture: process.arch },
  workflow: process.env.GITHUB_RUN_ID ? {
    url: `https://github.com/${process.env.GITHUB_REPOSITORY}/actions/runs/${process.env.GITHUB_RUN_ID}`,
    attempt: Number(process.env.GITHUB_RUN_ATTEMPT),
    ref: process.env.GITHUB_REF,
    sha: process.env.GITHUB_SHA,
  } : null,
  toolchains: {
    node: process.version, npm: run("npm", ["--version"]).trim(),
    go: run("go", ["version"]).trim(), neovim: run(process.env.NVIM ?? "nvim", ["--version"]).trim(),
  },
  inputs: await sourceInputs(root),
  executable: await digest(`${directory}/review-nvim`),
  frontend: await treeDigests(`${root}/dist`),
  tests: commands.map(([name, program, args]) => ({ name, program, args, result: "passed" })),
  evidence: await treeDigests(evidence),
}, null, 2) + "\n");
