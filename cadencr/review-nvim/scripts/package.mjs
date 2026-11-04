import { spawnSync } from "node:child_process";
import { cp, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { metadata, repository } from "./metadata.mjs";

const root = fileURLToPath(new URL("../", import.meta.url));
const manifest = JSON.parse(await readFile(`${root}/tab.json`, "utf8"));
const destination = resolve(process.argv[2] ?? `../releases/review-nvim-v${manifest.version}`);
const cli = process.env.CADENCR_CLI ?? "cadencr";
const release = `${repository}/releases/download/cadencr-v${manifest.version}`;
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
  console.log(`Prepared ${destination}\nNo release or registry submission was published.`);
} finally {
  await rm(staging, { recursive: true, force: true });
}
