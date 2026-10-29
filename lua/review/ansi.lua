local M = {}

local palette = {
  "#000000", "#cd0000", "#00cd00", "#cdcd00", "#0000ee", "#cd00cd", "#00cdcd", "#e5e5e5",
  "#7f7f7f", "#ff0000", "#00ff00", "#ffff00", "#5c5cff", "#ff00ff", "#00ffff", "#ffffff",
}

local function byte(value)
  return type(value) == "number" and value >= 0 and value <= 255 and value == math.floor(value)
end

local function indexed(value)
  if not byte(value) then return end
  if value < 16 then
    local color = vim.g["terminal_color_" .. value]
    return type(color) == "string" and color:match("^#%x%x%x%x%x%x$") and color or palette[value + 1]
  end
  if value >= 232 then
    local gray = 8 + (value - 232) * 10
    return ("#%02x%02x%02x"):format(gray, gray, gray)
  end
  local cube = { 0, 95, 135, 175, 215, 255 }
  value = value - 16
  return ("#%02x%02x%02x"):format(
    cube[math.floor(value / 36) + 1], cube[math.floor(value / 6) % 6 + 1], cube[value % 6 + 1])
end

local function color(state, field, mode, values, offset)
  local cterm = field == "fg" and "ctermfg" or "ctermbg"
  if mode == 5 then
    local index = tonumber(values[offset])
    if byte(index) then state[field], state[cterm] = indexed(index), index end
  elseif mode == 2 then
    local r, g, b = tonumber(values[offset]), tonumber(values[offset + 1]), tonumber(values[offset + 2])
    if byte(r) and byte(g) and byte(b) then
      state[field], state[cterm] = ("#%02x%02x%02x"):format(r, g, b), nil
    end
  end
end

local function sgr(parameters, state)
  local values = vim.split(parameters, ";", { plain = true })
  local index = 1
  while index <= #values do
    local part = values[index]
    local colon = part:find(":", 1, true) and vim.split(part, ":", { plain = true })
    local code = tonumber(colon and colon[1] or part) or (part == "" and 0 or nil)
    if code == 0 then
      state = {}
    elseif code == 1 then state.bold = true
    elseif code == 3 then state.italic = true
    elseif code == 4 then state.underline = true
    elseif code == 7 then state.reverse = true
    elseif code == 9 then state.strikethrough = true
    elseif code == 22 then state.bold = nil
    elseif code == 23 then state.italic = nil
    elseif code == 24 then state.underline = nil
    elseif code == 27 then state.reverse = nil
    elseif code == 29 then state.strikethrough = nil
    elseif code == 39 then state.fg, state.ctermfg = nil, nil
    elseif code == 49 then state.bg, state.ctermbg = nil, nil
    elseif code and ((code >= 30 and code <= 37) or (code >= 90 and code <= 97)) then
      local value = code >= 90 and code - 90 + 8 or code - 30
      state.fg, state.ctermfg = indexed(value), value
    elseif code and ((code >= 40 and code <= 47) or (code >= 100 and code <= 107)) then
      local value = code >= 100 and code - 100 + 8 or code - 40
      state.bg, state.ctermbg = indexed(value), value
    elseif code == 38 or code == 48 then
      local field = code == 38 and "fg" or "bg"
      if colon then
        local mode = tonumber(colon[2])
        color(state, field, mode, colon, mode == 2 and #colon >= 6 and 4 or 3)
      else
        local mode = tonumber(values[index + 1])
        color(state, field, mode, values, index + 2)
        if mode == 5 then index = index + 2 elseif mode == 2 then index = index + 4 end
      end
    end
    index = index + 1
  end
  return state
end

-- Render SGR styling as byte-column highlights in an ordinary preview buffer.
-- No terminal is started, so cursor/erase/OSC sequences cannot alter the UI.
function M.render(trace)
  trace = trace:gsub("\27%].-\7", ""):gsub("\27%].-\27\\", ""):gsub("\27[P^_].-\27\\", "")
  local lines, highlights, definitions = {}, {}, {}
  local state, group, parts, column = {}, nil, {}, 0
  local function append(value)
    value = value:gsub("\27[@-_]", ""):gsub("[%z\1-\8\11\12\14-\31\127]", "")
    local chunks = vim.split(value, "\n", { plain = true })
    for index, chunk in ipairs(chunks) do
      if #chunk > 0 then
        parts[#parts + 1] = chunk
        if group then
          highlights[#highlights + 1] = {
            line = #lines + 1, start_col = column, end_col = column + #chunk, group = group,
          }
        end
        column = column + #chunk
      end
      if index < #chunks then
        lines[#lines + 1], parts, column = table.concat(parts), {}, 0
      end
    end
  end
  local cursor = 1
  while cursor <= #trace do
    local first, last = trace:find("\27%[[0-?]*[ -/]*[@-~]", cursor)
    if not first then append(trace:sub(cursor)); break end
    append(trace:sub(cursor, first - 1))
    if trace:sub(last, last) == "m" then
      state = sgr(trace:sub(first + 2, last - 1), state)
      local key = {}
      for _, name in ipairs({ "fg", "bg", "ctermfg", "ctermbg", "bold", "italic", "underline",
          "reverse", "strikethrough" }) do
        if state[name] ~= nil then key[#key + 1] = name .. "_" .. tostring(state[name]):gsub("#", "") end
      end
      group = #key > 0 and ("ReviewJobAnsi_" .. table.concat(key, "_")) or nil
      if group and not definitions[group] then definitions[group] = vim.tbl_extend("force", {}, state) end
    end
    cursor = last + 1
  end
  lines[#lines + 1] = table.concat(parts)
  return lines, highlights, definitions
end

return M
