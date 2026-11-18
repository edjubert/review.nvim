local M = {}
local defaults = {
  panel_width = 44,
  inline_comments = false,
  pipeline_refresh_interval = 5000,
  job_logs = { gitlab = { trace_path = "projects/{project_id}/jobs/{job_id}/trace", artifacts = {} }, adapters = {} },
  keymaps = {
    comment = false, submit = false, refresh = false, info = false, help = false,
    edit_description = false,
    toggle_comments = false, reply = false, open_comment = false,
    search_files = false, files_picker = false, filter_exit = false, toggle_viewed = false,
    next_commit = false, prev_commit = false, next_file = false, prev_file = false,
    next_hunk = false, prev_hunk = false, complete = false, drafts = false,
    stack = false, stack_next = false, stack_prev = false, stack_open = false,
    thread = false, threads = false, close = false,
    panel_open = false, panel_left = false, panel_right = false,
    panel_toggle = false, panel_expand = false, panel_collapse = false,
    panel_collapse_all = false, panel_expand_all = false,
    close_document = false, select_comment = false, save_draft = false,
    pipeline_open = false, pipeline_back = false, pipeline_refresh = false, pipeline_logs = false,
  },
  clone_protocol = "ssh",
  repo = nil,
  stack_icons = {
    approved = "👌",
    changes_requested = "👎",
    pipeline_success = "✅",
    pipeline_running = "◐",
    pipeline_failed = "❌",
  },
  cache_dir = vim.fn.stdpath("cache") .. "/review",
  state_dir = vim.fn.stdpath("state") .. "/review",
}
M.config = vim.deepcopy(defaults)

-- One review per Neovim tab. Opening another review keeps the current one, so
-- two reviews can stay open side by side in their own tabs.
M.sessions = {}
M.session = nil

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
  assert(M.config.clone_protocol == "ssh" or M.config.clone_protocol == "https", "clone_protocol must be ssh or https")
  assert(type(M.config.inline_comments) == "boolean", "inline_comments must be a boolean")
  local interval = M.config.pipeline_refresh_interval
  assert(type(interval) == "number" and interval % 1 == 0 and (interval == 0 or interval >= 1000),
    "pipeline_refresh_interval must be 0 or an integer of at least 1000 milliseconds")
  require("review.job_logs").validate(M.config.job_logs)
  assert(type(M.config.stack_icons) == "table", "stack_icons must be a table")
  for name, icon in pairs(M.config.stack_icons) do
    assert(defaults.stack_icons[name] ~= nil, "Unknown stack_icons." .. name)
    assert(type(icon) == "string", "stack_icons." .. name .. " must be a string")
  end
  assert(type(M.config.keymaps) == "table", "keymaps must be a table")
  for name, key in pairs(M.config.keymaps) do
    assert(defaults.keymaps[name] ~= nil, "Unknown keymaps." .. name)
    assert((type(key) == "string" and key ~= "") or key == false,
      "keymaps." .. name .. " must be a mapping string or false")
  end
end

-- The review of the current tab, else the last review the user focused. A
-- command run from another tab keeps working on that review.
local function live(session)
  return session and not session.closed and session.tab
    and vim.api.nvim_tabpage_is_valid(session.tab)
end

local function current()
  local session = M.sessions[vim.api.nvim_get_current_tabpage()]
  if live(session) then return session end
  if live(M.session) then return M.session end
end

local function with_session(fn)
  local session = current()
  if not session then
    vim.notify("Open a review with :Review first.", vim.log.levels.WARN, { title = "review" })
    return
  end
  fn(session)
end

function M._forget(session)
  for tab, value in pairs(M.sessions) do
    if value == session then M.sessions[tab] = nil end
  end
  if M.session == session then M.session = nil end
end

function M.open(raw_url, opts)
  if vim.fn.has("nvim-0.11") == 0 then
    vim.notify("review requires Neovim 0.11 or newer.", vim.log.levels.ERROR); return
  end
  if not raw_url or raw_url == "" then
    vim.ui.input({ prompt = "GitLab MR / GitHub PR / Codeberg PR URL: " }, function(value) if value then M.open(value, opts) end end)
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
  -- Stack navigation replaces the review it leaves; :Review keeps it open.
  if opts and opts.replace then
    local previous = current()
    if previous then
      if previous.submitting or previous.deciding or previous.resolving then
        vim.notify("Wait for the current review operation to finish.", vim.log.levels.WARN)
        return
      end
      previous:close()
    end
  end
  local ok, session = pcall(require("review.session").new, target, vim.deepcopy(M.config))
  if not ok then vim.notify(session, vim.log.levels.ERROR, { title = "review" }); return end
  session.on_close = function() M._forget(session) end
  session:load()
  if session.tab then M.sessions[session.tab] = session end
  M.session = session
end

function M.comment(first, last)
  local s = current()
  if not s or vim.api.nvim_get_current_buf() ~= s.viewer_buf then
    vim.notify("Select a line in a review diff buffer first.", vim.log.levels.WARN); return
  end
  s:comment(first or vim.fn.line("."), last or first or vim.fn.line("."))
end

function M.refresh() with_session(function(s) s:refresh() end) end

function M.approve() with_session(function(s) s:approve() end) end

function M.request_changes() with_session(function(s) s:request_changes() end) end

function M.reply()
  local s = current()
  if not s or vim.api.nvim_get_current_buf() ~= s.viewer_buf then
    vim.notify("Use :ReviewReply on a commented review diff line.", vim.log.levels.WARN); return
  end
  s:reply()
end

function M.open_comment() with_session(function(s) s:open_comment() end) end

function M.resolve() with_session(function(s) s:resolve() end) end

function M.resolve_all() with_session(function(s) s:resolve_all() end) end

function M.info() with_session(function(s) s:show_info() end) end

function M.edit_description() with_session(function(s) s:edit_description() end) end

function M.pipelines() with_session(function(s) s:show_pipelines() end) end

function M.refresh_job() with_session(function(s) require("review.telescope").refresh_job(s) end) end

function M.job_logs() with_session(function(s) require("review.telescope").select_job_log(s) end) end

function M.help() with_session(function(s) require("review.ui").help(s) end) end

function M.files(query) with_session(function(s) s:search_files(query) end) end

function M.files_picker() with_session(function(s) s:pick_files() end) end

function M.clear_files() with_session(function(s) require("review.ui").set_filter(s, "") end) end

function M.viewed(enabled) with_session(function(s) s:mark_viewed(enabled) end) end

function M.toggle_comments() with_session(function(s) s:toggle_comments() end) end

function M._commands()
  local function session_command(name, callback, opts)
    vim.api.nvim_create_user_command(name, function(args)
      with_session(function(session) callback(session, args) end)
    end, opts)
  end
  -- A command run from another tab keeps targeting the review last focused.
  local group = vim.api.nvim_create_augroup("ReviewSessions", { clear = true })
  vim.api.nvim_create_autocmd("TabEnter", {
    group = group,
    callback = function()
      local session = M.sessions[vim.api.nvim_get_current_tabpage()]
      if session and not session.closed then M.session = session end
    end,
  })
  -- A tab closed by hand leaves no session behind for later commands.
  vim.api.nvim_create_autocmd("TabClosed", {
    group = group,
    callback = function()
      for tab, session in pairs(M.sessions) do
        if not vim.api.nvim_tabpage_is_valid(tab) then
          M.sessions[tab] = nil
          if M.session == session then M.session = nil end
        end
      end
    end,
  })
  vim.api.nvim_create_user_command("Review", function(args) M.open(args.args) end,
    { nargs = "?", desc = "Open a GitLab MR, GitHub PR or Codeberg PR URL" })
  for _, entry in ipairs({
    { "ReviewNextCommit", "move_commit", 1, "Next review commit" },
    { "ReviewPrevCommit", "move_commit", -1, "Previous review commit" },
    { "ReviewNextFile", "move_file", 1, "Next review file" },
    { "ReviewPrevFile", "move_file", -1, "Previous review file" },
    { "ReviewNextChange", "move_hunk", 1, "Next review change" },
    { "ReviewPrevChange", "move_hunk", -1, "Previous review change" },
  }) do
    local opts = { desc = entry[4] }
    if entry[2] == "move_hunk" then opts.count = 1 end
    session_command(entry[1], function(session, args) session[entry[2]](session, entry[3], args.count) end, opts)
  end
  session_command("ReviewComplete", function(session) session:select_commit(0) end,
    { desc = "Show the complete MR/PR comparison" })
  session_command("ReviewStack", function(session) session:show_stack() end,
    { desc = "Choose another review in the stack" })
  session_command("ReviewStackNext", function(session) session:move_stack(1) end,
    { desc = "Open the next review in the stack" })
  session_command("ReviewStackPrev", function(session) session:move_stack(-1) end,
    { desc = "Open the previous review in the stack" })
  session_command("ReviewStackOpen", function(session) session:open_stack_browser() end,
    { desc = "Open the review under the cursor in the browser" })
  local panel_actions = { "open", "left", "right", "toggle", "expand", "collapse", "collapse_all", "expand_all" }
  session_command("ReviewPanel", function(session, args)
    if not vim.tbl_contains(panel_actions, args.args) then error("Unknown ReviewPanel action: " .. args.args, 0) end
    require("review.ui").panel_action(session, args.args)
  end, { nargs = 1, desc = "Open or fold the selected review tree entry",
    complete = function() return panel_actions end })
  vim.api.nvim_create_user_command("ReviewInfo", M.info,
    { desc = "Show the MR/PR title and description" })
  vim.api.nvim_create_user_command("ReviewEditDescription", M.edit_description,
    { desc = "Edit and publish the MR/PR description" })
  vim.api.nvim_create_user_command("ReviewHelp", M.help,
    { desc = "Search review commands and configured mappings in Telescope" })
  vim.api.nvim_create_user_command("ReviewPipelines", M.pipelines,
    { desc = "Browse review pipelines, grouped jobs and job logs in Telescope" })
  vim.api.nvim_create_user_command("ReviewJobRefresh", M.refresh_job,
    { desc = "Reload the selected job's metadata and log without using cached results" })
  vim.api.nvim_create_user_command("ReviewJobLogs", M.job_logs,
    { desc = "Choose a trace, artifact or custom log for the selected job" })
  vim.api.nvim_create_user_command("ReviewFiles", function(args) M.files(args.args) end,
    { nargs = "*", desc = "Filter changed files in the review panel" })
  vim.api.nvim_create_user_command("ReviewFilesClear", M.clear_files,
    { desc = "Clear the review panel's file filter" })
  vim.api.nvim_create_user_command("ReviewFilesPicker", M.files_picker,
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
  vim.api.nvim_create_user_command("ReviewDrafts", function() with_session(function(s) s:show_drafts() end) end,
    { desc = "Inspect, edit or delete local drafts" })
  vim.api.nvim_create_user_command("ReviewThreads", function() with_session(function(s) s:show_threads() end) end,
    { desc = "Read all review discussions and jump to comment lines" })
  session_command("ReviewThread", function(session) session:show_thread_at_cursor() end,
    { desc = "Read discussions attached to the current diff line" })
  session_command("ReviewJump", function(session) session:jump_thread_at_cursor() end,
    { desc = "Jump from the selected discussion to its comment line" })
  vim.api.nvim_create_user_command("ReviewToggleComments", M.toggle_comments,
    { desc = "Show or hide discussions inline in the review diff" })
  vim.api.nvim_create_user_command("ReviewRefresh", M.refresh,
    { desc = "Reload the open review, commits, diffs and discussions" })
  vim.api.nvim_create_user_command("ReviewSubmit", function() with_session(function(s) s:submit() end) end,
    { desc = "Preview and explicitly publish local review comments" })
  vim.api.nvim_create_user_command("ReviewApprove", M.approve,
    { desc = "Approve the open MR/PR" })
  vim.api.nvim_create_user_command("ReviewRequestChanges", M.request_changes,
    { desc = "Request changes on the open MR/PR without submitting local drafts" })
  vim.api.nvim_create_user_command("ReviewResolve", M.resolve,
    { desc = "Resolve the GitLab conversation under the cursor" })
  vim.api.nvim_create_user_command("ReviewResolveAll", M.resolve_all,
    { desc = "Confirm and resolve all unresolved GitLab MR conversations" })
  vim.api.nvim_create_user_command("ReviewClose", function() with_session(function(s) s:close() end) end,
    { desc = "Close the review tab" })
end

return M
