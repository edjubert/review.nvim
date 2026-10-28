local sha1 = require("review.sha1")
local M = {}

function M.side(rows)
  local add, delete = false, false
  for _, row in ipairs(rows) do
    add = add or row.kind == "add"
    delete = delete or row.kind == "delete"
  end
  if add and delete then return nil, "Select either old or new lines, not both sides of a replacement." end
  return delete and "old" or "new"
end

function M.build(refs, file, rows)
  if #rows == 0 then return nil, "No lines selected." end
  local side, err = M.side(rows)
  if not side then return nil, err end
  local key = side .. "_line"
  for i, row in ipairs(rows) do
    if not row[key] or (i > 1 and row[key] ~= rows[i - 1][key] + 1) then
      return nil, "The selection is not a contiguous range on one side of the MR diff."
    end
  end
  local last = rows[#rows]
  local position = {
    position_type = "text",
    base_sha = refs.base_sha,
    head_sha = refs.head_sha,
    start_sha = refs.start_sha,
    old_path = file.old_path,
    new_path = file.new_path,
    old_line = last.old_line,
    new_line = last.new_line,
  }
  if #rows > 1 then
    local function endpoint(row)
      return {
        line_code = ("%s_%d_%d"):format(sha1(file.new_path),
          row.old_pos or row.old_line or 0, row.new_pos or row.new_line or 0),
        type = row.kind == "add" and "new" or "old",
        old_line = row.old_line,
        new_line = row.new_line,
      }
    end
    position.line_range = { start = endpoint(rows[1]), ["end"] = endpoint(last) }
  end
  return position
end

function M.same_refs(a, b)
  return a and b and a.base_sha == b.base_sha and a.start_sha == b.start_sha and a.head_sha == b.head_sha
end

return M
