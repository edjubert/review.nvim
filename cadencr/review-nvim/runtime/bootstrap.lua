-- Runs before the user's init.lua, including plugin-manager setup.
local root = assert(vim.env.REVIEW_NVIM_RUNTIME, "Missing CadencR review runtime")
local owned = {}

local function is_review(name)
  return name == "review" or name:sub(1, 7) == "review."
end

local function loader(name)
  if not is_review(name) then return end
  assert(name == "review" or name:match("^review%.[%w_%.]+$"), "Invalid review module: " .. name)
  local path = root .. "/lua/" .. name:gsub("%.", "/")
  if vim.uv.fs_stat(path .. ".lua") then
    path = path .. ".lua"
  else
    path = path .. "/init.lua"
  end
  -- Missing modules must fail here instead of falling through to another version.
  local chunk, err = loadfile(path)
  assert(chunk, err)
  return function(...)
    local result = chunk(...)
    owned[name] = result == nil and (package.loaded[name] or true) or result
    return result
  end, path
end

local function activate()
  -- Keep modules loaded from this bundle, including the user's setup() options.
  for name, value in pairs(package.loaded) do
    if is_review(name) and value ~= owned[name] then package.loaded[name] = nil end
  end
  for name in pairs(package.preload) do
    if is_review(name) then package.preload[name] = nil end
  end
  for index = #package.loaders, 1, -1 do
    if package.loaders[index] == loader then table.remove(package.loaders, index) end
  end
  table.insert(package.loaders, 1, loader)
  vim.opt.runtimepath:prepend(root)
end

_G.CadencRReviewRuntime = { activate = activate }
activate()
-- Prevent another installation's plugin/review.lua from registering commands.
vim.g.loaded_review = true
require("review")._commands()
