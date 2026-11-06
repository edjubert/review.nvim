import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { copyNotices } from "../scripts/licenses.mjs";
import { copyRuntime, runtimeSources } from "../scripts/runtime.mjs";
import { requireCleanSource, sourceState } from "../scripts/source.mjs";
import { digest, sourceInputs, verifyNativeReceipt } from "../scripts/receipts.mjs";

test("the distributed emoji catalogue retains its exact gemoji license and build watch input", async (t) => {
  const directory = await mkdtemp(join(tmpdir(), "review-notices-"));
  t.after(() => rm(directory, { recursive: true, force: true }));
  await copyRuntime(directory);
  assert.equal(await readFile(join(directory, "LICENSES/gemoji.txt"), "utf8"),
    await readFile(new URL("../../../LICENSES/gemoji.txt", import.meta.url), "utf8"));
  assert.ok((await runtimeSources()).some((path) => path.endsWith("/LICENSES/gemoji.txt")));
});

test("dependency licenses and NOTICE files are copied verbatim; missing licenses fail the build", async (t) => {
  const directory = await mkdtemp(join(tmpdir(), "review-dependency-notices-"));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const dependency = join(directory, "dependency");
  await mkdir(dependency);
  await writeFile(join(dependency, "NOTICE"), "Attribution\n");
  await assert.rejects(copyNotices(dependency, join(directory, "output")), /No distributable license/);
  await writeFile(join(dependency, "LICENSE.md"), "License\n");
  await copyNotices(dependency, join(directory, "output"));
  assert.equal(await readFile(join(directory, "output/NOTICE"), "utf8"), "Attribution\n");
  assert.equal(await readFile(join(directory, "output/LICENSE.md"), "utf8"), "License\n");
});

test("release provenance rejects dirty source, stale runtime, untracked inputs and unavailable Git", async (t) => {
  const directory = await mkdtemp(join(tmpdir(), "review-source-"));
  t.after(() => rm(directory, { recursive: true, force: true }));
  function git(args) {
    const result = spawnSync("git", args, { cwd: directory, encoding: "utf8" });
    assert.equal(result.status, 0, result.stderr);
  }
  assert.throws(() => sourceState(directory), /Git|git/);
  git(["init", "-q"]);
  git(["config", "user.email", "fixture@example.invalid"]);
  git(["config", "user.name", "Fixture"]);
  await writeFile(join(directory, "LICENSE"), "Original\n");
  git(["add", "LICENSE"]);
  git(["-c", "commit.gpgsign=false", "commit", "-qm", "fixture"]);
  const source = sourceState(directory);
  assert.equal(source.modified, false);
  assert.deepEqual(requireCleanSource(directory, source), source);
  assert.throws(() => requireCleanSource(directory, { ...source, commit: "0".repeat(40) }), /rebuilt/);
  assert.throws(() => requireCleanSource(directory, { ...source, modified: true }), /rebuilt/);
  await writeFile(join(directory, "LICENSE"), "Changed\n");
  assert.throws(() => requireCleanSource(directory, source), /clean/);
  git(["restore", "LICENSE"]);
  await writeFile(join(directory, "untracked.lua"), "return {}\n");
  assert.throws(() => requireCleanSource(directory, source), /clean/);
});

test("native qualification cannot be reused for a different target, binary or dependency lock", async (t) => {
  const directory = await mkdtemp(join(tmpdir(), "review-native-receipt-"));
  t.after(() => rm(directory, { recursive: true, force: true }));
  await mkdir(join(directory, "backend"));
  await mkdir(join(directory, "bin/linux-x86_64"), { recursive: true });
  for (const name of ["package.json", "package-lock.json", "backend/go.mod", "backend/go.sum"]) {
    await writeFile(join(directory, name), name + "\n");
  }
  const binary = join(directory, "bin/linux-x86_64/review-nvim");
  await writeFile(binary, "Fixture executable");
  const source = { repository: "https://github.com/edjubert/review.nvim", commit: "a".repeat(40), modified: false };
  const receipt = {
    schema_version: 1, source, target: "linux-x86_64",
    native: { platform: "linux", architecture: "x64" },
    executable: await digest(binary), inputs: await sourceInputs(directory),
    workflow: process.env.GITHUB_RUN_ID ? {
      sha: source.commit,
      url: `https://github.com/${process.env.GITHUB_REPOSITORY}/actions/runs/${process.env.GITHUB_RUN_ID}`,
      attempt: Number(process.env.GITHUB_RUN_ATTEMPT),
    } : null,
  };
  await verifyNativeReceipt(directory, source, "linux-x86_64", receipt);
  await assert.rejects(verifyNativeReceipt(directory, source, "darwin-x86_64", receipt), /native qualification/);
  await assert.rejects(verifyNativeReceipt(directory, { ...source, commit: "b".repeat(40) }, "linux-x86_64", receipt),
    /native qualification/);
  await writeFile(binary, "Changed executable");
  await assert.rejects(verifyNativeReceipt(directory, source, "linux-x86_64", receipt), /does not match/);
  await writeFile(binary, "Fixture executable");
  await writeFile(join(directory, "backend/go.sum"), "Changed dependencies");
  await assert.rejects(verifyNativeReceipt(directory, source, "linux-x86_64", receipt), /does not match/);
});
