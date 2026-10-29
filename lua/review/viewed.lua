local M = {}

local function path(config, target)
  return config.state_dir .. "/viewed/" .. vim.fn.sha256(target.url) .. ".json"
end

local function record(base, head, file)
  if type(base) ~= "string" or base == "" or type(head) ~= "string" or head == ""
      or type(file) ~= "table" or type(file.old_path) ~= "string" or type(file.new_path) ~= "string" then
    return nil
  end
  return {
    base = base, head = head, old_path = file.old_path, new_path = file.new_path,
    status = type(file.status) == "string" and file.status
      or (file.new_file and "A" or file.deleted_file and "D" or "M"),
  }
end

local function key(value)
  return vim.fn.sha256(vim.json.encode({
    value.base, value.head, value.old_path, value.new_path, value.status,
  }))
end

function M.load(config, target)
  local file = path(config, target)
  local stat, stat_error, code = vim.uv.fs_stat(file)
  if not stat then
    if code == "ENOENT" then return { version = 1, files = vim.empty_dict() } end
    error("Could not read local viewed state: " .. file .. ". " .. tostring(stat_error), 0)
  end
  local ok, state = pcall(function()
    return vim.json.decode(table.concat(vim.fn.readfile(file), "\n"))
  end)
  if ok and type(state) == "table" and state.version == 1 and type(state.files) == "table" then
    for id, item in pairs(state.files) do
      local value = type(item) == "table" and record(item.base, item.head, item)
      if type(id) ~= "string" or not value or type(item.status) ~= "string" or key(value) ~= id then
        ok = false
        break
      end
    end
  else ok = false end
  if not ok then
    error("Could not read local viewed state: " .. file .. ". The file has been preserved.", 0)
  end
  if next(state.files) == nil then state.files = vim.empty_dict() end
  return state
end

function M.is(state, base, head, file)
  if type(state) ~= "table" or type(state.files) ~= "table" then return false end
  local value = record(base, head, file)
  return value ~= nil and state.files[key(value)] ~= nil
end

function M.set(state, base, head, file, enabled)
  local value = record(base, head, file)
  if not value then error("The file's Git comparison is not loaded yet.", 0) end
  state.files[key(value)] = enabled and value or nil
  if next(state.files) == nil then state.files = vim.empty_dict() end
end

function M.save(config, target, state)
  local file = path(config, target)
  local data = vim.json.encode(state)
  vim.fn.mkdir(vim.fn.fnamemodify(file, ":h"), "p")
  local temporary = file .. "." .. vim.uv.hrtime() .. ".tmp"
  local fd, open_error = vim.uv.fs_open(temporary, "wx", 384)
  if not fd then error(open_error, 0) end
  local offset = 0
  while offset < #data do
    local written, write_error = vim.uv.fs_write(fd, data:sub(offset + 1), offset)
    if not written or written == 0 then
      vim.uv.fs_close(fd)
      vim.uv.fs_unlink(temporary)
      error(write_error or "Could not save local viewed state.", 0)
    end
    offset = offset + written
  end
  local closed, close_error = vim.uv.fs_close(fd)
  if not closed then vim.uv.fs_unlink(temporary); error(close_error, 0) end
  local renamed, rename_error = vim.uv.fs_rename(temporary, file)
  if not renamed then vim.uv.fs_unlink(temporary); error(rename_error, 0) end
end

return M
