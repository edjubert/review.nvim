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

-- Start independent reads now, then await their results from any coroutine.
-- A completed future can be awaited more than once (e.g. shared diff refs).
function M.future(fn)
  local future = { listeners = {} }
  local function finish(ok, ...)
    future.done, future.ok = true, ok
    future.results = { n = select("#", ...), ... }
    for _, done in ipairs(future.listeners) do done() end
    future.listeners = nil
  end
  M.run(function() finish(true, fn()) end, function(err) finish(false, err) end)
  return future
end

function M.await(future)
  if not future.done then
    coroutine.yield(function(done)
      if future.done then done()
      else future.listeners[#future.listeners + 1] = done end
    end)
  end
  if not future.ok then error(future.results[1], 0) end
  return unpack(future.results, 1, future.results.n)
end

function M.all(tasks)
  local futures, results = {}, {}
  for key, fn in pairs(tasks) do futures[key] = M.future(fn) end
  for key, future in pairs(futures) do results[key] = M.await(future) end
  return results
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
