import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { appendFile, chmod, mkdir, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";

const pins = JSON.parse(await readFile(new URL("../ci/toolchains.json", import.meta.url), "utf8"));
assert.ok(process.env.RUNNER_TEMP && process.env.GITHUB_PATH, "This bootstrap is for GitHub-hosted runners.");
const kind = process.argv[2];
const directory = join(process.env.RUNNER_TEMP, "review-tools", kind);
await mkdir(directory, { recursive: true });
let asset, url;
if (kind === "neovim") {
  asset = pins.neovim.assets[`${process.platform}-${process.arch}`];
  assert.ok(asset, "No pinned Neovim for this platform.");
  url = `https://github.com/neovim/neovim/releases/download/v${pins.neovim.version}/${asset.name}`;
} else {
  assert.equal(kind, "cadencr");
  assert.equal(`${process.platform}-${process.arch}`, "linux-x64");
  asset = pins.cadencr;
  url = `https://github.com/merkr-software/CadencR/releases/download/cli/v${asset.version}/${asset.name}`;
}
const response = await fetch(url);
assert.ok(response.ok, `Toolchain download failed: ${response.status}`);
const bytes = Buffer.from(await response.arrayBuffer());
assert.equal(createHash("sha256").update(bytes).digest("hex"), asset.sha256, "Toolchain SHA-256 mismatch.");
const path = join(directory, kind === "cadencr" ? "cadencr" : asset.name);
await writeFile(path, bytes);
if (kind === "neovim") {
  const tar = spawnSync("tar", ["-xzf", path, "--strip-components=1", "-C", directory], { stdio: "inherit" });
  if (tar.error) throw tar.error;
  assert.equal(tar.status, 0);
  await appendFile(process.env.GITHUB_PATH, `${directory}/bin\n`);
} else {
  await chmod(path, 0o755);
  await appendFile(process.env.GITHUB_PATH, `${directory}\n`);
}
