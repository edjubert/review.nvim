local M = {}

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

function M.new(body, position, commit, display)
  return {
    id = tostring(vim.uv.hrtime()),
    body = body,
    position = position,
    commit = commit,
    display = display,
    created_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
  }
end

return M
