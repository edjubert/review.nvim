local threads = require("review.threads")
local emoji = require("review.emoji")
local status = require("review.status")
local reactions = require("review.reactions")
local viewed = require("review.viewed")
local tree = require("review.tree")
local M = {}
local namespace = vim.api.nvim_create_namespace("review")
local comment_namespace = vim.api.nvim_create_namespace("review.comments")
local panel_namespace = vim.api.nvim_create_namespace("review.panel")
local filter_namespace = vim.api.nvim_create_namespace("review.filter")
local filter_prompt = "> "
local serial = 0

function M.highlights()
  local links = {
    ReviewPanelTitle = "Title",
    ReviewCommit = "Directory",
    ReviewCommitSha = "Identifier",
    ReviewDirectory = "Directory",
    ReviewFile = "Normal",
    ReviewFileAdded = "DiagnosticOk",
    ReviewFileModified = "DiagnosticWarn",
    ReviewFileDeleted = "DiagnosticError",
    ReviewFileRenamed = "DiagnosticInfo",
    ReviewFileViewed = "DiagnosticOk",
    ReviewSelected = "CursorLine",
    ReviewDraftCount = "Special",
    ReviewHelp = "Comment",
    ReviewFilterBorder = "FloatBorder",
    ReviewFilterPrompt = "Identifier",
    ReviewStatusOk = "DiagnosticOk",
    ReviewStatusWarn = "DiagnosticWarn",
    ReviewStatusError = "DiagnosticError",
    ReviewCommentBorder = "FloatBorder",
    ReviewCommentAuthor = "Title",
    ReviewCommentBody = "NormalFloat",
    ReviewCommentReaction = "Special",
    ReviewPipelineHeading = "ReviewPipelineStage",
  }
  for name, link in pairs(links) do vim.api.nvim_set_hl(0, name, { default = true, link = link }) end
  local title = vim.api.nvim_get_hl(0, { name = "Title", link = false })
  local pipeline_colors = {
    ReviewPipelineSuccess = { fg = "#9ece6a", ctermfg = 114 },
    ReviewPipelineError = { fg = "#f7768e", ctermfg = 203 },
    ReviewPipelinePending = { fg = "#ff9e64", ctermfg = 208 },
    ReviewPipelineRunning = { fg = "#7aa2f7", ctermfg = 111 },
    ReviewPipelineInactive = { fg = "#7a8499", ctermfg = 244 },
    ReviewPipelineStage = { fg = title.fg or "#c0caf5", ctermfg = title.ctermfg, bold = true },
  }
  for name, colors in pairs(pipeline_colors) do
    vim.api.nvim_set_hl(0, name, vim.tbl_extend("force", { default = true }, colors))
  end
end

vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("ReviewHighlights", { clear = true }),
  callback = M.highlights,
})

local function set_lines(buf, lines)
  local readonly = vim.bo[buf].readonly
  vim.bo[buf].readonly = false
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  vim.bo[buf].readonly = readonly
end

local function scratch(name, filetype)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, name)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = filetype
  return buf
end

function M.valid(session)
  return not session.closed and session.tab and vim.api.nvim_tabpage_is_valid(session.tab)
end

function M.key(session, name)
  return (session.config.keymaps or {})[name] or false
end

function M.comment_key(session)
  return M.key(session, "comment")
end

function M.submit_key(session)
  return M.key(session, "submit")
end

function M.refresh_key(session)
  return M.key(session, "refresh")
end

function M.info_key(session)
  return M.key(session, "info")
end

function M.toggle_comments_key(session)
  return M.key(session, "toggle_comments")
end

function M.reply_key(session)
  return M.key(session, "reply")
end

function M.open_comment_key(session)
  return M.key(session, "open_comment")
end

function M.search_files_key(session)
  return M.key(session, "search_files")
end

function M.toggle_viewed_key(session)
  return M.key(session, "toggle_viewed")
end

local function bind(session, buf, name, callback, description, mode)
  local key = M.key(session, name)
  if key then
    vim.keymap.set(mode or "n", key, callback, { buffer = buf, silent = true, desc = description })
  end
end

function M.bind_open_comment(session, buf)
  bind(session, buf, "open_comment", function() session:open_comment() end, "Open this comment in the browser")
end

function M.bind(session, buf)
  local maps = {
    next_commit = { function() session:move_commit(1) end, "Next review commit" },
    prev_commit = { function() session:move_commit(-1) end, "Previous review commit" },
    next_file = { function() session:move_file(1) end, "Next review file" },
    prev_file = { function() session:move_file(-1) end, "Previous review file" },
    next_hunk = { function() session:move_hunk(1, vim.v.count1) end, "Next review change" },
    prev_hunk = { function() session:move_hunk(-1, vim.v.count1) end, "Previous review change" },
    complete = { function() session:select_commit(0) end, "Complete MR/PR comparison" },
    drafts = { function() session:show_drafts() end, "Inspect local review drafts" },
    threads = { function() session:show_threads() end, "Read all review discussions" },
    close = { function() session:close() end, "Close the review tab" },
    submit = { function() session:submit() end, "Preview and submit review drafts" },
    refresh = { function() session:refresh() end, "Refresh the review" },
    info = { function() session:show_info() end, "Show the MR/PR title and description" },
    help = { function() M.help(session) end, "Search review commands and mappings" },
    toggle_comments = { function() session:toggle_comments() end, "Show or hide inline discussions" },
    toggle_viewed = { function() session:mark_viewed() end, "Toggle this file's local viewed state" },
    files_picker = { function() session:pick_files() end, "Search review files in Telescope" },
  }
  for name, mapping in pairs(maps) do
    bind(session, buf, name, mapping[1], mapping[2])
  end
end

function M.create(session)
  M.highlights()
  serial = serial + 1
  session.serial = serial
  vim.cmd("tabnew")
  session.tab = vim.api.nvim_get_current_tabpage()
  session.viewer_win = vim.api.nvim_get_current_win()
  session.viewer_buf = scratch("review://" .. serial .. "/diff", "")
  vim.api.nvim_win_set_buf(session.viewer_win, session.viewer_buf)
  vim.cmd("topleft " .. session.config.panel_width .. "vnew")
  session.panel_win = vim.api.nvim_get_current_win()
  session.panel_buf = scratch("review://" .. serial .. "/commits", "review")
  vim.api.nvim_win_set_buf(session.panel_win, session.panel_buf)
  vim.wo[session.panel_win].number = false
  vim.wo[session.panel_win].relativenumber = false
  vim.wo[session.panel_win].wrap = false
  vim.wo[session.panel_win].signcolumn = "no"
  vim.wo[session.panel_win].foldenable = false
  vim.wo[session.panel_win].winfixwidth = true
  vim.wo[session.panel_win].cursorline = true
  vim.wo[session.panel_win].scrolloff = math.max(3, vim.o.scrolloff)
  session.ui_group = vim.api.nvim_create_augroup("ReviewUI" .. serial, { clear = true })
  vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
    group = session.ui_group,
    callback = function()
      M.filter(session)
      if session.inline_comments then M.comments(session) end
    end,
  })
  vim.api.nvim_create_autocmd("WinScrolled", {
    group = session.ui_group,
    callback = function()
      if vim.v.event[tostring(session.panel_win)] then M.filter(session) end
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = session.ui_group,
    pattern = tostring(session.panel_win),
    callback = function() M.close(session) end,
  })
  M.bind(session, session.panel_buf)
  M.bind(session, session.viewer_buf)
  bind(session, session.panel_buf, "search_files", function() session:search_files() end,
    "Filter changed files in the review panel")
  local tree_actions = {
    panel_open = "open", panel_left = "left", panel_right = "right",
    panel_toggle = "toggle", panel_expand = "expand", panel_collapse = "collapse",
    panel_collapse_all = "collapse_all", panel_expand_all = "expand_all",
  }
  for name, action in pairs(tree_actions) do
    bind(session, session.panel_buf, name, function() M.panel_action(session, action) end,
      "Review tree: " .. action)
  end
  bind(session, session.viewer_buf, "thread", function() session:show_thread_at_cursor() end,
    "Read discussions on this review line")
  local comment_key = M.comment_key(session)
  if comment_key then
    vim.keymap.set({ "n", "x" }, comment_key, function()
      if not session.current then return end
      local start, finish = vim.api.nvim_win_get_cursor(session.viewer_win)[1], nil
      local mode = vim.fn.mode()
      if mode == "v" or mode == "V" or mode == "\22" then
        finish = vim.fn.line("v")
        start, finish = math.min(start, finish), math.max(start, finish)
        vim.cmd.normal({ args = { "\27" }, bang = true })
      end
      session:comment(start, finish or start)
    end, { buffer = session.viewer_buf, silent = true, desc = "Draft a review comment" })
  end
  local reply_key = M.reply_key(session)
  if reply_key then
    vim.keymap.set("n", reply_key, function() session:reply() end,
      { buffer = session.viewer_buf, silent = true, desc = "Draft a reply to this discussion" })
  end
  M.bind_open_comment(session, session.viewer_buf)
  vim.api.nvim_set_current_win(session.viewer_win)
  set_lines(session.viewer_buf, { "Loading review…" })
  M.panel(session)
end

function M.help(session)
  if not M.valid(session) then return end
  local entries = {}
  local function add(command, mapping, description, scope)
    entries[#entries + 1] = {
      command = command, key = M.key(session, mapping), description = description,
      scope = scope or "Panel / diff",
    }
  end
  for _, item in ipairs({
    { ":ReviewHelp", "help", "Search review commands and configured mappings" },
    { ":ReviewInfo", "info", "Show the MR/PR title and description" },
    { ":ReviewComplete", "complete", "Show the complete MR/PR comparison" },
    { ":ReviewNextCommit", "next_commit", "Select the next commit" },
    { ":ReviewPrevCommit", "prev_commit", "Select the previous commit" },
    { ":ReviewNextFile", "next_file", "Open the next matching changed file" },
    { ":ReviewPrevFile", "prev_file", "Open the previous matching changed file" },
    { ":ReviewNextChange", "next_hunk", "Jump forward through change blocks; accepts a count" },
    { ":ReviewPrevChange", "prev_hunk", "Jump backward through change blocks; accepts a count" },
    { ":ReviewFiles", "search_files", "Edit the sidebar file filter, or apply a query", "Panel" },
    { ":ReviewFilesClear", false, "Clear the filter and restore directory folds", "Panel" },
    { "Return to file tree", "filter_exit", "Keep the query and return to the tree; native Enter and Ctrl-C also work", "File filter" },
    { ":ReviewFilesPicker", "files_picker", "Search all changed files in Telescope" },
    { ":ReviewViewed", false, "Mark the selected file viewed locally" },
    { ":ReviewUnviewed", false, "Remove the selected file's local viewed marker" },
    { ":ReviewToggleViewed", "toggle_viewed", "Toggle the selected file's local viewed marker" },
    { ":[range]ReviewComment", "comment", "Create a local draft on a line or selected range", "Diff, normal / visual" },
    { ":ReviewReply", "reply", "Create a local reply draft on a commented line", "Diff" },
    { ":ReviewThread", "thread", "Read discussions on the current line or range", "Diff" },
    { ":ReviewThreads", "threads", "Read all discussions" },
    { ":ReviewJump", "select_comment", "Jump to the selected discussion's diff line", "Discussion window" },
    { ":ReviewOpenComment", "open_comment", "Open the selected comment or reply in the browser", "Diff / discussion window" },
    { ":ReviewDrafts", "drafts", "Inspect, edit or delete local drafts" },
    { ":ReviewRefresh", "refresh", "Reload the review while preserving local drafts" },
    { ":ReviewSubmit", "submit", "Preview drafts and confirm publication or publication with a change request" },
    { ":ReviewApprove", false, "Approve the current MR/PR immediately without publishing drafts" },
    { ":ReviewRequestChanges", false, "Confirm requesting changes without publishing local drafts" },
    { ":ReviewClose", "close", "Close the review tab" },
    { ":w", "save_draft", "Save a draft locally and close its editor", "Comment editor" },
    { ":q!", "close_document", "Cancel draft editing without publishing", "Comment editor" },
  }) do
    add(unpack(item))
  end
  add(":ReviewToggleComments", "toggle_comments", "Show or hide inline discussions ("
    .. (session.inline_comments and "on" or "off") .. ")")
  for _, item in ipairs({
    { "open", "panel_open", "Open a commit/file or toggle a directory" },
    { "left", "panel_left", "Collapse a directory or move to its parent" },
    { "right", "panel_right", "Expand a directory or move to its first child" },
    { "toggle", "panel_toggle", "Toggle the selected directory" },
    { "expand", "panel_expand", "Expand the selected directory" },
    { "collapse", "panel_collapse", "Collapse the selected directory" },
    { "collapse_all", "panel_collapse_all", "Collapse all directories" },
    { "expand_all", "panel_expand_all", "Expand all directories" },
  }) do
    add(":ReviewPanel " .. item[1], item[2], item[3], "Panel")
  end
  if session.provider.pipelines then
    add(":ReviewPipelines", false, "Browse GitLab pipelines and jobs in Telescope")
    add("Open pipeline/job URL", "pipeline_open", "Open the selected pipeline or job in the browser", "Pipeline / jobs picker")
    add("Return to pipelines", "pipeline_back", "Return from the jobs picker to its pipelines", "Jobs picker")
  end
  if session.provider.resolve then
    add(":ReviewResolve", false, "Resolve the selected conversation immediately", "Diff / discussion window")
    add(":ReviewResolveAll", false, "Warn and confirm before resolving all open conversations")
  end
  require("review.telescope").help(entries)
end

function M.close(session)
  if session.ui_group then
    pcall(vim.api.nvim_del_augroup_by_id, session.ui_group)
    session.ui_group = nil
  end
  if session.filter_win and vim.api.nvim_win_is_valid(session.filter_win) then
    vim.api.nvim_win_close(session.filter_win, true)
  end
end

local function directory_folds(session)
  if vim.trim(session.file_filter or "") ~= "" then
    local comparison = (session.base or "") .. ":" .. (session.head or "")
    if session.filter_comparison ~= comparison then
      session.filtered_folds, session.filter_comparison = {}, comparison
    end
    session.filtered_folds = session.filtered_folds or {}
    return session.filtered_folds
  end
  session.directory_folds = session.directory_folds or {}
  local comparison = (session.base or "") .. ":" .. (session.head or "")
  session.directory_folds[comparison] = session.directory_folds[comparison] or {}
  return session.directory_folds[comparison]
end

local function file_tree(session)
  if not session.file_tree or session.file_tree.source ~= session.files
      or session.file_tree.query ~= (session.file_filter or "") then
    session.file_tree = tree.build(session.files or {}, session.file_filter)
  end
  return session.file_tree
end

function M.reveal_file(session, file)
  local folds = directory_folds(session)
  for _, path in ipairs(tree.parents(file.new_path)) do folds[path] = nil end
end

function M.focus_panel_entry(session, wanted)
  if not session.panel_win or not vim.api.nvim_win_is_valid(session.panel_win) then return false end
  for row, item in pairs(session.panel_entries or {}) do
    if (wanted.file and item.file == wanted.file)
        or (wanted.directory and item.directory == wanted.directory)
        or (wanted.commit ~= nil and item.commit == wanted.commit) then
      vim.api.nvim_win_set_cursor(session.panel_win, { row, 0 })
      return true
    end
  end
  return false
end

local function restore_panel_entry(session, item)
  if not item or M.focus_panel_entry(session, item) then return end
  local file = item.file and session.files[item.file]
  local path = item.directory or (file and file.new_path)
  local parents = path and tree.parents(path) or {}
  for index = #parents, 1, -1 do
    if M.focus_panel_entry(session, { directory = parents[index] }) then return end
  end
  M.focus_panel_entry(session, { commit = session.commit_index })
end

local function input_query(session)
  local lines = vim.api.nvim_buf_get_lines(session.filter_buf, 0, -1, false)
  local line = lines[#lines] or ""
  return line:sub(1, #filter_prompt) == filter_prompt and line:sub(#filter_prompt + 1) or line
end

local function sync_filter_input(session)
  if not session.filter_buf or not vim.api.nvim_buf_is_valid(session.filter_buf) then return end
  vim.api.nvim_buf_set_lines(session.filter_buf, 0, -1, false, { filter_prompt .. (session.file_filter or "") })
  vim.bo[session.filter_buf].modified = false
end

local function focus_filter_result(session)
  if M.focus_panel_entry(session, { file = session.file_index }) then return end
  for row = 1, vim.api.nvim_buf_line_count(session.panel_buf) do
    if (session.panel_entries[row] or {}).file then
      vim.api.nvim_win_set_cursor(session.panel_win, { row, 0 })
      return
    end
  end
  M.focus_panel_entry(session, { commit = session.commit_index })
end

function M.set_filter(session, query, from_input)
  if not M.valid(session) then return end
  assert(type(query) == "string", "The review file filter must be a string.")
  query = query:gsub("[\r\n]", " ")
  local row = vim.api.nvim_win_get_cursor(session.panel_win)[1]
  local anchor = (session.panel_entries or {})[row]
  if query ~= (session.file_filter or "") then session.filtered_folds = nil end
  session.file_filter = query
  M.panel(session)
  if not from_input then sync_filter_input(session) end
  if vim.trim(query) == "" then restore_panel_entry(session, anchor)
  else focus_filter_result(session) end
end

function M.finish_filter(session, query)
  if not M.valid(session) then return end
  query = query or input_query(session)
  session.filter_editing = false
  vim.cmd.stopinsert()
  M.set_filter(session, query)
  vim.api.nvim_set_current_win(session.panel_win)
  if vim.trim(query) == "" then restore_panel_entry(session, session.filter_anchor)
  else focus_filter_result(session) end
end

function M.filter(session)
  if not M.valid(session) or not vim.api.nvim_win_is_valid(session.panel_win) then return end
  if not session.filter_buf or not vim.api.nvim_buf_is_valid(session.filter_buf) then
    local buf = scratch("review://" .. session.serial .. "/filter", "review-filter")
    session.filter_buf = buf
    vim.bo[buf].buftype = "prompt"
    vim.fn.prompt_setprompt(buf, filter_prompt)
    sync_filter_input(session)
    vim.fn.prompt_setcallback(buf, function(query)
      session.filter_editing = false
      vim.schedule(function() if M.valid(session) then M.finish_filter(session, query) end end)
    end)
    vim.fn.prompt_setinterrupt(buf, function()
      local query = input_query(session)
      session.filter_editing = false
      vim.schedule(function() if M.valid(session) then M.finish_filter(session, query) end end)
    end)
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP" }, {
      group = session.ui_group, buffer = buf,
      callback = function()
        if M.valid(session) and session.filter_editing then
          local query = input_query(session)
          if query ~= session.file_filter then M.set_filter(session, query, true) end
        end
      end,
    })
    vim.api.nvim_create_autocmd("BufEnter", {
      group = session.ui_group, buffer = buf,
      callback = function()
        if not M.valid(session) then return end
        local row = vim.api.nvim_win_get_cursor(session.panel_win)[1]
        session.filter_anchor = (session.panel_entries or {})[row]
        session.filter_editing = true
      end,
    })
    vim.api.nvim_create_autocmd("BufLeave", {
      group = session.ui_group, buffer = buf,
      callback = function()
        if M.valid(session) and session.filter_editing then M.set_filter(session, input_query(session), true) end
        session.filter_editing = false
      end,
    })
    bind(session, buf, "filter_exit", function() M.finish_filter(session) end,
      "Return to the filtered review tree", { "n", "i" })
  end
  local root = file_tree(session)
  local width = math.max(1, vim.api.nvim_win_get_width(session.panel_win) - 2)
  local topline = vim.fn.getwininfo(session.panel_win)[1].topline - 1
  local last_row = math.max(0, vim.api.nvim_win_get_height(session.panel_win) - 3)
  -- Follow the reserved rows above the tree, then stay accessible at the top
  -- once the review metadata has scrolled out of view.
  local row = math.min(last_row, math.max(0, (session.filter_row or 0) - topline))
  local config = {
    relative = "win", win = session.panel_win, row = row, col = 0,
    width = width, height = 1, focusable = true, style = "minimal", border = "rounded",
    title = " Files ", title_pos = "left", footer = (" %d/%d "):format(root.count, root.total),
    footer_pos = "right",
  }
  if not session.filter_win or not vim.api.nvim_win_is_valid(session.filter_win) then
    session.filter_win = vim.api.nvim_open_win(session.filter_buf, false, config)
    vim.wo[session.filter_win].winhighlight = "NormalFloat:Normal,FloatBorder:ReviewFilterBorder,"
      .. "FloatTitle:ReviewPanelTitle,FloatFooter:ReviewHelp"
    vim.wo[session.filter_win].wrap = false
    vim.wo[session.filter_win].cursorline = false
  else
    vim.api.nvim_win_set_config(session.filter_win, config)
  end
  vim.api.nvim_buf_clear_namespace(session.filter_buf, filter_namespace, 0, -1)
  vim.api.nvim_buf_set_extmark(session.filter_buf, filter_namespace, 0, 0,
    { end_col = #filter_prompt, hl_group = "ReviewFilterPrompt", strict = false })
end

function M.start_filter(session)
  if not M.valid(session) then return end
  M.filter(session)
  sync_filter_input(session)
  vim.api.nvim_set_current_win(session.filter_win)
  session.filter_editing = true
  local line = vim.api.nvim_buf_get_lines(session.filter_buf, 0, 1, false)[1]
  vim.api.nvim_win_set_cursor(session.filter_win, { 1, #line })
  vim.cmd.startinsert({ bang = true })
end

function M.panel_action(session, action)
  if not M.valid(session) or not vim.api.nvim_win_is_valid(session.panel_win) then return end
  local row = vim.api.nvim_win_get_cursor(session.panel_win)[1]
  local item = (session.panel_entries or {})[row]
  if not session.files or #session.files == 0 then
    if item and item.commit ~= nil and (action == "open" or action == "right") then
      session:select_commit(item.commit)
    end
    return
  end
  local folds = directory_folds(session)
  if action == "collapse_all" or action == "expand_all" then
    for path in pairs(folds) do folds[path] = nil end
    if action == "collapse_all" then
      local function collapse(node)
        for _, child in ipairs(node.children) do
          if child.directory then folds[child.directory] = true; collapse(child) end
        end
      end
      collapse(file_tree(session))
    end
    M.panel(session)
    restore_panel_entry(session, item)
    return
  end
  if not item then return end
  local path = item.directory
  if action == "left" then
    if not path or folds[path] then
      if item.parent and item.parent ~= "" then M.focus_panel_entry(session, { directory = item.parent })
      elseif item.parent == "" then M.focus_panel_entry(session, { commit = session.commit_index }) end
      return
    end
    action = "collapse"
  elseif action == "right" and path and not folds[path] then
    local child = (session.panel_entries or {})[row + 1]
    if child and child.parent == path then vim.api.nvim_win_set_cursor(session.panel_win, { row + 1, 0 }) end
    return
  end
  if path then
    if action == "expand" or action == "right" then folds[path] = nil
    elseif action == "collapse" then folds[path] = true
    else folds[path] = not folds[path] or nil end
    M.panel(session)
    M.focus_panel_entry(session, { directory = path })
  elseif action == "open" or action == "right" then
    if item.file then session:select_file(item.file)
    elseif item.commit ~= nil then session:select_commit(item.commit) end
  elseif (action == "collapse" or action == "toggle") and item.parent and item.parent ~= "" then
    folds[item.parent] = true
    M.panel(session)
    M.focus_panel_entry(session, { directory = item.parent })
  end
end

function M.panel(session)
  if not M.valid(session) or not vim.api.nvim_buf_is_valid(session.panel_buf) then return end
  local lines = {
    session.provider.prefix .. session.target.iid .. " " .. (session.data and session.data.mr.title or "Loading…"),
    "",
  }
  if session.refreshing and session.data then lines[1] = lines[1] .. " · refreshing…" end
  local decorations = { { line = 1, start = 0, finish = #lines[1], group = "ReviewPanelTitle" } }
  session.panel_entries = {}
  local function highlight(line, start, finish, group)
    decorations[#decorations + 1] = { line = line, start = start, finish = finish, group = group }
  end
  local function entry(text, item, group, selected)
    lines[#lines + 1] = text
    session.panel_entries[#lines] = item
    highlight(#lines, 0, #text, group)
    if selected then
      decorations[#decorations + 1] = { line = #lines, selected = true }
    end
  end
  local review_status = session.data and session.data.status
  if review_status then
    local pipeline, review = review_status.pipeline, review_status.review
    local function status_line(text, state)
      lines[#lines + 1] = text:gsub("[\r\n]", " ")
      highlight(#lines, 0, #lines[#lines], status.highlight(state))
    end
    status_line("Pipeline: " .. status.label(pipeline.state)
      .. (pipeline.id and (" (#" .. pipeline.id .. ")") or ""), pipeline.state)
    local count = review.approvals and (" · " .. review.approvals
      .. (review.required and ("/" .. review.required) or "") .. " approval(s)") or ""
    status_line("Review: " .. status.label(review.state) .. count, review.state)
    for _, reviewer in ipairs(review.reviewers or {}) do
      status_line("  @" .. reviewer.username .. " · " .. status.label(reviewer.state)
        .. (reviewer.stale and " (stale)" or ""), reviewer.stale and "unknown" or reviewer.state)
    end
    lines[#lines + 1] = ""
  end
  if session.files and #session.files > 0 then
    local count = 0
    for _, file in ipairs(session.files) do
      if viewed.is(session.viewed, session.base, session.head, file) then count = count + 1 end
    end
    lines[#lines + 1] = session.viewed_error and "Viewed: unavailable"
      or ("Viewed: %d/%d files"):format(count, #session.files)
    highlight(#lines, 0, #lines[#lines], session.viewed_error and "ReviewStatusWarn" or "ReviewHelp")
    lines[#lines + 1] = ""
  end
  session.filter_row = #lines
  -- Three rows for the bordered input and one spacer before the first commit.
  for _ = 1, 4 do lines[#lines + 1] = "" end
  local function files()
    local status_groups = {
      A = "ReviewFileAdded", M = "ReviewFileModified", D = "ReviewFileDeleted",
      R = "ReviewFileRenamed", C = "ReviewFileAdded",
    }
    local folds = directory_folds(session)
    local selected = session.files and session.files[session.file_index or 0]
    local function children(parent, depth)
      for _, node in ipairs(parent.children) do
        local indent = (" "):rep(4 + depth * 2)
        local name = node.name:gsub("%c", " ")
        if node.directory then
          local closed = folds[node.directory] == true
          local prefix = node.directory .. "/"
          local contains_selected = closed and selected and selected.new_path:sub(1, #prefix) == prefix
          entry(indent .. (closed and "▸ " or "▾ ") .. name .. "/" .. (contains_selected and " ◀" or ""),
            { directory = node.directory, parent = node.parent }, "ReviewDirectory", contains_selected)
          if not closed then children(node, depth + 1) end
        else
          local file = session.files[node.file]
          local marked = viewed.is(session.viewed, session.base, session.head, file)
          local marker = session.viewed_error and "[?]" or marked and "[x]" or "[ ]"
          entry(("%s%s %s %s%s"):format(indent, marker, file.status, name,
            session.file_index == node.file and " ◀" or ""), { file = node.file, parent = node.parent },
            status_groups[file.status] or "ReviewFile", session.file_index == node.file)
          highlight(#lines, #indent, #indent + 3, marked and "ReviewFileViewed" or "ReviewHelp")
        end
      end
    end
    local root = file_tree(session)
    children(root, 0)
    if session.files and #session.files == 0 then lines[#lines + 1] = "    No changed files" end
    if root.total > 0 and root.count == 0 then lines[#lines + 1] = "    No files match this filter." end
  end
  entry((session.commit_index == 0 and "▾ " or "▸ ") .. "Complete " .. session.provider.label,
    { commit = 0 }, "ReviewCommit", session.commit_index == 0)
  if session.commit_index == 0 then files() end
  for index, commit in ipairs(session.data and session.data.commits or {}) do
    entry((session.commit_index == index and "▾ " or "▸ ") .. commit.id:sub(1, 8) .. " " .. commit.title,
      { commit = index }, "ReviewCommit", session.commit_index == index)
    highlight(#lines, #"▸ ", #"▸ " + #commit.id:sub(1, 8), "ReviewCommitSha")
    if session.commit_index == index then files() end
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = ("%d local draft(s)"):format(#session.drafts)
  highlight(#lines, 0, #lines[#lines], "ReviewDraftCount")
  set_lines(session.panel_buf, lines)
  vim.api.nvim_buf_clear_namespace(session.panel_buf, panel_namespace, 0, -1)
  for _, decoration in ipairs(decorations) do
    local opts = decoration.selected and { line_hl_group = "ReviewSelected", priority = 5 }
      or { end_col = decoration.finish, hl_group = decoration.group, priority = 10 }
    vim.api.nvim_buf_set_extmark(session.panel_buf, panel_namespace,
      decoration.line - 1, decoration.start or 0, opts)
  end
  M.filter(session)
end

function M.file_title(session, current)
  current = current or session.current
  local win = session.viewer_win
  if not current or not win or not vim.api.nvim_win_is_valid(win) then return end
  local marked = viewed.is(session.viewed, current.base, current.head, current.file)
  local title = current.file.new_path .. " · "
    .. (session.commit_index == 0 and "complete " .. session.provider.kind or current.head:sub(1, 8))
    .. (session.viewed_error and " · [viewed unavailable]" or marked and " · [viewed]" or " · [unviewed]")
  vim.wo[win].winbar = title:gsub("%%", "%%%%")
end

function M.render(session, current)
  if not M.valid(session) then return end
  local buf, win = session.viewer_buf, session.viewer_win
  if not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_win_is_valid(win) then return end
  vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
  vim.api.nvim_buf_clear_namespace(buf, comment_namespace, 0, -1)
  M.file_title(session, current)
  if not current.rows then
    set_lines(buf, { current.error or "Unable to display this file." })
    vim.bo[buf].filetype = ""
    return
  end
  local lines = {}
  for _, row in ipairs(current.rows) do lines[#lines + 1] = row.text end
  set_lines(buf, #lines > 0 and lines or { "" })
  vim.bo[buf].filetype = vim.filetype.match({ filename = current.file.new_path }) or ""
  vim.bo[buf].readonly = true
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].wrap = false
  vim.wo[win].signcolumn = "no"
  for i, row in ipairs(current.rows) do
    local change = row.kind == "add" and "DiffAdd" or row.kind == "delete" and "DiffDelete" or nil
    local number = ("%5s %5s %s "):format(row.old_line or "", row.new_line or "",
      row.kind == "add" and "+" or row.kind == "delete" and "-" or " ")
    vim.api.nvim_buf_set_extmark(buf, namespace, i - 1, 0, {
      virt_text = { { number, change or "LineNr" } },
      virt_text_pos = "inline",
      line_hl_group = change,
      hl_eol = change ~= nil,
      priority = 10,
    })
    for _, span in ipairs(row.spans or {}) do
      if span[2] > span[1] then
        vim.api.nvim_buf_set_extmark(buf, namespace, i - 1, span[1], {
          end_col = span[2], hl_group = "DiffText", priority = 20,
        })
      end
    end
  end
  M.comments(session)
  -- A different line number belongs to each side; the buffer's own number
  -- includes deleted rows and must never be used for a provider position.
  vim.api.nvim_win_set_cursor(win, { 1, 0 })
  if not session.filter_editing then vim.api.nvim_set_current_win(win) end
end

-- Wrap virtual text ourselves: virt_lines do not follow the window's wrap option.
local function wrap_comment(text, width)
  local chars = vim.fn.split(text:gsub("\t", "    "):gsub("\r", ""), "\\zs")
  local lines, first = {}, 1
  while first <= #chars do
    local last, space, cells = first - 1, nil, 0
    while last < #chars do
      local char = chars[last + 1]
      local size = vim.fn.strdisplaywidth(char, cells)
      if cells + size > width and last >= first then break end
      last, cells = last + 1, cells + size
      if char:match("%s") then space = last end
    end
    if last < #chars and space then last = space end
    lines[#lines + 1] = table.concat(chars, "", first, last)
    first = last + 1
  end
  return #lines > 0 and lines or { "" }
end

local function inline_discussion(session, discussion)
  local root = threads.root(discussion)
  local anchor = threads.anchor(discussion, session.current)
  if not root or not anchor then return {} end
  local width = math.max(1, vim.api.nvim_win_get_width(session.viewer_win) - 6)
  local lines = {}
  local function append(prefix, text, group)
    for index, part in ipairs(wrap_comment(text, width)) do
      lines[#lines + 1] = {
        { index == 1 and prefix or "  │  ", "ReviewCommentBorder" },
        { part, group },
      }
    end
  end
  local status = root.resolved and "Resolved discussion"
    or root.outdated and "Outdated discussion" or "Discussion"
  local range = anchor.first ~= anchor.last and (anchor.first .. "–" .. anchor.last) or tostring(anchor.last)
  for _, note in ipairs(discussion.notes) do
    if not note.system then
      local author = "@" .. ((note.author or {}).username or "unknown"):gsub("[\r\n\t]", " ")
      if note == root then
        append("  ╭─ ", author .. " · " .. status .. " · " .. anchor.side .. " " .. range, "ReviewCommentAuthor")
      else
        append("  │  ", "", "ReviewCommentBody")
        append("  │  ", author, "ReviewCommentAuthor")
      end
      for _, text in ipairs(vim.split(emoji.render(note.body or ""), "\n", { plain = true })) do
        append("  │  ", text, "ReviewCommentBody")
      end
      local reaction_text = reactions.text(note)
      if reaction_text then append("  │  ", reaction_text, "ReviewCommentReaction") end
    end
  end
  append("  ╰─ ", (M.key(session, "thread") or ":ReviewThread") .. ": full discussion · "
    .. (M.reply_key(session) or ":ReviewReply") .. ": reply · "
    .. (M.open_comment_key(session) or ":ReviewOpenComment") .. ": browser", "ReviewHelp")
  return lines
end

function M.comments(session)
  local current, buf = session.current, session.viewer_buf
  if not current or not current.rows or not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  vim.api.nvim_buf_clear_namespace(buf, comment_namespace, 0, -1)
  local labels, blocks = {}, {}
  local function mark(old_line, new_line, text)
    for i, row in ipairs(current.rows) do
      if (new_line and row.new_line == new_line) or (not new_line and old_line and row.old_line == old_line) then
        labels[i] = labels[i] or {}
        labels[i][#labels[i] + 1] = text
        break
      end
    end
  end
  for _, draft in ipairs(session.drafts) do
    local d = draft.display
    local label = draft.reply and "local reply" or "local draft"
    if d and d.head == current.head and d.base == current.base and d.path == current.file.new_path then
      mark(d.old_line, d.new_line, label)
    elseif draft.position.new_path == current.file.new_path and draft.position.head_sha == current.head then
      local p = draft.position
      mark(p.base_sha == current.base and p.old_line or nil, p.new_line, label)
    end
  end
  for _, discussion in ipairs(session.data and session.data.discussions or {}) do
    local row = threads.row(discussion, current)
    if row then
      labels[row] = labels[row] or {}
      labels[row][#labels[row] + 1] = "discussion (" .. (M.key(session, "thread") or ":ReviewThread") .. ")"
      if session.inline_comments then
        blocks[row] = blocks[row] or {}
        vim.list_extend(blocks[row], inline_discussion(session, discussion))
      end
    end
  end
  for row, texts in pairs(labels) do
    vim.api.nvim_buf_set_extmark(buf, comment_namespace, row - 1, 0, {
      virt_text = { { "  ● " .. table.concat(texts, " · "), "Comment" } },
      virt_text_pos = "eol", priority = 30,
      virt_lines = blocks[row], virt_lines_leftcol = true,
    })
  end
end

function M.empty(session, message)
  if M.valid(session) and vim.api.nvim_buf_is_valid(session.viewer_buf) then
    vim.api.nvim_buf_clear_namespace(session.viewer_buf, namespace, 0, -1)
    vim.api.nvim_buf_clear_namespace(session.viewer_buf, comment_namespace, 0, -1)
    set_lines(session.viewer_buf, { message })
  end
end

local function float(title, lines, writable, config)
  serial = serial + 1
  local buf = scratch("review://float/" .. serial, "markdown")
  set_lines(buf, lines)
  vim.bo[buf].modifiable = writable or false
  if writable then vim.bo[buf].buftype = "acwrite" end
  local width = math.max(20, math.min(90, vim.o.columns - 6))
  local height = math.max(3, math.min(22, vim.o.lines - 6))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor", width = width, height = height,
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    style = "minimal", border = "rounded", title = " " .. title .. " ",
  })
  vim.wo[win].wrap = true
  local close_key = (config.keymaps or {}).close_document
  if close_key then
    vim.keymap.set("n", close_key, function() vim.api.nvim_win_close(win, true) end,
      { buffer = buf, silent = true, desc = "Close this review window" })
  end
  return buf, win
end

function M.compose(title, body, saved, config)
  config = config or require("review").config
  local save_key = (config.keymaps or {}).save_draft
  local buf, win = float(title .. " · " .. (save_key and save_key .. " or " or "") .. ":w saves locally",
    vim.split(body or "", "\n"), true, config)
  local function save()
    local text = vim.trim(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
    if text == "" then
      vim.notify("The comment is empty.", vim.log.levels.WARN, { title = "review" })
      return
    end
    local ok, err = pcall(saved, text)
    if not ok then vim.notify(tostring(err), vim.log.levels.ERROR, { title = "review" }); return end
    vim.bo[buf].modified = false
    vim.cmd.stopinsert()
    vim.api.nvim_win_close(win, true)
    vim.notify("Comment saved as a local draft.", vim.log.levels.INFO, { title = "review" })
  end
  vim.api.nvim_create_autocmd("BufWriteCmd", { buffer = buf, callback = save })
  if save_key then
    vim.keymap.set({ "n", "i" }, save_key, save, { buffer = buf, silent = true, desc = "Save local draft" })
  end
  return buf, win
end

function M.document(title, lines, opts)
  opts = opts or {}
  local config = opts.config or require("review").config
  local buf, win = float(title, #lines > 0 and lines or { opts.empty or "Nothing to display." }, false, config)
  if opts.on_select then
    vim.wo[win].cursorline = true
    local function close()
      if not vim.api.nvim_win_is_valid(win) then return false end
      vim.api.nvim_win_close(win, true)
      return true
    end
    local select_key = (config.keymaps or {}).select_comment
    if select_key then
      vim.keymap.set("n", select_key, function()
        local entry = (opts.entries or {})[vim.api.nvim_win_get_cursor(win)[1]]
        if entry then opts.on_select(entry, close) end
      end, { buffer = buf, silent = true, desc = "Jump to the comment line" })
    end
  end
  return buf, win
end

function M.update_document(buf, lines)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  set_lines(buf, #lines > 0 and lines or { "No discussions in this review." })
end

return M
