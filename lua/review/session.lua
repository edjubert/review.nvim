local async = require("review.async")
local providers = require("review.providers")
local git = require("review.git")
local diff = require("review.diff")
local position = require("review.position")
local drafts = require("review.drafts")
local threads = require("review.threads")
local ui = require("review.ui")
local Session = {}
Session.__index = Session

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "review" })
end

function Session.new(target, config)
  return setmetatable({
    target = target, config = config, drafts = drafts.load(config, target),
    provider = providers.for_target(target),
    inline_comments = config.inline_comments == true,
    thread_documents = {},
    commit_index = 0, files = {}, closed = false, generation = 0,
  }, Session)
end

function Session:task(fn, on_error, generation)
  async.run(fn, function(err)
    if generation and generation ~= self.generation then return end
    if on_error then on_error(err) end
    if not self.closed then
      self.error = err
      notify(err, vim.log.levels.ERROR)
      if not self.current then ui.empty(self, err) end
    end
  end)
end

function Session:load()
  ui.create(self)
  self:refresh()
end

function Session:refresh()
  if not ui.valid(self) then
    notify("Open a review with :Review first.", vim.log.levels.WARN)
    return
  end
  if self.submitting or self.approving then
    notify("Wait for the current review operation to finish.", vim.log.levels.WARN)
    return
  end
  if self.refreshing then
    notify("The review is already refreshing.")
    return
  end
  local initial = not self.data
  local commit = self.data and self.data.commits[self.commit_index]
  local file = self.files[self.file_index or 0]
  local selection = {
    commit = commit and commit.id,
    path = file and file.new_path,
    base = self.base,
    head = self.head,
    cursor = vim.api.nvim_win_is_valid(self.viewer_win)
      and vim.api.nvim_win_get_cursor(self.viewer_win) or nil,
    panel_focused = vim.api.nvim_get_current_win() == self.panel_win,
  }
  self.refreshing = true
  self.generation = self.generation + 1
  local generation = self.generation
  self.error = nil
  ui.panel(self)
  if not self.current then
    ui.empty(self, initial and "Loading review…" or "Refreshing review…")
  end
  self:task(function()
    local data = self.provider.load(self.target)
    local config = vim.deepcopy(self.config)
    -- A refresh must use the same repository even if the current cwd changed.
    config.repo = self.repo or config.repo
    local repo = git.prepare(self.target, data.project, config)
    for _, sha in ipairs({ data.mr.diff_refs.base_sha, data.mr.diff_refs.head_sha }) do
      git.ensure(repo, sha, data.project, config)
    end
    local latest = self.provider.current(self.target)
    if not position.same_refs(data.mr.diff_refs, latest.diff_refs) then
      error("The review changed while loading. Run :ReviewRefresh to try again.", 0)
    end
    if generation ~= self.generation then return end
    self.refreshing = false
    if not ui.valid(self) then return end
    local index = initial and #data.commits > 0 and 1 or 0
    if selection.commit then
      for i, candidate in ipairs(data.commits) do
        if candidate.id == selection.commit then index = i; break end
      end
    end
    self.data, self.repo, self.ready = data, repo, true
    self.error = nil
    self:select_commit(index, selection)
    if not initial then notify("Review refreshed.") end
  end, function()
    self.refreshing = false
    ui.panel(self)
    -- Resume an old view whose pending load was invalidated by this refresh.
    if self.ready and not self.current and not self.closed then
      self:select_commit(self.commit_index, selection)
    end
  end, generation)
end

function Session:select_commit(index, selection)
  if not self.ready or self.closed or self.refreshing or index < 0 or index > #self.data.commits then return end
  self.generation = self.generation + 1
  local generation = self.generation
  self.commit_index, self.current, self.files, self.file_index = index, nil, {}, nil
  ui.empty(self, "Loading changed files…")
  self:task(function()
    local refs = self.data.mr.diff_refs
    local base, head = refs.base_sha, refs.head_sha
    if index > 0 then
      local commit = self.data.commits[index]
      base, head = commit.parent_ids[1], commit.id
      if not base then error("Root commits are not supported yet.", 0) end
      git.ensure(self.repo, base, self.data.project, self.config)
      git.ensure(self.repo, head, self.data.project, self.config)
    end
    local files = git.files(self.repo, base, head)
    if generation ~= self.generation or self.closed then return end
    self.base, self.head, self.files = base, head, files
    ui.panel(self)
    local file_index = 1
    if selection and selection.path then
      local found = false
      for i, file in ipairs(files) do
        if file.new_path == selection.path then file_index, found = i, true; break end
      end
      if selection.require_path and not found then
        ui.empty(self, "The commented file is not part of this comparison.")
        notify("The commented file is not part of this comparison.", vim.log.levels.WARN)
        return
      end
    end
    if #files > 0 then self:select_file(file_index, selection)
    else ui.empty(self, "This comparison contains no changed files.") end
  end, nil, generation)
end

function Session:select_file(index, selection)
  local file = self.files[index]
  if not file or self.closed or self.refreshing then return end
  self.generation = self.generation + 1
  local generation, base, head = self.generation, self.base, self.head
  self.file_index, self.current = index, nil
  ui.empty(self, "Loading " .. file.new_path .. "…")
  ui.panel(self)
  self:task(function()
    local old = file.new_file and "" or git.content(self.repo, base, file.old_path)
    local new = file.deleted_file and "" or git.content(self.repo, head, file.new_path)
    local rows, err = diff.build(old, new)
    if generation ~= self.generation or self.closed then return end
    local current = { file = file, base = base, head = head, old = old, new = new, rows = rows, error = err }
    if rows then self:map_threads(current, generation) end
    if generation ~= self.generation or self.closed then return end
    self.current = current
    ui.render(self, self.current)
    if not ui.valid(self) then return end
    if rows and vim.api.nvim_win_is_valid(self.viewer_win) then
      local cursor = { diff.hunk_starts(rows)[1] or 1, 0 }
      if selection and selection.focus_line then
        local target, found = selection.focus_line, false
        for line, row in ipairs(rows) do
          if row[target.side .. "_line"] == target.line then cursor, found = { line, 0 }, true; break end
        end
        if not found then notify("The comment's line is unavailable in this diff.", vim.log.levels.WARN) end
      elseif selection and selection.cursor and #rows > 0
          and selection.path == file.new_path and selection.base == base and selection.head == head then
        local line = math.min(selection.cursor[1], #rows)
        cursor = { line, math.min(selection.cursor[2], math.max(0, #rows[line].text - 1)) }
      end
      vim.api.nvim_win_set_cursor(self.viewer_win, cursor)
      vim.api.nvim_win_call(self.viewer_win, function()
        vim.cmd.normal({ args = { "zvzz" }, bang = true })
      end)
    end
    if selection and selection.panel_focused and vim.api.nvim_win_is_valid(self.panel_win) then
      vim.api.nvim_set_current_win(self.panel_win)
    end
  end, nil, generation)
end

-- Map current-review discussions into a commit snapshot using unchanged lines.
-- Historical refs are fetched only on an explicit jump, never while rendering.
function Session:map_threads(current, generation)
  current.thread_anchors = {}
  local refs, maps, renames = self.data.mr.diff_refs, {}, {}
  local function destination_path(anchor, source, destination)
    local paths = renames[anchor.side]
    if paths == nil then
      local ok, files = pcall(git.files, self.repo, source, destination)
      paths = ok and {} or false
      if ok then
        for _, file in ipairs(files) do paths[file.old_path] = not file.deleted_file and file.new_path or false end
      end
      renames[anchor.side] = paths
    end
    if not paths then return nil end
    local path = paths[anchor.path]
    return path == nil and anchor.path or path
  end
  for _, discussion in ipairs(self.data.discussions) do
    local anchor = threads.anchor(discussion)
    if anchor then
      local old = anchor.side == "old"
      local source = old and refs.base_sha or refs.head_sha
      local destination = old and current.base or current.head
      local path = old and current.file.old_path or current.file.new_path
      if anchor.sha == source and source ~= destination then
        local key = anchor.side .. "\0" .. anchor.path
        if maps[key] == nil then
          local ok, map = pcall(function()
            if destination_path(anchor, source, destination) ~= path then return false end
            local original = git.content(self.repo, source, anchor.path)
            return diff.line_map(original, old and current.old or current.new)
          end)
          if generation ~= self.generation or self.closed then return end
          maps[key] = ok and map or false
        end
        local map = maps[key]
        local first = map and map[anchor.first]
        local valid = first and anchor.first <= anchor.last and anchor.last - anchor.first < #current.rows
        if valid then
          for line = anchor.first, anchor.last do
            if map[line] ~= first + line - anchor.first then valid = false; break end
          end
        end
        if valid then
          current.thread_anchors[discussion] = vim.tbl_extend("force", anchor, {
            sha = destination, path = path, first = first, last = map[anchor.last],
          })
        end
      end
    end
  end
end

function Session:move_commit(delta)
  self:select_commit(self.commit_index + delta)
end

function Session:move_file(delta)
  self:select_file((self.file_index or 0) + delta)
end

function Session:move_hunk(direction, count)
  if self.refreshing or not self.current or not self.current.rows or not vim.api.nvim_win_is_valid(self.viewer_win) then
    return
  end
  local line = vim.api.nvim_win_get_cursor(self.viewer_win)[1]
  local destination = diff.jump(self.current.rows, line, direction, count)
  if not destination then
    notify(direction > 0 and "No next change block in this file." or "No previous change block in this file.")
    return
  end
  vim.api.nvim_set_current_win(self.viewer_win)
  vim.api.nvim_win_set_cursor(self.viewer_win, { destination, 0 })
  vim.cmd.normal({ args = { "zvzz" }, bang = true })
end

-- A commit snapshot is mapped to the current review diff, with unchanged lines
-- only. Never guess a position for code that later commits rewrote.
function Session:comment_position(current, first, last)
  local selected = {}
  for i = first, last do
    if not current.rows[i] then error("Select lines inside the diff.", 0) end
    selected[#selected + 1] = current.rows[i]
  end
  local side, side_error = position.side(selected)
  if not side then error(side_error, 0) end
  local refs = self.data.mr.diff_refs
  local source_sha = side == "old" and current.base or current.head
  local destination_sha = side == "old" and refs.base_sha or refs.head_sha
  local source_path = side == "old" and current.file.old_path or current.file.new_path
  local destination_path = git.rename_path(self.repo, source_sha, destination_sha, source_path)
  if not destination_path then error("This file no longer exists in the current review diff.", 0) end
  local mr_file
  for _, file in ipairs(self.data.diffs) do
    if file[side == "old" and "old_path" or "new_path"] == destination_path then mr_file = file; break end
  end
  if not mr_file or not mr_file.diff or mr_file.diff == "" then
    error(self.provider.name .. " has no commentable diff for this file. Open the complete review or use the web interface.", 0)
  end
  local source_content = side == "old" and current.old or current.new
  local destination_content = git.content(self.repo, destination_sha, destination_path)
  local map = diff.line_map(source_content, destination_content)
  local parsed = diff.patch(mr_file.diff)
  local key, mapped = side .. "_line", {}
  for _, row in ipairs(selected) do
    local mapped_line = row[key] and map[row[key]]
    if not mapped_line then
      error("A later commit changed this line. Select its current position in the complete review view (gA).", 0)
    end
    local target_row = parsed["by_" .. side][mapped_line]
    if not target_row then error("This line is outside " .. self.provider.name .. "'s commentable diff context.", 0) end
    mapped[#mapped + 1] = target_row
  end
  local result, err = self.provider.build_position(refs, mr_file, mapped)
  if not result then error(err, 0) end
  return result
end

function Session:save_draft(body, target_position, commit, display, reply)
  local updated = vim.deepcopy(self.drafts)
  updated[#updated + 1] = drafts.new(body, target_position, commit, display, reply)
  drafts.save(self.config, self.target, updated)
  self.drafts = updated
  ui.panel(self)
  ui.comments(self)
end

function Session:comment(first, last)
  if self.refreshing then notify("Wait for the review refresh to finish.", vim.log.levels.WARN); return end
  if not self.current or not self.current.rows then notify("Open a text diff first.", vim.log.levels.WARN); return end
  local current = self.current
  local generation = self.generation
  self:task(function()
    local target_position = self:comment_position(current, first, last)
    if generation ~= self.generation or not ui.valid(self) then return end
    local label = current.file.new_path .. " · " .. first .. (last ~= first and "–" .. last or "")
    ui.compose(label, "", function(body)
      local row = current.rows[last]
      self:save_draft(body, target_position, current.head, {
        path = current.file.new_path, base = current.base, head = current.head,
        old_line = row.old_line, new_line = row.new_line,
      })
    end)
  end, nil, generation)
end

function Session:reply()
  if self.refreshing then notify("Wait for the review refresh to finish.", vim.log.levels.WARN); return end
  if self.submitting then notify("Wait for comment submission to finish.", vim.log.levels.WARN); return end
  if not self.data or not self.current or not self.current.rows
      or vim.api.nvim_get_current_buf() ~= self.viewer_buf then
    notify("Use :ReviewReply on a commented review diff line.", vim.log.levels.WARN)
    return
  end
  local selected, row = {}, vim.api.nvim_win_get_cursor(self.viewer_win)[1]
  for _, discussion in ipairs(self.data.discussions or {}) do
    if threads.contains(discussion, self.current, row) then selected[#selected + 1] = discussion end
  end
  if #selected == 0 then notify("No discussion on this line. Use gT to see all discussions."); return end
  if not self.provider.reply_target or not self.provider.reply or not self.provider.validate_reply then
    notify("Reply drafts are not supported by the " .. self.provider.name .. " provider.", vim.log.levels.WARN)
    return
  end
  local current, generation = self.current, self.generation
  local function compose(discussion)
    if not discussion or generation ~= self.generation or not ui.valid(self) then return end
    local destination, err = self.provider.reply_target(discussion)
    if not destination then notify(err, vim.log.levels.WARN); return end
    local root, anchor = threads.root(discussion), threads.anchor(discussion, current)
    local author = ((root.author or {}).username or "unknown"):gsub("[\r\n\t]", " ")
    destination.author, destination.body = author, root.body or ""
    local p = vim.tbl_extend("force", vim.deepcopy(root.position), self.data.mr.diff_refs)
    local display = { path = current.file.new_path, base = current.base, head = current.head,
      [anchor.side .. "_line"] = anchor.last }
    ui.compose(("Reply to @%s · %s:%d"):format(author, current.file.new_path, anchor.last), "", function(body)
      if not ui.valid(self) then error("The review is closed. Reopen it before saving this reply.", 0) end
      self:save_draft(body, p, current.head, display, destination)
    end)
  end
  if #selected == 1 then compose(selected[1]); return end
  vim.ui.select(selected, {
    prompt = "Reply to which discussion?",
    format_item = function(discussion)
      local root = threads.root(discussion)
      return ("@%s · %s"):format((root.author or {}).username or "unknown",
        (root.body or ""):gsub("[\r\n]", " "))
    end,
  }, compose)
end

function Session:show_drafts()
  if #self.drafts == 0 then notify("No local drafts."); return end
  vim.ui.select(self.drafts, {
    prompt = "Local review drafts",
    format_item = function(draft)
      local p = draft.position
      return (draft.reply and ("Reply to @" .. (draft.reply.author or "unknown") .. " · ") or "")
        .. (p.new_path or p.old_path) .. ":" .. (p.new_line or p.old_line)
        .. (draft.status and (" [" .. draft.status .. "]") or "") .. " · " .. draft.body:gsub("\n", " ")
    end,
  }, function(draft)
    if not draft then return end
    local actions = { "Edit locally", "Delete locally" }
    local retry_action = "Allow retry after checking " .. self.provider.name
    if draft.status == "uncertain" or draft.status == "sending" then
      actions[#actions + 1] = retry_action
    end
    vim.ui.select(actions, { prompt = "Draft action" }, function(action)
      if action == "Edit locally" then
        ui.compose("Edit local draft", draft.body, function(body)
          draft.body = body
          drafts.save(self.config, self.target, self.drafts)
        end)
      elseif action == "Delete locally" then
        for i, candidate in ipairs(self.drafts) do
          if candidate.id == draft.id then table.remove(self.drafts, i); break end
        end
        drafts.save(self.config, self.target, self.drafts)
        ui.panel(self)
        ui.comments(self)
      elseif action == retry_action then
        draft.status = nil
        drafts.save(self.config, self.target, self.drafts)
      end
    end)
  end)
end

function Session:show_info()
  if not ui.valid(self) then return end
  if not self.data then
    notify("The review metadata is not loaded yet.", vim.log.levels.WARN)
    return
  end
  local review = self.data.mr
  local title = type(review.title) == "string" and review.title:gsub("[\r\n]", " ") or "Untitled review"
  local description = type(review.description) == "string" and review.description or ""
  local lines = { "# " .. title, "", "## Description", "" }
  if vim.trim(description) == "" then
    lines[#lines + 1] = "No description provided."
  else
    vim.list_extend(lines, vim.split(description:gsub("\r\n", "\n"), "\n", { plain = true }))
  end
  ui.document(("%s %s%d · q: close"):format(self.provider.name, self.provider.prefix, self.target.iid), lines)
end

function Session:toggle_comments()
  if not ui.valid(self) then return end
  self.inline_comments = not self.inline_comments
  ui.comments(self)
  ui.footer(self)
end

function Session:show_thread_at_cursor()
  if not self.data or not self.current or not self.current.rows
      or vim.api.nvim_get_current_buf() ~= self.viewer_buf then
    notify("Use gt on a review diff line; gT opens all discussions.", vim.log.levels.WARN)
    return
  end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local selected = {}
  for _, discussion in ipairs(self.data.discussions) do
    if threads.contains(discussion, self.current, row) then selected[#selected + 1] = discussion end
  end
  if #selected == 0 then
    notify("No discussion on this line. Use gT to see all discussions.")
    return
  end
  self:show_threads(selected, "Discussion under cursor")
end

function Session:open_comment()
  if not ui.valid(self) then return end
  local function open(note)
    local web_url = note and note.web_url
    if type(web_url) ~= "string" or not web_url:match("^https?://%S+$") or web_url:find("%c") then
      notify("No URL is available for this comment.", vim.log.levels.WARN)
      return
    end
    local ok, job, err = pcall(vim.ui.open, web_url)
    if not ok or not job then
      notify("Could not open the comment URL: " .. tostring(ok and err or job), vim.log.levels.ERROR)
    end
  end
  local buf, row = vim.api.nvim_get_current_buf(), vim.api.nvim_win_get_cursor(0)[1]
  local comments = self.thread_documents[buf]
  if comments then
    if comments[row] then open(comments[row])
    else notify("No comment under the cursor.") end
    return
  end
  if buf ~= self.viewer_buf or not self.data or not self.current or not self.current.rows then
    notify("Use :ReviewOpenComment on a commented diff line or in a discussion window.", vim.log.levels.WARN)
    return
  end
  local selected = {}
  for _, discussion in ipairs(self.data.discussions or {}) do
    if threads.contains(discussion, self.current, row) then selected[#selected + 1] = discussion end
  end
  if #selected == 0 then notify("No discussion on this line. Use gT to see all discussions."); return end
  if #selected == 1 then open(threads.root(selected[1])); return end
  local generation = self.generation
  vim.ui.select(selected, {
    prompt = "Open which discussion in the browser?",
    format_item = function(discussion)
      local root = threads.root(discussion)
      return ("@%s · %s"):format((root.author or {}).username or "unknown",
        (root.body or ""):gsub("[\r\n]", " "))
    end,
  }, function(discussion)
    if discussion and generation == self.generation and ui.valid(self) then open(threads.root(discussion)) end
  end)
end

function Session:show_threads(discussions, title)
  if not self.data or not ui.valid(self) then return end
  local lines, entries, comments = threads.document(discussions or self.data.discussions)
  local key = ui.open_comment_key(self) or ":ReviewOpenComment"
  local buf = ui.document((title or (self.provider.name .. " discussions"))
    .. " · Enter: line · " .. key .. ": browser · q: close", lines, {
    empty = "No discussions in this review.",
    entries = entries,
    on_select = function(discussion, close) self:jump_thread(discussion, close) end,
  })
  self.thread_documents[buf] = comments
  ui.bind_open_comment(self, buf)
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf, once = true,
    callback = function() self.thread_documents[buf] = nil end,
  })
end

function Session:jump_thread(discussion, close)
  if not self.ready or not ui.valid(self) or not vim.api.nvim_win_is_valid(self.viewer_win) then return end
  if self.refreshing then notify("Wait for the review refresh to finish.", vim.log.levels.WARN); return end
  local anchor = threads.anchor(discussion)
  if not anchor then
    notify("This discussion has no file line to jump to.")
    return
  end
  local function focus(row)
    if close and close() == false then return end
    vim.api.nvim_set_current_win(self.viewer_win)
    vim.api.nvim_win_set_cursor(self.viewer_win, { row, 0 })
    vim.cmd.normal({ args = { "zvzz" }, bang = true })
  end
  local row = threads.row(discussion, self.current)
  if row then focus(row); return end
  if type(anchor.sha) ~= "string" or not anchor.sha:match("^%x+$") then
    notify("The provider did not expose this comment's diff revision; its line cannot be located safely.",
      vim.log.levels.WARN)
    return
  end
  local generation, refs = self.generation, self.data.mr.diff_refs
  local function active()
    return generation == self.generation and ui.valid(self) and vim.api.nvim_win_is_valid(self.viewer_win)
  end
  self:task(function()
    local destination_sha = anchor.side == "old" and refs.base_sha or refs.head_sha
    git.ensure(self.repo, anchor.sha, self.data.project, self.config)
    if not active() then return end
    local path = git.rename_path(self.repo, anchor.sha, destination_sha, anchor.path)
    if not active() then return end
    if not path then
      notify("The commented file was deleted. The discussion remains readable here.", vim.log.levels.WARN)
      return
    end
    local line = anchor.last
    if anchor.sha ~= destination_sha then
      local original = git.content(self.repo, anchor.sha, anchor.path)
      local current = git.content(self.repo, destination_sha, path)
      if not active() then return end
      line = diff.line_map(original, current)[anchor.last]
      if not line then
        notify("The commented line was rewritten or removed. The discussion remains readable here.", vim.log.levels.WARN)
        return
      end
    end
    local file
    for _, candidate in ipairs(git.files(self.repo, refs.base_sha, refs.head_sha)) do
      if candidate[anchor.side == "old" and "old_path" or "new_path"] == path then file = candidate; break end
    end
    if not active() then return end
    if not file then
      notify("The commented file is no longer part of the review diff.", vim.log.levels.WARN)
      return
    end
    if close and close() == false then return end
    self:select_commit(0, {
      path = file.new_path, require_path = true, focus_line = { side = anchor.side, line = line },
    })
  end, nil, generation)
end

function Session:submit()
  if not self.ready or self.submitting or self.approving or self.refreshing then return end
  if #self.drafts == 0 then notify("No local drafts to submit."); return end
  for _, draft in ipairs(self.drafts) do
    if draft.status == "uncertain" or draft.status == "sending" then
      notify("An earlier publish attempt has an unknown outcome. Check " .. self.provider.name
        .. ", then edit the draft's retry state with :ReviewDrafts.",
        vim.log.levels.WARN)
      return
    end
  end
  -- Always let the user inspect the exact comments before authorizing POST.
  local preview = {}
  for i, draft in ipairs(self.drafts) do
    local p = draft.position
    local line = p.new_line or p.old_line
    local first = p.line_range and p.line_range.start
    local start = first and (first.new_line or first.old_line)
    local range = start and start ~= line and (start .. "–" .. line) or tostring(line)
    preview[#preview + 1] = ("## %d · %s%s:%s"):format(i,
      draft.reply and ("Reply to @" .. (draft.reply.author or "unknown") .. " · ") or "", p.new_path, range)
    if draft.reply then
      preview[#preview + 1] = "Discussion: " .. tostring(draft.reply.discussion_id)
      preview[#preview + 1] = "Original comment (context only):"
      for _, text in ipairs(vim.split(draft.reply.body or "", "\n", { plain = true })) do
        preview[#preview + 1] = "> " .. text
      end
      preview[#preview + 1] = ""
      preview[#preview + 1] = "Reply:"
    end
    vim.list_extend(preview, vim.split(draft.body, "\n", { plain = true }))
    preview[#preview + 1] = ""
  end
  ui.document("Review drafts · q closes preview", preview)
  vim.ui.select({ "Keep local", "Publish " .. #self.drafts .. " comment(s) to " .. self.provider.name },
    { prompt = "Publish these review comments?" }, function(choice)
      if not choice or choice == "Keep local" or self.closed or self.submitting
          or self.approving or self.refreshing then return end
      self.submitting = true
      self:task(function()
        local latest = self.provider.current(self.target)
        for _, draft in ipairs(self.drafts) do
          if draft.status ~= "published" and not position.same_refs(draft.position, latest.diff_refs) then
            self.submitting = false
            error("The review diff changed since a draft was created. Drafts remain local; choose updated positions.", 0)
          end
        end
        local count = 0
        while #self.drafts > 0 do
          local draft = self.drafts[1]
          if draft.status ~= "published" then
            local current_mr = self.provider.current(self.target)
            if not position.same_refs(draft.position, current_mr.diff_refs) then
              error("The review changed during submission. Remaining drafts stay local.", 0)
            end
            local publish = self.provider.post
            if draft.reply then
              if not self.provider.reply or not self.provider.validate_reply then
                error("Reply drafts are not supported by the " .. self.provider.name .. " provider.", 0)
              end
              self.provider.validate_reply(self.target, draft)
              publish = self.provider.reply
            elseif self.provider.validate_submission then
              self.provider.validate_submission(self.target, draft)
            end
            draft.status = "sending"
            drafts.save(self.config, self.target, self.drafts)
            local ok, response = pcall(publish, self.target, draft)
            if not ok then
              draft.status = "uncertain"
              pcall(drafts.save, self.config, self.target, self.drafts)
              error("Publication outcome could not be confirmed. Check " .. self.provider.name
                .. " before retrying. " .. tostring(response), 0)
            end
            draft.status, draft.published_id = "published", response.id
            drafts.save(self.config, self.target, self.drafts)
            count = count + 1
          end
          table.remove(self.drafts, 1)
          drafts.save(self.config, self.target, self.drafts)
        end
        self.submitting = false
        self.data.discussions = self.provider.discussions(self.target, self.data.mr.diff_refs, self.data.diffs)
        if self.current and self.current.rows then self:map_threads(self.current, self.generation) end
        ui.panel(self)
        ui.comments(self)
        notify(("Published %d comment(s)."):format(count))
      end, function() self.submitting = false end)
    end)
end

function Session:approve()
  if not self.ready or self.closed then
    notify("Wait for the review to finish loading before approving it.", vim.log.levels.WARN)
    return
  end
  if not self.provider.approve then
    notify("Approval is only supported for GitLab merge requests.", vim.log.levels.WARN)
    return
  end
  if self.approving or self.submitting or self.refreshing then
    notify("Wait for the current review operation to finish.", vim.log.levels.WARN)
    return
  end
  self.approving = true
  self:task(function()
    self.provider.approve(self.target)
    self.approving = false
    notify(("Approved GitLab MR !%d."):format(self.target.iid))
  end, function()
    self.approving = false
  end)
end

function Session:close()
  if self.closed then return end
  if self.submitting or self.approving then
    notify("Wait for the current review operation to finish.", vim.log.levels.WARN)
    return
  end
  self.closed = true
  ui.close(self)
  if self.tab and vim.api.nvim_tabpage_is_valid(self.tab) then
    local tabs = vim.api.nvim_list_tabpages()
    for i, tab in ipairs(tabs) do
      if tab == self.tab then vim.cmd(i .. "tabclose"); break end
    end
  end
end

return Session
