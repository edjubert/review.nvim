local M = {}

local function render_text(text)
  local aliases = require("review.emoji_data")
  local parts, index = {}, 1
  while index <= #text do
    local start = text:find("[\\`:]", index)
    if not start then
      parts[#parts + 1] = text:sub(index)
      break
    end
    parts[#parts + 1] = text:sub(index, start - 1)
    local char, finish, replacement = text:sub(start, start), start, nil
    if char == "\\" then
      -- A Markdown escape protects the following delimiter.
      finish = math.min(#text, start + 1)
    elseif char == "`" then
      local _, last = text:find("^`+", start)
      finish = last
      local search = last + 1
      while search <= #text do
        local first, closing = text:find("`+", search)
        if not first then break end
        if closing - first == last - start then
          finish = closing
          break
        end
        search = closing + 1
      end
      -- Only matching backtick runs form a code span; unmatched runs are text.
    else
      local _, last, name = text:find("^:([%w_+%-]+):", start)
      if name then
        finish, replacement = last, aliases[name]
      end
    end
    parts[#parts + 1] = replacement or text:sub(start, finish)
    index = finish + 1
  end
  return table.concat(parts)
end

local function fence_marker(line)
  local indent, marker, tail = line:match("^( *)([`~]+)(.*)$")
  if not marker or #indent > 3 or #marker < 3
      or not (marker:match("^`+$") or marker:match("^~+$")) then return end
  return marker, tail
end

-- Convert display text only, preserving Markdown code and the original body.
function M.render(text)
  if not text:find(":", 1, true) then return text end
  local parts, pending, fence = {}, {}, nil
  local function flush()
    if #pending == 0 then return end
    parts[#parts + 1] = render_text(table.concat(pending, "\n"))
    pending = {}
  end
  for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
    local marker, tail = fence_marker(line)
    if fence then
      parts[#parts + 1] = line
      if marker and marker:sub(1, 1) == fence:sub(1, 1)
          and #marker >= #fence and tail:match("^%s*$") then fence = nil end
    elseif marker and (marker:sub(1, 1) == "~" or not tail:find("`", 1, true)) then
      flush()
      parts[#parts + 1] = line
      fence = marker
    else
      pending[#pending + 1] = line
    end
  end
  flush()
  return table.concat(parts, "\n")
end

return M
