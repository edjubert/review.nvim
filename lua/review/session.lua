local async = require("review.async")
local providers = require("review.providers")
local git = require("review.git")
local diff = require("review.diff")
local position = require("review.position")
local drafts = require("review.drafts")
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
    notify("Open a merge request with :Review first.", vim.log.levels.WARN)
    return
  end
  if self.submitting then
    notify("Wait for comment submission to finish.", vim.log.levels.WARN)
    return
  end
  if self.refreshing then
    notify("The merge request is already refreshing.")
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
    ui.empty(self, initial and "Loading merge request…" or "Refreshing merge request…")
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
      error("The merge request changed while loading. Run :ReviewRefresh to try again.", 0)
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
    if not initial then notify("Merge request refreshed.") end
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
      for i, file in ipairs(files) do
        if file.new_path == selection.path then file_index = i; break end
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
    self.current = { file = file, base = base, head = head, old = old, new = new, rows = rows, error = err }
    ui.render(self, self.current)
    if not ui.valid(self) then return end
    if rows and vim.api.nvim_win_is_valid(self.viewer_win) then
      local cursor = { diff.hunk_starts(rows)[1] or 1, 0 }
      if selection and selection.cursor and #rows > 0
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

-- A commit snapshot is mapped to the current MR diff, with unchanged lines
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
  if not destination_path then error("This file no longer exists in the current MR diff.", 0) end
  local mr_file
  for _, file in ipairs(self.data.diffs) do
    if file[side == "old" and "old_path" or "new_path"] == destination_path then mr_file = file; break end
  end
  if not mr_file or not mr_file.diff or mr_file.diff == "" then
    error("GitLab has no commentable diff for this file. Open the complete MR or use the web interface.", 0)
  end
  local source_content = side == "old" and current.old or current.new
  local destination_content = git.content(self.repo, destination_sha, destination_path)
  local map = diff.line_map(source_content, destination_content)
  local parsed = diff.patch(mr_file.diff)
  local key, mapped = side .. "_line", {}
  for _, row in ipairs(selected) do
    local mapped_line = row[key] and map[row[key]]
    if not mapped_line then
      error("A later commit changed this line. Select its current position in the complete MR view (gA).", 0)
    end
    local target_row = parsed["by_" .. side][mapped_line]
    if not target_row then error("This line is outside GitLab's commentable diff context.", 0) end
    mapped[#mapped + 1] = target_row
  end
  local result, err = position.build(refs, mr_file, mapped)
  if not result then error(err, 0) end
  return result
end

function Session:save_draft(body, target_position, commit, display)
  local updated = vim.deepcopy(self.drafts)
  updated[#updated + 1] = drafts.new(body, target_position, commit, display)
  drafts.save(self.config, self.target, updated)
  self.drafts = updated
  ui.panel(self)
  ui.comments(self)
end

function Session:comment(first, last)
  if self.refreshing then notify("Wait for the merge request refresh to finish.", vim.log.levels.WARN); return end
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

function Session:show_drafts()
  if #self.drafts == 0 then notify("No local drafts."); return end
  vim.ui.select(self.drafts, {
    prompt = "Local review drafts",
    format_item = function(draft)
      local p = draft.position
      return (p.new_path or p.old_path) .. ":" .. (p.new_line or p.old_line)
        .. (draft.status and (" [" .. draft.status .. "]") or "") .. " · " .. draft.body:gsub("\n", " ")
    end,
  }, function(draft)
    if not draft then return end
    local actions = { "Edit locally", "Delete locally" }
    if draft.status == "uncertain" or draft.status == "sending" then
      actions[#actions + 1] = "Allow retry after checking GitLab"
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
      elseif action == "Allow retry after checking GitLab" then
        draft.status = nil
        drafts.save(self.config, self.target, self.drafts)
      end
    end)
  end)
end

function Session:show_threads()
  if not self.data then return end
  local file = self.current and self.current.file
  local lines = {}
  for _, discussion in ipairs(self.data.discussions) do
    local first = discussion.notes and discussion.notes[1]
    local p = first and type(first.position) == "table" and first.position or nil
    if first and (not file or (p and (p.new_path == file.new_path or p.old_path == file.old_path))) then
      lines[#lines + 1] = "## " .. (first.resolved and "Resolved" or "Discussion")
      if p then lines[#lines + 1] = (p.new_path or p.old_path) .. ":" .. (p.new_line or p.old_line or "?") end
      for _, note in ipairs(discussion.notes) do
        if not note.system then
          lines[#lines + 1] = ""
          lines[#lines + 1] = "### " .. ((note.author or {}).username or "unknown")
          vim.list_extend(lines, vim.split(note.body or "", "\n", { plain = true }))
        end
      end
      lines[#lines + 1] = ""
    end
  end
  ui.document(self.provider.name .. " discussions", lines)
end

function Session:submit()
  if not self.ready or self.submitting or self.refreshing then return end
  if #self.drafts == 0 then notify("No local drafts to submit."); return end
  for _, draft in ipairs(self.drafts) do
    if draft.status == "uncertain" or draft.status == "sending" then
      notify("An earlier publish attempt has an unknown outcome. Check GitLab, then edit the draft's retry state with :ReviewDrafts.",
        vim.log.levels.WARN)
      return
    end
  end
  -- Always let the user inspect the exact comments before authorizing POST.
  local preview = {}
  for i, draft in ipairs(self.drafts) do
    local p = draft.position
    preview[#preview + 1] = ("## %d · %s:%s"):format(i, p.new_path, p.new_line or p.old_line)
    vim.list_extend(preview, vim.split(draft.body, "\n", { plain = true }))
    preview[#preview + 1] = ""
  end
  ui.document("Review drafts · q closes preview", preview)
  vim.ui.select({ "Keep local", "Publish " .. #self.drafts .. " comment(s) to GitLab" },
    { prompt = "Publish these review comments?" }, function(choice)
      if not choice or choice == "Keep local" or self.closed or self.submitting or self.refreshing then return end
      self.submitting = true
      self:task(function()
        local latest = self.provider.current(self.target)
        for _, draft in ipairs(self.drafts) do
          if draft.status ~= "published" and not position.same_refs(draft.position, latest.diff_refs) then
            self.submitting = false
            error("The MR diff changed since a draft was created. Drafts remain local; choose updated positions.", 0)
          end
        end
        local count = 0
        while #self.drafts > 0 do
          local draft = self.drafts[1]
          if draft.status ~= "published" then
            local current_mr = self.provider.current(self.target)
            if not position.same_refs(draft.position, current_mr.diff_refs) then
              error("The MR changed during submission. Remaining drafts stay local.", 0)
            end
            draft.status = "sending"
            drafts.save(self.config, self.target, self.drafts)
            local ok, response = pcall(self.provider.post, self.target, draft)
            if not ok then
              draft.status = "uncertain"
              pcall(drafts.save, self.config, self.target, self.drafts)
              error("Publication outcome could not be confirmed. Check GitLab before retrying. " .. tostring(response), 0)
            end
            draft.status, draft.published_id = "published", response.id
            drafts.save(self.config, self.target, self.drafts)
            count = count + 1
          end
          table.remove(self.drafts, 1)
          drafts.save(self.config, self.target, self.drafts)
        end
        self.submitting = false
        self.data.discussions = self.provider.pages(self.target, self.provider.mr_path(self.target) .. "/discussions")
        ui.panel(self)
        ui.comments(self)
        notify(("Published %d comment(s)."):format(count))
      end, function() self.submitting = false end)
    end)
end

function Session:close()
  if self.closed then return end
  if self.submitting then notify("Wait for comment submission to finish.", vim.log.levels.WARN); return end
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
