-- Runs after the user's configuration and plugin-manager startup.
local runtime = _G.CadencRReviewRuntime
if not runtime then
  -- An already-running older backend can launch a session after a local update.
  dofile(vim.env.REVIEW_NVIM_RUNTIME .. "/bootstrap.lua")
  runtime = _G.CadencRReviewRuntime
end
runtime.activate()

-- Let lazy.nvim apply the user's options and config callback to the pinned
-- modules, even when its normal trigger is a :Review command.
local lazy = package.loaded.lazy
local config = package.loaded["lazy.core.config"]
if lazy and config and config.plugins then
  local plugins = {}
  for name, plugin in pairs(config.plugins) do
    local url = type(plugin.url) == "string" and plugin.url:gsub("%.git$", "") or ""
    if name == "review.nvim" or plugin.main == "review"
      or url:match("/review%.nvim$") then
      plugins[#plugins + 1] = name
    end
  end
  table.sort(plugins)
  if #plugins > 0 then lazy.load({ plugins = plugins }) end
end

runtime.activate()
local review = require("review")
vim.g.loaded_review = true
-- Replace plugin-manager command stubs and callbacks from other installations.
review._commands()
vim.cmd("stopinsert")
vim.schedule(function()
  review.setup(vim.tbl_deep_extend("force", review.config, {
    state_dir = vim.env.REVIEW_NVIM_STATE .. "/state",
    cache_dir = vim.env.REVIEW_NVIM_STATE .. "/cache",
  }))
  review.open(vim.env.REVIEW_NVIM_URL)
end)
