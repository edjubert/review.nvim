local M = {}
local defaults = {
  panel_width = 44,
  inline_comments = false,
  keymaps = {
    comment = "<leader>rc", submit = "<leader>rs", refresh = "<leader>rr",
    info = "<leader>ri", toggle_comments = "<leader>rt", reply = "<leader>rR",
    open_comment = "<leader>ro",
    search_files = "/",
    toggle_viewed = "<leader>rv",
  },
  clone_protocol = "ssh",
  repo = nil,
  cache_dir = vim.fn.stdpath("cache") .. "/review",
  state_dir = vim.fn.stdpath("state") .. "/review",
}
M.config = vim.deepcopy(defaults)

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
  assert(M.config.clone_protocol == "ssh" or M.config.clone_protocol == "https", "clone_protocol must be ssh or https")
  assert(type(M.config.inline_comments) == "boolean", "inline_comments must be a boolean")
  for _, name in ipairs({ "comment", "submit", "refresh", "info", "toggle_comments", "reply", "open_comment",
      "search_files", "toggle_viewed" }) do
    assert(type(M.config.keymaps[name]) == "string" or M.config.keymaps[name] == false,
      "keymaps." .. name .. " must be a mapping string or false")
  end
end

function M.open(raw_url)
  if vim.fn.has("nvim-0.11") == 0 then
    vim.notify("review requires Neovim 0.11 or newer.", vim.log.levels.ERROR); return
  end
  if not raw_url or raw_url == "" then
    vim.ui.input({ prompt = "GitLab MR / GitHub PR / Codeberg PR URL: " }, function(value) if value then M.open(value) end end)
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
    if M.session.submitting or M.session.deciding or M.session.resolving then
      vim.notify("Wait for the current review operation to finish.", vim.log.levels.WARN)
      return
    end
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

function M.approve()
  if not M.session or M.session.closed then
    vim.notify("Open a review with :Review first.", vim.log.levels.WARN, { title = "review" })
    return
  end
  M.session:approve()
end

function M.request_changes()
  if not M.session or M.session.closed then
    vim.notify("Open a review with :Review first.", vim.log.levels.WARN, { title = "review" })
    return
  end
  M.session:request_changes()
end

function M.reply()
  local s = M.session
  if not s or s.closed or vim.api.nvim_get_current_buf() ~= s.viewer_buf then
    vim.notify("Use :ReviewReply on a commented review diff line.", vim.log.levels.WARN); return
  end
  s:reply()
end

function M.open_comment()
  if not M.session or M.session.closed then
    vim.notify("Open a review with :Review first.", vim.log.levels.WARN, { title = "review" })
    return
  end
  M.session:open_comment()
end

function M.resolve()
  if not M.session or M.session.closed then
    vim.notify("Open a review with :Review first.", vim.log.levels.WARN, { title = "review" })
    return
  end
  M.session:resolve()
end

function M.resolve_all()
  if not M.session or M.session.closed then
    vim.notify("Open a review with :Review first.", vim.log.levels.WARN, { title = "review" })
    return
  end
  M.session:resolve_all()
end

function M.info()
  if not M.session or M.session.closed then
    vim.notify("Open a review with :Review first.", vim.log.levels.WARN, { title = "review" })
    return
  end
  M.session:show_info()
end

function M.pipelines()
  if not M.session or M.session.closed then
    vim.notify("Open a review with :Review first.", vim.log.levels.WARN, { title = "review" })
    return
  end
  M.session:show_pipelines()
end

function M.files()
  if not M.session or M.session.closed then
    vim.notify("Open a review with :Review first.", vim.log.levels.WARN, { title = "review" })
    return
  end
  M.session:search_files()
end

function M.viewed(enabled)
  if not M.session or M.session.closed then
    vim.notify("Open a review with :Review first.", vim.log.levels.WARN, { title = "review" })
    return
  end
  M.session:mark_viewed(enabled)
end

function M.toggle_comments()
  if not M.session or M.session.closed then
    vim.notify("Open a review with :Review first.", vim.log.levels.WARN, { title = "review" })
    return
  end
  M.session:toggle_comments()
end

function M._commands()
  vim.api.nvim_create_user_command("Review", function(args) M.open(args.args) end,
    { nargs = "?", desc = "Open a GitLab MR, GitHub PR or Codeberg PR URL" })
  vim.api.nvim_create_user_command("ReviewInfo", M.info,
    { desc = "Show the MR/PR title and description" })
  vim.api.nvim_create_user_command("ReviewPipelines", M.pipelines,
    { desc = "Browse GitLab MR pipelines and jobs in Telescope" })
  vim.api.nvim_create_user_command("ReviewFiles", M.files,
    { desc = "Search the current review's changed files in Telescope" })
  vim.api.nvim_create_user_command("ReviewViewed", function() M.viewed(true) end,
    { desc = "Mark the selected review file viewed locally" })
  vim.api.nvim_create_user_command("ReviewUnviewed", function() M.viewed(false) end,
    { desc = "Mark the selected review file unviewed locally" })
  vim.api.nvim_create_user_command("ReviewToggleViewed", function() M.viewed() end,
    { desc = "Toggle the selected review file's local viewed state" })
  vim.api.nvim_create_user_command("ReviewComment", function(args) M.comment(args.line1, args.line2) end,
    { range = true, desc = "Create a local comment draft on a line or range" })
  vim.api.nvim_create_user_command("ReviewReply", M.reply,
    { desc = "Draft a reply to a discussion on the current diff line" })
  vim.api.nvim_create_user_command("ReviewOpenComment", M.open_comment,
    { desc = "Open the comment under the cursor in the browser" })
  vim.api.nvim_create_user_command("ReviewDrafts", function() if M.session then M.session:show_drafts() end end,
    { desc = "Inspect, edit or delete local drafts" })
  vim.api.nvim_create_user_command("ReviewThreads", function() if M.session then M.session:show_threads() end end,
    { desc = "Read all review discussions and jump to comment lines" })
  vim.api.nvim_create_user_command("ReviewToggleComments", M.toggle_comments,
    { desc = "Show or hide discussions inline in the review diff" })
  vim.api.nvim_create_user_command("ReviewRefresh", M.refresh,
    { desc = "Reload the open review, commits, diffs and discussions" })
  vim.api.nvim_create_user_command("ReviewSubmit", function() if M.session then M.session:submit() end end,
    { desc = "Preview and explicitly publish local review comments" })
  vim.api.nvim_create_user_command("ReviewApprove", M.approve,
    { desc = "Approve the open MR/PR" })
  vim.api.nvim_create_user_command("ReviewRequestChanges", M.request_changes,
    { desc = "Request changes on the open MR/PR without submitting local drafts" })
  vim.api.nvim_create_user_command("ReviewResolve", M.resolve,
    { desc = "Resolve the GitLab conversation under the cursor" })
  vim.api.nvim_create_user_command("ReviewResolveAll", M.resolve_all,
    { desc = "Confirm and resolve all unresolved GitLab MR conversations" })
  vim.api.nvim_create_user_command("ReviewClose", function() if M.session then M.session:close() end end,
    { desc = "Close the review tab" })
end

return M
