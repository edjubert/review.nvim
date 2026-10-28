local M = {}

-- Git quotes paths containing tabs, newlines or non-ASCII bytes using C escapes.
local function path(value, prefix)
  if value:sub(1, 1) == '"' then
    local chars, i, closed = {}, 2, false
    local escapes = { a = "\a", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", v = "\v" }
    while i <= #value do
      local char = value:sub(i, i)
      if char == '"' then closed = true; break end
      if char == "\\" then
        i = i + 1
        char = value:sub(i, i)
        local octal = value:sub(i):match("^([0-7][0-7]?[0-7]?)")
        if octal then
          local byte = tonumber(octal, 8)
          if byte > 255 then error("Invalid quoted path in Codeberg's diff.", 0) end
          chars[#chars + 1], i = string.char(byte), i + #octal
        elseif char == "\\" or char == '"' or escapes[char] then
          chars[#chars + 1], i = escapes[char] or char, i + 1
        else
          error("Invalid quoted path in Codeberg's diff.", 0)
        end
      else
        chars[#chars + 1], i = char, i + 1
      end
    end
    if not closed then error("Unclosed quoted path in Codeberg's diff.", 0) end
    value = table.concat(chars)
  else
    -- Git may append a tab after an unquoted path containing spaces.
    value = value:match("^[^\t]*")
  end
  if value == "/dev/null" then return nil end
  if value:sub(1, #prefix) ~= prefix then error("Unexpected path prefix in Codeberg's diff.", 0) end
  return value:sub(#prefix + 1)
end

function M.apply(patch, files)
  local by_path, seen = {}, {}
  for _, file in ipairs(files) do by_path[file.new_path] = file end
  local chunk, chunks = nil, 0
  local function finish()
    if not chunk then return end
    local old, new, hunk
    for i, line in ipairs(chunk) do
      if line:match("^@@ ") then hunk = i; break end
      if line:sub(1, 4) == "--- " then old = path(line:sub(5), "a/") end
      if line:sub(1, 4) == "+++ " then new = path(line:sub(5), "b/") end
    end
    -- Renames without content changes, mode changes and binary files have no
    -- commentable hunk. Their names/statuses still come from the files API.
    if not hunk then return end
    local file = by_path[new or old]
    if not file or seen[file.new_path] or (old and old ~= file.old_path)
        or (new and new ~= file.new_path) then
      error("Codeberg's file list and diff disagree. Run :ReviewRefresh.", 0)
    end
    seen[file.new_path] = true
    file.diff = table.concat(chunk, "\n", hunk) .. "\n"
  end
  for line in (patch .. "\n"):gmatch("(.-)\n") do
    if line:match("^diff %-%-git ") then
      finish()
      chunk, chunks = {}, chunks + 1
    elseif chunk then
      chunk[#chunk + 1] = line
    end
  end
  finish()
  if chunks ~= #files then
    error("Codeberg did not return a complete file diff. Run :ReviewRefresh.", 0)
  end
  return files
end

return M
