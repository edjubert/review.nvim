local M = {}

function M.hunk_starts(rows)
  local starts, changed = {}, false
  for line, row in ipairs(rows) do
    local is_change = row.kind == "add" or row.kind == "delete"
    if is_change and not changed then starts[#starts + 1] = line end
    changed = is_change
  end
  return starts
end

function M.jump(rows, line, direction, count)
  local starts = M.hunk_starts(rows)
  for _ = 1, count or 1 do
    local destination
    if direction > 0 then
      for _, start in ipairs(starts) do
        if start > line then destination = start; break end
      end
    else
      for i = #starts, 1, -1 do
        if starts[i] < line then destination = starts[i]; break end
      end
    end
    if not destination then return nil end
    line = destination
  end
  return line
end

function M.spans(old, new)
  local function chars(text)
    local parts = vim.fn.split(text, "\\zs")
    local offsets = { 0 }
    for _, char in ipairs(parts) do offsets[#offsets + 1] = offsets[#offsets] + #char end
    return parts, offsets
  end
  local a, ao = chars(old)
  local b, bo = chars(new)
  local before, after = {}, {}
  local hunks = vim.diff(table.concat(a, "\n") .. (#a > 0 and "\n" or ""),
    table.concat(b, "\n") .. (#b > 0 and "\n" or ""), { result_type = "indices" })
  for _, h in ipairs(hunks) do
    if h[2] > 0 then before[#before + 1] = { ao[h[1]], ao[h[1] + h[2]] } end
    if h[4] > 0 then after[#after + 1] = { bo[h[3]], bo[h[3] + h[4]] } end
  end
  return before, after
end

function M.lines(text)
  if text == "" then return {} end
  local lines = vim.split(text, "\n", { plain = true })
  if lines[#lines] == "" then table.remove(lines) end
  for i, line in ipairs(lines) do lines[i] = line:gsub("\r$", "") end
  return lines
end

-- Deleted lines are real, selectable buffer lines, not virtual lines.
function M.build(old, new)
  if old:find("\0", 1, true) or new:find("\0", 1, true) then return nil, "Binary file" end
  local before, after = M.lines(old), M.lines(new)
  local hunks = vim.diff(old, new, { result_type = "indices", algorithm = "histogram" })
  local rows, oi, ni = {}, 1, 1
  local function context(until_old, until_new)
    while oi < until_old and ni < until_new do
      rows[#rows + 1] = { text = after[ni], kind = "context", old_line = oi, new_line = ni }
      oi, ni = oi + 1, ni + 1
    end
  end
  for _, h in ipairs(hunks) do
    local a, ac, b, bc = unpack(h)
    local old_start = ac == 0 and a + 1 or a
    local new_start = bc == 0 and b + 1 or b
    context(old_start, new_start)
    local row_start = #rows + 1
    for line = old_start, old_start + ac - 1 do
      rows[#rows + 1] = { text = before[line], kind = "delete", old_line = line }
    end
    for line = new_start, new_start + bc - 1 do
      rows[#rows + 1] = { text = after[line], kind = "add", new_line = line }
    end
    for i = 0, math.min(ac, bc) - 1 do
      local old_row, new_row = rows[row_start + i], rows[row_start + ac + i]
      old_row.spans, new_row.spans = M.spans(old_row.text, new_row.text)
    end
    oi, ni = old_start + ac, new_start + bc
  end
  context(#before + 1, #after + 1)
  return rows
end

function M.line_map(from, to)
  local map = {}
  local rows = M.build(from, to)
  if not rows then return map end
  for _, row in ipairs(rows) do
    if row.kind == "context" then map[row.old_line] = row.new_line end
  end
  return map
end

function M.patch(patch)
  local parsed = { by_old = {}, by_new = {}, rows = {} }
  local old_line, new_line
  for line in (patch .. "\n"):gmatch("(.-)\n") do
    local a, b = line:match("^@@ %-(%d+)[,%d]* %+(%d+)[,%d]* @@")
    if a then
      old_line, new_line = tonumber(a), tonumber(b)
    elseif old_line then
      local prefix = line:sub(1, 1)
      -- GitLab's line_code uses both running positions, including the
      -- opposite counter on an addition/deletion. old_line/new_line omit
      -- that counter, but old_pos/new_pos must retain it for range hashes.
      local row = { text = line:sub(2), old_pos = old_line, new_pos = new_line }
      if prefix == " " then
        row.kind, row.old_line, row.new_line = "context", old_line, new_line
        old_line, new_line = old_line + 1, new_line + 1
      elseif prefix == "-" then
        row.kind, row.old_line = "delete", old_line
        old_line = old_line + 1
      elseif prefix == "+" then
        row.kind, row.new_line = "add", new_line
        new_line = new_line + 1
      end
      if row.kind then
        parsed.rows[#parsed.rows + 1] = row
        if row.old_line then parsed.by_old[row.old_line] = row end
        if row.new_line then parsed.by_new[row.new_line] = row end
      end
    end
  end
  return parsed
end

return M
