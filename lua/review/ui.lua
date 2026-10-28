local M = {}
local namespace = vim.api.nvim_create_namespace("review")
local comment_namespace = vim.api.nvim_create_namespace("review.comments")
local panel_namespace = vim.api.nvim_create_namespace("review.panel")
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
    ReviewSelected = "CursorLine",
    ReviewDraftCount = "Special",
    ReviewHelp = "Comment",
  }
  for name, link in pairs(links) do vim.api.nvim_set_hl(0, name, { default = true, link = link }) end
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

function M.comment_key(session)
  local key = (session.config.keymaps or {}).comment
  if key == nil then return "<leader>rc" end
  return key
end

function M.submit_key(session)
  local key = (session.config.keymaps or {}).submit
  if key == nil then return "<leader>rs" end
  return key
end

function M.refresh_key(session)
  local key = (session.config.keymaps or {}).refresh
  if key == nil then return "<leader>rr" end
  return key
end

function M.bind(session, buf)
  local maps = {
    ["]c"] = function() session:move_commit(1) end,
    ["[c"] = function() session:move_commit(-1) end,
    ["]f"] = function() session:move_file(1) end,
    ["[f"] = function() session:move_file(-1) end,
    ["]h"] = function() session:move_hunk(1, vim.v.count1) end,
    ["[h"] = function() session:move_hunk(-1, vim.v.count1) end,
    ["gA"] = function() session:select_commit(0) end,
    ["gd"] = function() session:show_drafts() end,
    ["gt"] = function() session:show_threads() end,
    ["q"] = function() session:close() end,
  }
  for key, callback in pairs(maps) do
    vim.keymap.set("n", key, callback, { buffer = buf, silent = true })
  end
  local submit_key = M.submit_key(session)
  if submit_key then
    vim.keymap.set("n", submit_key, function() session:submit() end,
      { buffer = buf, silent = true, desc = "Preview and submit review drafts" })
  end
  local refresh_key = M.refresh_key(session)
  if refresh_key then
    vim.keymap.set("n", refresh_key, function() session:refresh() end,
      { buffer = buf, silent = true, desc = "Refresh the review" })
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
  vim.wo[session.panel_win].winfixwidth = true
  vim.wo[session.panel_win].cursorline = true
  session.ui_group = vim.api.nvim_create_augroup("ReviewUI" .. serial, { clear = true })
  vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
    group = session.ui_group,
    callback = function() M.footer(session) end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = session.ui_group,
    pattern = tostring(session.panel_win),
    callback = function() M.close(session) end,
  })
  M.bind(session, session.panel_buf)
  M.bind(session, session.viewer_buf)
  vim.keymap.set("n", "<CR>", function()
    local entry = session.panel_entries[vim.api.nvim_win_get_cursor(session.panel_win)[1]]
    if entry then
      if entry.file then session:select_file(entry.file)
      else session:select_commit(entry.commit) end
    end
  end, { buffer = session.panel_buf, silent = true })
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
  vim.api.nvim_set_current_win(session.viewer_win)
  set_lines(session.viewer_buf, { "Loading review…" })
  M.panel(session)
end

local function footer_hints(session)
  return {
    " Enter open · gA complete " .. session.provider.kind,
    " " .. (M.comment_key(session) or ":ReviewComment") .. " comment line/range",
    " ]c/[c commits · ]f/[f files",
    " ]h/[h next/previous change",
    " gd drafts · gt discussions",
    " " .. (M.refresh_key(session) or ":ReviewRefresh") .. " refresh " .. session.provider.kind,
    " " .. (M.submit_key(session) or ":ReviewSubmit") .. " submit · q close",
  }
end

-- A non-focusable footer remains at the bottom even when the tree scrolls.
-- Blank tail rows and scrolloff keep selectable entries above the overlay.
function M.footer(session)
  if not M.valid(session) or not vim.api.nvim_win_is_valid(session.panel_win) then return end
  local hints = footer_hints(session)
  local panel_height = vim.api.nvim_win_get_height(session.panel_win)
  local height = math.min(#hints, math.max(1, panel_height - 2))
  local width = vim.api.nvim_win_get_width(session.panel_win)
  local row = panel_height - height
  if not session.help_buf or not vim.api.nvim_buf_is_valid(session.help_buf) then
    session.help_buf = scratch("review://" .. session.serial .. "/help", "review")
    set_lines(session.help_buf, hints)
  end
  if not session.help_win or not vim.api.nvim_win_is_valid(session.help_win) then
    session.help_win = vim.api.nvim_open_win(session.help_buf, false, {
      relative = "win", win = session.panel_win, row = row, col = 0,
      width = width, height = height, focusable = false, style = "minimal", zindex = 40,
    })
    vim.wo[session.help_win].winhighlight = "Normal:ReviewHelp,NormalFloat:ReviewHelp,EndOfBuffer:ReviewHelp"
    vim.wo[session.help_win].wrap = false
  else
    local current = vim.api.nvim_win_get_config(session.help_win)
    if current.row ~= row or current.width ~= width or current.height ~= height then
      vim.api.nvim_win_set_config(session.help_win, {
        relative = "win", win = session.panel_win, row = row, col = 0,
        width = width, height = height,
      })
    end
  end
  vim.wo[session.panel_win].scrolloff = height
end

function M.close(session)
  if session.ui_group then
    pcall(vim.api.nvim_del_augroup_by_id, session.ui_group)
    session.ui_group = nil
  end
  if session.help_win and vim.api.nvim_win_is_valid(session.help_win) then
    vim.api.nvim_win_close(session.help_win, true)
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
  local function files()
    local status_groups = {
      A = "ReviewFileAdded", M = "ReviewFileModified", D = "ReviewFileDeleted",
      R = "ReviewFileRenamed", C = "ReviewFileAdded",
    }
    for index, file in ipairs(session.files or {}) do
      entry(("    %s %s%s"):format(file.status, file.new_path,
        session.file_index == index and " ◀" or ""), { file = index },
        status_groups[file.status] or "ReviewFile", session.file_index == index)
      local directory = file.new_path:match("^(.*/)")
      if directory then highlight(#lines, 6, 6 + #directory, "ReviewDirectory") end
    end
    if session.files and #session.files == 0 then lines[#lines + 1] = "    No changed files" end
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
  for _ = 1, #footer_hints(session) do lines[#lines + 1] = "" end
  set_lines(session.panel_buf, lines)
  vim.api.nvim_buf_clear_namespace(session.panel_buf, panel_namespace, 0, -1)
  for _, decoration in ipairs(decorations) do
    local opts = decoration.selected and { line_hl_group = "ReviewSelected", priority = 5 }
      or { end_col = decoration.finish, hl_group = decoration.group, priority = 10 }
    vim.api.nvim_buf_set_extmark(session.panel_buf, panel_namespace,
      decoration.line - 1, decoration.start or 0, opts)
  end
  M.footer(session)
end

function M.render(session, current)
  if not M.valid(session) then return end
  local buf, win = session.viewer_buf, session.viewer_win
  if not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_win_is_valid(win) then return end
  vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
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
  local title = current.file.new_path .. " · "
    .. (session.commit_index == 0 and "complete " .. session.provider.kind or current.head:sub(1, 8))
  vim.wo[win].winbar = title:gsub("%%", "%%%%")
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
  vim.api.nvim_set_current_win(win)
end

function M.comments(session)
  local current, buf = session.current, session.viewer_buf
  if not current or not current.rows or not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  vim.api.nvim_buf_clear_namespace(buf, comment_namespace, 0, -1)
  local labels = {}
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
    if d and d.head == current.head and d.base == current.base and d.path == current.file.new_path then
      mark(d.old_line, d.new_line, "local draft")
    elseif draft.position.new_path == current.file.new_path and draft.position.head_sha == current.head then
      local p = draft.position
      mark(p.base_sha == current.base and p.old_line or nil, p.new_line, "local draft")
    end
  end
  for _, discussion in ipairs(session.data and session.data.discussions or {}) do
    local first = discussion.notes and discussion.notes[1]
    local p = first and first.position
    if p and p ~= vim.NIL and p.new_path == current.file.new_path and p.head_sha == current.head then
      mark(p.base_sha == current.base and p.old_line or nil, p.new_line, "discussion (gt)")
    end
  end
  for row, texts in pairs(labels) do
    vim.api.nvim_buf_set_extmark(buf, comment_namespace, row - 1, 0, {
      virt_text = { { "  ● " .. table.concat(texts, " · "), "Comment" } },
      virt_text_pos = "eol", priority = 30,
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

local function float(title, lines, writable)
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
  vim.keymap.set("n", "q", function() vim.api.nvim_win_close(win, true) end, { buffer = buf })
  return buf, win
end

function M.compose(title, body, saved)
  local buf, win = float(title .. " · Ctrl-S or :w saves locally", vim.split(body or "", "\n"), true)
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
  vim.keymap.set({ "n", "i" }, "<C-s>", save, { buffer = buf, desc = "Save local draft" })
  return buf, win
end

function M.document(title, lines)
  return float(title, #lines > 0 and lines or { "No discussions on this file." }, false)
end

return M
