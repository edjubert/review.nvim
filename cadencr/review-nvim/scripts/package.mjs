import { spawnSync } from "node:child_process";
import { cp, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { metadata, repository } from "./metadata.mjs";
import { digest, treeDigests, verifyNativeReceipt } from "./receipts.mjs";
import { requireCleanSource } from "./source.mjs";

const root = fileURLToPath(new URL("../", import.meta.url));
const repositoryRoot = fileURLToPath(new URL("../../../", import.meta.url));
const manifest = JSON.parse(await readFile(`${root}/tab.json`, "utf8"));
const releaseTag = `cadencr-v${manifest.version}`;
if (process.env.GITHUB_REF?.startsWith("refs/tags/") &&
    process.env.GITHUB_REF !== `refs/tags/${releaseTag}`) {
  throw new Error(`The release tag must match the manifest version: ${releaseTag}`);
}
const destination = resolve(process.argv[2] ?? `${repositoryRoot}/artifacts/release-${manifest.version}`);
const cli = process.env.CADENCR_CLI ?? "cadencr";
const release = `${repository}/releases/download/${releaseTag}`;
const source = requireCleanSource(repositoryRoot,
  JSON.parse(await readFile(`${root}/dist/runtime/source.json`, "utf8")));
const receipts = {};
for (const target of Object.keys(manifest.backend.binary)) {
  const directory = `${repositoryRoot}/artifacts/native/native-${target}`;
  const receipt = JSON.parse(await readFile(`${directory}/build-receipt.json`, "utf8"));
  await verifyNativeReceipt(root, source, target, receipt);
  if (JSON.stringify(receipt.evidence) !== JSON.stringify(await treeDigests(`${directory}/evidence`))) {
    throw new Error(`Native test evidence was changed for ${target}`);
  }
  receipts[target] = receipt;
}
if (JSON.stringify(receipts["linux-x86_64"].frontend) !== JSON.stringify(await treeDigests(`${root}/dist`))) {
  throw new Error("The frontend must match the natively tested Linux build.");
}
function run(args) {
  const result = spawnSync(cli, args, { encoding: "utf8" });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(result.stderr || result.stdout);
  return result.stdout.trim() ? JSON.parse(result.stdout) : null;
}

// Run conformance before preparing output; packing checks every declared binary.
run(["plugin", "validate", root, "--kind", "tab", "--json"]);
await mkdir(dirname(destination), { recursive: true });
await mkdir(destination); // Refuse to overwrite an earlier release preparation.
const staging = await mkdtemp(join(tmpdir(), "review-nvim-package-"));
try {
  const binaries = {};
  for (const target of Object.keys(manifest.backend.binary)) {
    const name = `tab-backend-${target}.tar.gz`;
    const receipt = run(["registry", "pack-tab-backend", "--directory", root,
      "--target", target, "--output", join(destination, name)]);
    binaries[target] = {
      archive: `${release}/${name}`,
      sha256: receipt.sha256,
      size: receipt.size,
      cmd: receipt.cmd,
      executable_sha256: receipt.executable_sha256,
      executable_size: receipt.executable_size,
    };
  }
  const webRoot = join(staging, manifest.id);
  await mkdir(webRoot);
  for (const entry of ["tab.json", "icon.svg", "dist"]) {
    await cp(`${root}/${entry}`, `${webRoot}/${entry}`, { recursive: true });
  }
  const web = { archive: `${release}/tab.tar.gz`, sha256: "0".repeat(64) };
  const provisional = join(staging, "metadata.json");
  await writeFile(provisional, JSON.stringify(metadata(manifest, web, binaries)));
  const receipt = run(["registry", "pack-tab", "--directory", webRoot, "--package", provisional,
    "--output", join(destination, "tab.tar.gz")]);
  web.sha256 = receipt.sha256;
  const document = join(destination, "marketplace.json");
  await writeFile(document, JSON.stringify(metadata(manifest, web, binaries), null, 2) + "\n", { flag: "wx" });
  run(["registry", "validate-metadata", document, "--json"]);
  const submission = {
    schema_version: 2,
    package: metadata(manifest, web, binaries),
    source: { repository, commit: source.commit, tag: releaseTag },
    changelog: "Batch GitLab conversation resolution with stale-discussion checks, confirmed partial results and REST fallback; improve conversation loading, pipeline status and job log previews.",
  };
  await mkdir(join(destination, "packages"));
  await mkdir(join(destination, "submissions"));
  await cp(document, join(destination, "packages", `${manifest.id}-${manifest.version}.json`));
  const submitted = join(destination, "submissions", `${manifest.id}-${manifest.version}.json`);
  await writeFile(submitted, JSON.stringify(submission, null, 2) + "\n");
  run(["registry", "validate-submission", submitted, "--json"]);
  await cp(`${repositoryRoot}/artifacts/native`, join(destination, "native-evidence"), { recursive: true });
  for (const target of Object.keys(binaries)) {
    await rm(join(destination, "native-evidence", `native-${target}`, "review-nvim"));
  }
  await writeFile(join(destination, "build-receipt.json"), JSON.stringify({
    schema_version: 1, source, native: receipts,
    packaging: {
      cli_version: spawnSync(cli, ["--version"], { encoding: "utf8" }).stdout.trim(),
    },
    outputs: Object.fromEntries(await Promise.all(
      ["tab.tar.gz", ...Object.keys(binaries).map((target) => `tab-backend-${target}.tar.gz`)]
        .map(async (name) => [name, await digest(join(destination, name))]))),
  }, null, 2) + "\n");
  console.log(`Prepared ${destination}\nNo release or registry submission was published.`);
} finally {
  await rm(staging, { recursive: true, force: true });
}
