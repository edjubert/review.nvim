local M = {}

function M.root(discussion)
  for _, note in ipairs(discussion.notes or {}) do
    if not note.system then return note end
  end
end

local function line(value)
  return type(value) == "number" and value > 0 and value % 1 == 0 and value or nil
end

function M.anchor(discussion, current)
  if current and current.thread_anchors and current.thread_anchors[discussion] then
    return current.thread_anchors[discussion]
  end
  local note = M.root(discussion)
  local p = note and note.position
  if type(p) ~= "table" then return nil end
  local side = line(p.new_line) and "new" or "old"
  local key = side .. "_line"
  local last = line(p[key])
  if not last then return nil end
  local range = type(p.line_range) == "table" and p.line_range or nil
  local start = range and type(range.start) == "table" and line(range.start[key]) or nil
  local path = side == "old" and (p.old_path or p.new_path) or (p.new_path or p.old_path)
  if type(path) ~= "string" or path == "" then return nil end
  local sha
  if side == "old" then sha = p.base_sha else sha = p.head_sha end
  return {
    path = path, side = side, key = key, first = start or last, last = last,
    sha = sha,
  }
end

local function matches(anchor, current)
  local path = anchor.side == "old" and current.file.old_path or current.file.new_path
  local sha
  if anchor.side == "old" then sha = current.base else sha = current.head end
  return type(anchor.sha) == "string" and anchor.sha == sha and anchor.path == path
end

function M.row(discussion, current)
  local anchor = M.anchor(discussion, current)
  if not anchor or not current or not current.rows or not matches(anchor, current) then return nil end
  for index, row in ipairs(current.rows) do
    if row[anchor.key] == anchor.last then return index end
  end
end

function M.contains(discussion, current, index)
  local anchor = M.anchor(discussion, current)
  if not anchor or not current or not current.rows or not matches(anchor, current) then return false end
  local row = current.rows[index]
  local number = row and row[anchor.key]
  return number and number >= anchor.first and number <= anchor.last or false
end

function M.document(discussions)
  local lines, entries, count = {}, {}, 0
  for _, discussion in ipairs(discussions) do
    local root = M.root(discussion)
    if root then
      local start, anchor = #lines + 1, M.anchor(discussion)
      count = count + 1
      local status = root.resolved and "Resolved discussion"
        or root.outdated and "Outdated discussion" or "Discussion"
      lines[#lines + 1] = ("## %d · %s"):format(count, status)
      if anchor then
        local range = anchor.first ~= anchor.last and (anchor.first .. "–" .. anchor.last) or anchor.last
        lines[#lines + 1] = ("%s:%s (%s)"):format(anchor.path, range, anchor.side == "old" and "old" or "new")
      else
        lines[#lines + 1] = "No file line attached"
      end
      for _, note in ipairs(discussion.notes) do
        if not note.system then
          lines[#lines + 1] = ""
          lines[#lines + 1] = "### " .. ((note.author or {}).username or "unknown")
          vim.list_extend(lines, vim.split(note.body or "", "\n", { plain = true }))
        end
      end
      lines[#lines + 1] = ""
      -- Enter works anywhere in a discussion, including its replies.
      for index = start, #lines do entries[index] = discussion end
    end
  end
  return lines, entries
end

return M
