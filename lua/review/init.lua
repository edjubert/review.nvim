local M = {}
local defaults = {
  panel_width = 44,
  keymaps = { comment = "<leader>rc", submit = "<leader>rs", refresh = "<leader>rr" },
  clone_protocol = "ssh",
  repo = nil,
  cache_dir = vim.fn.stdpath("cache") .. "/review",
  state_dir = vim.fn.stdpath("state") .. "/review",
}
M.config = vim.deepcopy(defaults)

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
  assert(M.config.clone_protocol == "ssh" or M.config.clone_protocol == "https", "clone_protocol must be ssh or https")
  for _, name in ipairs({ "comment", "submit", "refresh" }) do
    assert(type(M.config.keymaps[name]) == "string" or M.config.keymaps[name] == false,
      "keymaps." .. name .. " must be a mapping string or false")
  end
end

function M.open(raw_url)
  if vim.fn.has("nvim-0.11") == 0 then
    vim.notify("review requires Neovim 0.11 or newer.", vim.log.levels.ERROR); return
  end
  if not raw_url or raw_url == "" then
    vim.ui.input({ prompt = "GitLab MR / GitHub PR URL: " }, function(value) if value then M.open(value) end end)
    return
  end
  local target, err = require("review.url").parse(raw_url)
  if not target then vim.notify(err, vim.log.levels.ERROR, { title = "review" }); return end
  local provider = require("review.providers").for_target(target)
  for _, command in ipairs({ "git", provider.cli }) do
    if vim.fn.executable(command) == 0 then
      vim.notify("review requires " .. command .. " in PATH for " .. provider.name .. ".", vim.log.levels.ERROR)
      return
    end
  end
  if M.session then
    if M.session.submitting then vim.notify("Wait for comment submission to finish.", vim.log.levels.WARN); return end
    M.session:close()
  end
  local ok, session = pcall(require("review.session").new, target, vim.deepcopy(M.config))
  if not ok then vim.notify(session, vim.log.levels.ERROR, { title = "review" }); return end
  M.session = session
  session:load()
end

function M.comment(first, last)
  local s = M.session
  if not s or vim.api.nvim_get_current_buf() ~= s.viewer_buf then
    vim.notify("Select a line in a review diff buffer first.", vim.log.levels.WARN); return
  end
  s:comment(first or vim.fn.line("."), last or first or vim.fn.line("."))
end

function M.refresh()
  if not M.session or M.session.closed then
    vim.notify("Open a review with :Review first.", vim.log.levels.WARN, { title = "review" })
    return
  end
  M.session:refresh()
end

function M._commands()
  vim.api.nvim_create_user_command("Review", function(args) M.open(args.args) end,
    { nargs = "?", desc = "Open a GitLab MR or GitHub PR URL" })
  vim.api.nvim_create_user_command("ReviewComment", function(args) M.comment(args.line1, args.line2) end,
    { range = true, desc = "Create a local comment draft on a line or range" })
  vim.api.nvim_create_user_command("ReviewDrafts", function() if M.session then M.session:show_drafts() end end,
    { desc = "Inspect, edit or delete local drafts" })
  vim.api.nvim_create_user_command("ReviewThreads", function() if M.session then M.session:show_threads() end end,
    { desc = "Read existing review discussions" })
  vim.api.nvim_create_user_command("ReviewRefresh", M.refresh,
    { desc = "Reload the open review, commits, diffs and discussions" })
  vim.api.nvim_create_user_command("ReviewSubmit", function() if M.session then M.session:submit() end end,
    { desc = "Preview and explicitly publish local review comments" })
  vim.api.nvim_create_user_command("ReviewClose", function() if M.session then M.session:close() end end,
    { desc = "Close the review tab" })
end

return M
