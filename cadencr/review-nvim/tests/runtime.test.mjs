import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test, { before, after } from "node:test";
import { copyRuntime } from "../scripts/runtime.mjs";

let root;
let runtime;
before(async () => {
  root = await mkdtemp(join(tmpdir(), "review-nvim-runtime-"));
  runtime = join(root, "runtime");
  await copyRuntime(runtime);
});
after(async () => { await rm(root, { recursive: true, force: true }); });

async function launch(mode) {
  const state = await mkdtemp(join(root, `${mode}-`));
  const installed = join(state, "installed");
  await mkdir(join(installed, "lua", "review"), { recursive: true });
  await mkdir(join(installed, "plugin"), { recursive: true });
  await writeFile(join(installed, "lua", "review", "init.lua"),
    'error("The installed review.nvim must never be loaded")\n');
  await writeFile(join(installed, "lua", "review", "only_installed.lua"), "return { foreign = true }\n");
  await writeFile(join(installed, "lua", "fixture_external.lua"), "return { available = true }\n");
  await writeFile(join(installed, "plugin", "review.lua"),
    'if vim.g.loaded_review then return end\nerror("Foreign review commands must not be registered")\n');
  const config = join(state, "init.lua");
  await writeFile(config, `
vim.opt.shadafile = "NONE"
vim.opt.number = true
vim.opt.runtimepath = { vim.env.REVIEW_TEST_INSTALLED, vim.env.VIMRUNTIME }
package.path = vim.env.REVIEW_TEST_INSTALLED .. "/lua/?.lua;" ..
  vim.env.REVIEW_TEST_INSTALLED .. "/lua/?/init.lua;" .. package.path
package.preload["review.url"] = function() error("Foreign preload") end
local review = require("review")
assert(debug.getinfo(review.setup).source == "@" .. vim.env.REVIEW_NVIM_RUNTIME .. "/lua/review/init.lua")
review.setup({ panel_width = 58, keymaps = { next_file = "]F" } })
_G.ReviewFixture = { opened = {}, lazy_configured = false }
review.open = function(url) table.insert(ReviewFixture.opened, url) end
vim.api.nvim_create_user_command("Review", function() error("Foreign command") end, { nargs = "*" })
if vim.env.REVIEW_TEST_LAZY_PATH then
  vim.go.loadplugins = true
  vim.opt.runtimepath:prepend(vim.env.REVIEW_TEST_LAZY_PATH)
  require("lazy").setup({
    {
      dir = vim.env.REVIEW_TEST_INSTALLED, name = "review.nvim", main = "review",
      lazy = vim.env.REVIEW_TEST_MODE ~= "eager", cmd = { "Review", "ReviewClose" },
      opts = { panel_width = 63, keymaps = { next_file = "]L" } },
      config = vim.env.REVIEW_TEST_MODE == "lazy-config" and function(_, opts)
        ReviewFixture.lazy_configured = true
        require("review").setup(opts)
        vim.api.nvim_create_user_command("Review", function() error("Lazy command override") end, { nargs = "*" })
      end,
    },
  }, {
    root = vim.env.REVIEW_TEST_STATE .. "/lazy",
    lockfile = vim.env.REVIEW_TEST_STATE .. "/lock.json",
    install = { missing = false }, checker = { enabled = false },
    change_detection = { enabled = false }, readme = { enabled = false },
  })
end
-- A plugin-manager cache populated after init.lua must not select foreign code.
package.loaded["review.url"] = { parse = function() error("Foreign cached URL module") end }
table.insert(package.loaders, 1, function(name)
  if name == "review.url" then return function() error("Foreign searcher") end end
end)
`);
  const check = join(state, "check.lua");
  const result = join(state, "result.json");
  await writeFile(check, `
local ok, err = xpcall(function()
  assert(vim.wait(1000, function() return #ReviewFixture.opened == 1 end))
  local review = require("review")
  local url = require("review.url")
  assert(debug.getinfo(review.setup).source == "@" .. vim.env.REVIEW_NVIM_RUNTIME .. "/lua/review/init.lua")
  assert(debug.getinfo(url.parse).source == "@" .. vim.env.REVIEW_NVIM_RUNTIME .. "/lua/review/url.lua")
  assert(require("fixture_external").available, "Other plugins remain available")
  local missing, missing_err = pcall(require, "review.only_installed")
  assert(not missing and tostring(missing_err):find("only_installed", 1, true),
    "Missing bundle modules must not come from the installed plugin")
  vim.cmd("Review https://github.com/fixture/repo/pull/2")
  assert(#ReviewFixture.opened == 2, "Review must use the pinned command callback")
  assert(vim.wo.number, "The user's normal configuration must remain active")
  assert(review.config.state_dir == vim.env.REVIEW_NVIM_STATE .. "/state")
  assert(review.config.cache_dir == vim.env.REVIEW_NVIM_STATE .. "/cache")
  vim.fn.writefile({ vim.json.encode({
    panel_width = review.config.panel_width, next_file = review.config.keymaps.next_file,
    lazy_configured = ReviewFixture.lazy_configured, opened = ReviewFixture.opened,
  }) }, vim.env.REVIEW_TEST_RESULT)
end, debug.traceback)
if not ok then
  io.stderr:write(err .. "\\n")
  vim.cmd("cquit 1")
end
vim.cmd("qa!")
`);
  const env = {
    ...process.env,
    NVIM_APPNAME: "review-nvim-test",
    XDG_CONFIG_HOME: join(state, "config"), XDG_DATA_HOME: join(state, "data"),
    XDG_CACHE_HOME: join(state, "cache"), XDG_STATE_HOME: join(state, "state"),
    REVIEW_NVIM_RUNTIME: runtime, REVIEW_NVIM_STATE: join(state, "plugin-state"),
    REVIEW_NVIM_URL: "https://github.com/fixture/repo/pull/1",
    REVIEW_TEST_MODE: mode, REVIEW_TEST_INSTALLED: installed,
    REVIEW_TEST_STATE: state, REVIEW_TEST_RESULT: result,
  };
  if (["lazy", "eager", "lazy-config"].includes(mode)) env.REVIEW_TEST_LAZY_PATH = process.env.LAZY_PATH;
  else delete env.REVIEW_TEST_LAZY_PATH;
  const args = ["--headless", "-u", config, "-i", "NONE"];
  if (mode === "preloaded") {
    args.push("--cmd", 'lua package.loaded.review = { _commands = function() error("Foreign cached root") end }; package.loaded["review.url"] = { foreign = true }');
  }
  args.push("--cmd", "lua dofile(vim.env.REVIEW_NVIM_RUNTIME .. '/bootstrap.lua')",
    "-c", "lua dofile(vim.env.REVIEW_NVIM_RUNTIME .. '/start.lua')",
    "-c", "lua dofile(vim.env.REVIEW_TEST_STATE .. '/check.lua')");
  const child = spawnSync(process.env.NVIM ?? "nvim", args, { env, encoding: "utf8", timeout: 10_000 });
  assert.equal(child.error, undefined);
  assert.equal(child.status, 0, child.stdout + child.stderr);
  return JSON.parse(await readFile(result, "utf8"));
}

for (const mode of ["normal", "preloaded"]) {
  test(`bundled review survives ${mode} startup, runtime resets and foreign module caches`, async () => {
    const result = await launch(mode);
    assert.equal(result.panel_width, 58);
    assert.equal(result.next_file, "]F");
    assert.deepEqual(result.opened, [
      "https://github.com/fixture/repo/pull/1", "https://github.com/fixture/repo/pull/2",
    ]);
  });
}

for (const mode of ["lazy", "eager", "lazy-config"]) {
  test(`real lazy.nvim ${mode} configuration applies to bundled review modules`, {
    skip: !process.env.LAZY_PATH,
  }, async () => {
    const result = await launch(mode);
    assert.equal(result.lazy_configured, mode === "lazy-config");
    assert.equal(result.panel_width, 63);
    assert.equal(result.next_file, "]L");
  });
}

test("an older running backend can launch the updated runtime without its bootstrap argument", async () => {
  const state = await mkdtemp(join(root, "legacy-"));
  const child = spawnSync(process.env.NVIM ?? "nvim", [
    "--headless", "-u", "NONE", "-i", "NONE",
    "--cmd", 'lua package.loaded.review = { _commands = function() error("Old cached version") end }',
    "-c", "lua dofile(vim.env.REVIEW_NVIM_RUNTIME .. '/start.lua')",
    "-c", `lua vim.wait(50); assert(debug.getinfo(require("review").setup).source == "@" .. vim.env.REVIEW_NVIM_RUNTIME .. "/lua/review/init.lua"); assert(require("review").config.state_dir == vim.env.REVIEW_NVIM_STATE .. "/state")`,
    "-c", "qa!",
  ], {
    env: {
      ...process.env,
      XDG_CONFIG_HOME: join(state, "config"), XDG_DATA_HOME: join(state, "data"),
      XDG_CACHE_HOME: join(state, "cache"), XDG_STATE_HOME: join(state, "state"),
      REVIEW_NVIM_RUNTIME: runtime, REVIEW_NVIM_STATE: state, REVIEW_NVIM_URL: "invalid",
    },
    encoding: "utf8", timeout: 5000,
  });
  assert.equal(child.error, undefined);
  assert.equal(child.status, 0, child.stdout + child.stderr);
});
