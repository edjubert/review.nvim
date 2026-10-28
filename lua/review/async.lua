local M = {}

-- Every continuation runs on Neovim's main loop, including spawn failures.
function M.run(fn, on_error)
  local co = coroutine.create(fn)
  local function step(...)
    local ok, next_step = coroutine.resume(co, ...)
    if not ok then
      if on_error then
        on_error(tostring(next_step))
      else
        vim.notify(tostring(next_step), vim.log.levels.ERROR, { title = "review" })
      end
    elseif coroutine.status(co) ~= "dead" then
      local started, err = pcall(next_step, function(...)
        local args = { ... }
        vim.schedule(function() step(unpack(args)) end)
      end)
      if not started then
        vim.schedule(function() step({ code = -1, stderr = tostring(err), stdout = "" }) end)
      end
    end
  end
  step()
end

function M.system(argv, opts)
  return coroutine.yield(function(done)
    vim.system(argv, vim.tbl_extend("force", { text = true, timeout = 120000 }, opts or {}), done)
  end)
end

function M.checked(argv, opts)
  local result = M.system(argv, opts)
  if result.code ~= 0 then
    error(vim.trim(result.stderr or "") ~= "" and vim.trim(result.stderr)
      or ("Command failed: " .. argv[1] .. " (exit " .. result.code .. ")"), 0)
  end
  return result.stdout or ""
end

return M
