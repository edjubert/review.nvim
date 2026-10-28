local M = {}

-- API positions and older JSON files may contain vim.NIL for optional fields.
-- Treat those fields as absent before the UI or a write transport reads them.
local function remove_null_fields(value)
  for key, item in pairs(value) do
    if item == vim.NIL then
      value[key] = nil
    elseif type(item) == "table" then
      remove_null_fields(item)
    end
  end
  return value
end

local function path(config, target)
  return config.state_dir .. "/drafts/" .. vim.fn.sha256(target.url) .. ".json"
end

function M.load(config, target)
  local file = path(config, target)
  if not vim.uv.fs_stat(file) then return {} end
  local ok, drafts = pcall(vim.json.decode, table.concat(vim.fn.readfile(file), "\n"))
  if not ok or not vim.islist(drafts) then
    error("Could not read local drafts: " .. file .. ". The file has been preserved.", 0)
  end
  for _, draft in ipairs(drafts) do
    if type(draft) ~= "table" then
      error("Could not read local drafts: " .. file .. ". The file has been preserved.", 0)
    end
    remove_null_fields(draft)
  end
  return drafts
end

function M.save(config, target, drafts)
  local file = path(config, target)
  vim.fn.mkdir(vim.fn.fnamemodify(file, ":h"), "p")
  local temporary = file .. "." .. vim.uv.hrtime() .. ".tmp"
  local fd, open_error = vim.uv.fs_open(temporary, "w", 384)
  if not fd then error(open_error, 0) end
  local written, write_error = vim.uv.fs_write(fd, vim.json.encode(drafts), 0)
  vim.uv.fs_close(fd)
  if not written then vim.uv.fs_unlink(temporary); error(write_error, 0) end
  local renamed, rename_error = vim.uv.fs_rename(temporary, file)
  if not renamed then vim.uv.fs_unlink(temporary); error(rename_error, 0) end
end

function M.new(body, position, commit, display, reply)
  return remove_null_fields(vim.deepcopy({
    id = tostring(vim.uv.hrtime()),
    body = body,
    position = position,
    commit = commit,
    display = display,
    reply = reply,
    created_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
  }))
end

return M
