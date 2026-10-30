local async = require("review.async")
local url = require("review.url")
local M = {}

M.trace_path = "projects/{project_id}/jobs/{job_id}/trace"
M.max_bytes = 512 * 1024
local placeholders = { project_id = true, project = true, job_id = true, pipeline_id = true }
local reserved = { ["gitlab-trace"] = true, ["gitlab-artifacts"] = true }

local function nonempty(value)
  return type(value) == "string" and value ~= "" and not value:find("%c")
end

local function validate_path(path)
  assert(nonempty(path) and path:match("^projects/") and not path:find("://", 1, true),
    "job_logs.gitlab.trace_path must be a relative projects/ GitLab API path")
  local literal = path:gsub("{([^{}]+)}", function(name)
    assert(placeholders[name], "Unknown job log placeholder: " .. name)
    return "value"
  end)
  assert(not literal:find("[{}#:]"), "Invalid job log trace path")
  for part in literal:gmatch("[^/?]+") do
    assert(part ~= "." and part ~= "..", "Invalid job log trace path")
  end
end

function M.validate_artifact(path)
  assert(nonempty(path) and path:sub(1, 1) ~= "/" and not path:find("\\", 1, true)
      and not path:find("//", 1, true) and not path:find("[*%?%[%]]"),
    "job log artifacts must be exact relative file paths")
  for part in path:gmatch("[^/]+") do
    assert(part ~= "." and part ~= "..", "Invalid job log artifact path")
  end
end

function M.validate(opts)
  assert(type(opts) == "table", "job_logs must be a table")
  local gitlab = opts.gitlab == nil and {} or opts.gitlab
  assert(type(gitlab) == "table", "job_logs.gitlab must be a table")
  validate_path(gitlab.trace_path == nil and M.trace_path or gitlab.trace_path)
  local artifacts = gitlab.artifacts == nil and {} or gitlab.artifacts
  assert(type(artifacts) == "table" and vim.islist(artifacts), "job_logs.gitlab.artifacts must be a list")
  local paths = {}
  for _, path in ipairs(artifacts) do
    M.validate_artifact(path)
    assert(not paths[path], "Duplicate job log artifact: " .. path)
    paths[path] = true
  end
  assert(opts.parse == nil or type(opts.parse) == "function", "job_logs.parse must be a function")
  local adapters = opts.adapters == nil and {} or opts.adapters
  assert(type(adapters) == "table" and vim.islist(adapters), "job_logs.adapters must be a list")
  local ids = vim.deepcopy(reserved)
  for _, adapter in ipairs(adapters) do
    assert(type(adapter) == "table" and nonempty(adapter.id) and adapter.id:match("^[%w_-]+$"),
      "Each job log adapter needs an id containing letters, digits, underscores or dashes")
    assert(not ids[adapter.id], "Duplicate or reserved job log adapter id: " .. adapter.id)
    ids[adapter.id] = true
    for _, name in ipairs({ "list", "read" }) do
      assert(type(adapter[name]) == "function", "Job log adapter " .. adapter.id .. " needs " .. name .. "()")
    end
    for _, name in ipairs({ "match", "parse" }) do
      assert(adapter[name] == nil or type(adapter[name]) == "function",
        "Job log adapter " .. adapter.id .. "." .. name .. " must be a function")
    end
  end
end

function M.trace_endpoint(target, job, path)
  path = path or M.trace_path
  validate_path(path)
  local values = {
    project_id = type(job.project_id) == "number" and job.project_id > 0
      and job.project_id == math.floor(job.project_id) and job.project_id or target.project,
    project = target.project,
    job_id = job.id, pipeline_id = job.pipeline_id,
  }
  return (path:gsub("{([^{}]+)}", function(name)
    assert(values[name] ~= nil, "Missing job log context: " .. name)
    return url.encode(tostring(values[name]))
  end))
end

local function tail(content)
  if #content <= M.max_bytes then return content, false end
  content = content:sub(-M.max_bytes)
  local newline = content:find("\n", 1, true)
  if newline then content = content:sub(newline + 1)
  else
    while #content > 0 and content:byte(1) >= 128 and content:byte(1) < 192 do content = content:sub(2) end
  end
  return content, true
end

local function source(adapter, item)
  assert(type(item) == "table" and nonempty(item.id), "A job log source needs a nonempty id")
  assert(item.label == nil or nonempty(item.label), "Invalid job log source label")
  return {
    key = adapter.id .. "/" .. item.id, label = item.label or item.id,
    adapter = adapter, data = vim.deepcopy(item),
  }
end

-- One controller per pipeline picker. Hooks run inside review.async coroutines
-- and can yield through ctx.system without owning timers or Neovim buffers.
function M.new(session, pipeline)
  local opts = session.config.job_logs or {}
  M.validate(opts)
  local selections, states, closed = {}, {}, false
  local controller = {}
  local trace_adapter = {
    id = "gitlab-trace",
    read = function(ctx)
      if type(ctx.job.erased_at) == "string" and ctx.job.erased_at ~= "" then return "" end
      assert(session.provider.job_trace, "Job logs are not available for this provider.")
      return session.provider.job_trace(ctx.target, ctx.job, (opts.gitlab or {}).trace_path)
    end,
  }
  local trace = source(trace_adapter, { id = "trace", label = "Job trace" })
  local artifact_adapter = {
    id = "gitlab-artifacts",
    read = function(ctx, item)
      assert(session.provider.job_artifact, "Job artifacts are not available for this provider.")
      return session.provider.job_artifact(ctx.target, ctx.job, item.path)
    end,
  }
  local function job_key(job)
    return tostring(job.project_id or session.target.project) .. "/" .. job.id
  end
  function controller.context(job)
    return {
      provider = session.target.provider, host = session.target.host, project = session.target.project,
      project_id = job.project_id, pipeline_id = pipeline.id, job_id = job.id,
      target = vim.deepcopy(session.target), job = vim.deepcopy(job), pipeline = vim.deepcopy(pipeline),
      system = async.checked,
    }
  end
  function controller.selected(job)
    return selections[job_key(job)] or trace
  end
  function controller.select(job, item)
    selections[job_key(job)] = item
  end
  function controller.list(job)
    local ctx, sources, errors = controller.context(job), { trace }, {}
    if closed then return sources, errors end
    if ctx.provider == "gitlab" and (job.state == "success" or job.state == "failed" or job.state == "canceled") then
      for _, path in ipairs((opts.gitlab or {}).artifacts or {}) do
        sources[#sources + 1] = source(artifact_adapter, { id = path, label = "Artifact: " .. path, path = path })
      end
    end
    for _, adapter in ipairs(opts.adapters or {}) do
      if closed then break end
      local ok, result = pcall(function()
        if adapter.match and not adapter.match(controller.context(job)) then return {} end
        if closed then return {} end
        local items = adapter.list(controller.context(job))
        assert(type(items) == "table" and vim.islist(items), "list() must return a list of log sources")
        local found, ids = {}, {}
        for _, item in ipairs(items) do
          local entry = source(adapter, item)
          assert(not ids[entry.key], "Duplicate job log source id: " .. item.id)
          ids[entry.key], found[#found + 1] = true, entry
        end
        return found
      end)
      if ok then vim.list_extend(sources, result)
      else errors[#errors + 1] = adapter.id .. ": " .. tostring(result) end
    end
    return sources, errors
  end
  function controller.read(job, item)
    if closed then return { source = item, deferred = true } end
    local key = job_key(job) .. "/" .. item.key
    local previous = states[key] or { content = "" }
    local ctx = controller.context(job)
    local value = { source = item, trace = previous.content, truncated = previous.truncated }
    local ok, result = pcall(function()
      local chunk = item.adapter.read(ctx, vim.deepcopy(item.data), vim.deepcopy(previous.cursor))
      if type(chunk) == "string" then chunk = { content = chunk, mode = "replace" } end
      assert(type(chunk) == "table" and type(chunk.content) == "string",
        "read() must return text or a chunk with string content")
      local mode = chunk.mode or "replace"
      assert(mode == "replace" or mode == "append", "Invalid job log chunk mode")
      assert(mode ~= "append" or chunk.cursor ~= nil, "An appended job log chunk needs a cursor")
      local content, truncated = tail(mode == "append" and (previous.content .. chunk.content) or chunk.content)
      return {
        content = content, cursor = vim.deepcopy(chunk.cursor),
        truncated = truncated or (mode == "append" and previous.truncated) or false,
      }
    end)
    if ok then
      if not closed then states[key] = result end
      previous = result
    else value.log_error = tostring(result) end
    value.trace, value.truncated = previous.content, previous.truncated
    if closed then return { source = item, deferred = true } end
    local parse = item.adapter.parse or opts.parse
    if parse then
      local parsed, content = pcall(parse, value.trace, controller.context(job), vim.deepcopy(item.data))
      if parsed and type(content) == "string" then value.trace = content
      else value.parse_error = parsed and "parse() must return text" or tostring(content) end
    end
    return value
  end
  function controller.close()
    closed = true
    selections, states = {}, {}
  end
  return controller
end

return M
