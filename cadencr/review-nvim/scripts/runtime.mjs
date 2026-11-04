import { cp, mkdir, readdir, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

const source = fileURLToPath(new URL("../../../", import.meta.url));
const target = fileURLToPath(new URL("../dist/runtime/", import.meta.url));

export async function runtimeSources() {
  const files = [`${source}/LICENSE`];
  for (const folder of ["lua", "plugin", "doc"]) {
    for (const path of await readdir(`${source}/${folder}`, { recursive: true })) {
      if (/\.(lua|txt)$/.test(path)) files.push(`${source}/${folder}/${path}`);
    }
  }
  return files;
}

export async function copyRuntime() {
  await mkdir(target, { recursive: true });
  for (const folder of ["lua", "plugin", "doc"]) {
    await cp(`${source}/${folder}`, `${target}/${folder}`, { recursive: true });
  }
  await cp(`${source}/LICENSE`, `${target}/LICENSE`);
  function git(args) {
    const result = spawnSync("git", args, { cwd: source, encoding: "utf8" });
    return result.status === 0 ? result.stdout.trim() : null;
  }
  await writeFile(`${target}/source.json`, JSON.stringify({
    repository: "https://github.com/edjubert/review.nvim",
    commit: git(["rev-parse", "HEAD"]),
    main: git(["rev-parse", "origin/main"]),
    modified: Boolean(git(["status", "--porcelain", "--", "lua", "plugin", "doc", "LICENSE"])),
  }, null, 2) + "\n");
  await writeFile(`${target}/start.lua`, `-- Loaded after the user's Neovim configuration.
vim.opt.runtimepath:prepend(vim.env.REVIEW_NVIM_RUNTIME)
vim.cmd("runtime plugin/review.lua")
vim.cmd("stopinsert")
vim.schedule(function()
  local review = require("review")
  review.setup(vim.tbl_deep_extend("force", review.config, {
    state_dir = vim.env.REVIEW_NVIM_STATE .. "/state",
    cache_dir = vim.env.REVIEW_NVIM_STATE .. "/cache",
  }))
  review.open(vim.env.REVIEW_NVIM_URL)
end)
`);
}
