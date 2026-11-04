import { cp, mkdir, readdir, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

const source = fileURLToPath(new URL("../../../", import.meta.url));
const target = fileURLToPath(new URL("../dist/runtime/", import.meta.url));

export async function runtimeSources() {
  const files = [
    `${source}/LICENSE`,
    `${source}/cadencr/review-nvim/runtime/bootstrap.lua`,
    `${source}/cadencr/review-nvim/runtime/start.lua`,
  ];
  for (const folder of ["lua", "plugin", "doc"]) {
    for (const path of await readdir(`${source}/${folder}`, { recursive: true })) {
      if (/\.(lua|txt)$/.test(path)) files.push(`${source}/${folder}/${path}`);
    }
  }
  return files;
}

export async function copyRuntime(destination = target) {
  await mkdir(destination, { recursive: true });
  for (const folder of ["lua", "plugin", "doc"]) {
    await cp(`${source}/${folder}`, `${destination}/${folder}`, { recursive: true });
  }
  await cp(`${source}/LICENSE`, `${destination}/LICENSE`);
  for (const file of ["bootstrap.lua", "start.lua"]) {
    await cp(`${source}/cadencr/review-nvim/runtime/${file}`, `${destination}/${file}`);
  }
  function git(args) {
    const result = spawnSync("git", args, { cwd: source, encoding: "utf8" });
    return result.status === 0 ? result.stdout.trim() : null;
  }
  await writeFile(`${destination}/source.json`, JSON.stringify({
    repository: "https://github.com/edjubert/review.nvim",
    commit: git(["rev-parse", "HEAD"]),
    main: git(["rev-parse", "origin/main"]),
    modified: Boolean(git(["status", "--porcelain", "--", "lua", "plugin", "doc", "LICENSE", "cadencr/review-nvim"])),
  }, null, 2) + "\n");
}
