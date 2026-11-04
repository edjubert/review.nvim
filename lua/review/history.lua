local M = {}
local limit, read_limit = 100, 1024 * 1024

local function path(config)
  return config.state_dir .. "/history.jsonl"
end

local function clean_title(title)
  return type(title) == "string" and vim.fn.strcharpart(vim.trim(title:gsub("[%c]", " ")), 0, 300) or ""
end

function M.list(config)
  local fd, err, code = vim.uv.fs_open(path(config), "r", 384)
  if not fd then
    if code == "ENOENT" then return {} end
    error("Could not read review history: " .. tostring(err), 0)
  end
  local stat = vim.uv.fs_fstat(fd)
  local offset = stat and math.max(0, stat.size - read_limit) or 0
  local data, read_error = vim.uv.fs_read(fd, read_limit, offset)
  vim.uv.fs_close(fd)
  if not data then error("Could not read review history: " .. tostring(read_error), 0) end
  if offset > 0 then data = data:match("\n(.*)") or "" end
  local entries = {}
  -- Append-only records allow several Neovim instances to share this history.
  -- Ignore incomplete/corrupt records without rewriting the original file.
  for line in data:gmatch("[^\n]+") do
    local ok, entry = pcall(vim.json.decode, line)
    if ok and type(entry) == "table" and entry.version == 1 and type(entry.url) == "string"
        and type(entry.opened_at) == "number" then
      local target = require("review.url").parse(entry.url)
      if target then
        entries[#entries + 1] = {
          url = target.url, title = clean_title(entry.title), opened_at = entry.opened_at,
        }
      end
    end
  end
  local recent, seen = {}, {}
  for i = #entries, 1, -1 do
    local entry = entries[i]
    if not seen[entry.url] then
      seen[entry.url] = true
      recent[#recent + 1] = entry
      if #recent == limit then break end
    end
  end
  return recent
end

function M.record(config, target, mr)
  local canonical = assert(require("review.url").parse(target.url))
  local data = "\n" .. vim.json.encode({
    version = 1, url = canonical.url, title = clean_title(mr and mr.title), opened_at = os.time(),
  }) .. "\n"
  vim.fn.mkdir(config.state_dir, "p", 448)
  local fd, err = vim.uv.fs_open(path(config), "a", 384)
  if not fd then error("Could not save review history: " .. tostring(err), 0) end
  -- One O_APPEND write prevents concurrent instances from losing each other's
  -- entries. A leading newline isolates an interrupted previous record.
  local written, write_error = vim.uv.fs_write(fd, data, -1)
  vim.uv.fs_close(fd)
  if written ~= #data then error("Could not save review history: " .. tostring(write_error), 0) end
end

return M
