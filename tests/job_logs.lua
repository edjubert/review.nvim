return function(h)
  local test, eq, raises, mocked, run = h.test, h.eq, h.raises, h.mocked, h.run
  local logs = require("review.job_logs")
  local provider = require("review.providers.gitlab")
  local target = { provider = "gitlab", host = "gitlab.example", project = "group/nested/repo" }
  local pipeline = { id = 42 }
  local job = { id = 7, project_id = 23, pipeline_id = 42, state = "running" }
  local function controller(opts)
    return logs.new({ target = target, provider = provider, config = { job_logs = opts } }, pipeline)
  end
  local function adapter(read, parse)
    return {
      id = "custom", list = function() return { { id = "one", label = "Run one" }, { id = "two" } } end,
      read = read, parse = parse,
    }
  end

  test("GitLab traces preserve the authenticated GET transport and fork project", function()
    local calls = {}
    mocked({ { provider, "request", function(t, endpoint, body, method, raw)
      eq(t, target); eq(body, nil); eq(method, "GET"); eq(raw, true)
      calls[#calls + 1] = endpoint
      return "original trace"
    end } }, function()
      local c = controller()
      eq(c.read(job, c.selected(job)).trace, "original trace")
      eq(provider.job_trace(target, { id = 8 }), "original trace")
      eq(provider.job_trace(target, job, "projects/{project_id}/pipelines/{pipeline_id}/jobs/{job_id}/trace"), "original trace")
      eq(calls, {
        "projects/23/jobs/7/trace", "projects/group%2Fnested%2Frepo/jobs/8/trace",
        "projects/23/pipelines/42/jobs/7/trace",
      })
      raises(function() provider.job_trace(target, { id = 0 }) end, "valid GitLab ID")
      raises(function() provider.job_trace(target, vim.tbl_extend("force", job, { trigger = true })) end, "do not have job logs")
    end)
  end)

  test("invalid log configuration is rejected before running transports", function()
    raises(function() logs.validate({ gitlab = { trace_path = "https://other.example/trace" } }) end, "relative")
    raises(function() logs.validate({ gitlab = { trace_path = "projects/{secret}/trace" } }) end, "placeholder")
    raises(function() logs.validate({ gitlab = { trace_path = "projects/../trace" } }) end, "Invalid")
    raises(function() logs.validate({ gitlab = { artifacts = { "logs/*.log" } } }) end, "exact")
    raises(function() logs.validate({ gitlab = { artifacts = { "../run.log" } } }) end, "Invalid")
    raises(function() logs.validate({ adapters = { { id = "gitlab-trace", list = function() end, read = function() end } } }) end, "reserved")
    raises(function() logs.validate({ adapters = { { id = "custom", list = function() end } } }) end, "read")
    raises(function() logs.validate({ parse = true }) end, "parse")
    raises(function() logs.validate({ gitlab = false }) end, "must be a table")
    raises(function() logs.validate({ gitlab = { trace_path = false } }) end, "relative")
    raises(function() logs.validate({ adapters = false }) end, "must be a list")
  end)

  test("artifact logs are opt-in, available on finished jobs and encode individual path segments", function()
    local c = controller({ gitlab = { artifacts = { "logs/unit tests.log" } } })
    eq(#c.list(job), 1)
    local finished = vim.tbl_extend("force", job, { state = "failed", erased_at = "yesterday" })
    local sources = c.list(finished)
    eq(#sources, 2); eq(sources[1].key, "gitlab-trace/trace")
    mocked({ { provider, "request", function(_, endpoint, body, method, raw)
      eq(endpoint, "projects/23/jobs/7/artifacts/logs/unit%20tests.log")
      eq(body, nil); eq(method, "GET"); eq(raw, true)
      return "artifact log"
    end } }, function()
      eq(c.read(finished, sources[2]).trace, "artifact log")
      eq(c.read(finished, sources[1]).trace, "")
    end)
  end)

  test("source discovery isolates matching errors and invalid lists while keeping the trace", function()
    local skipped = adapter(function() error("must not read") end)
    skipped.match = function(ctx)
      eq(ctx.host, "gitlab.example"); eq(ctx.pipeline_id, 42); eq(ctx.job_id, 7)
      return false
    end
    skipped.list = function() error("must not list") end
    local broken = { id = "broken", match = function() error("no credentials") end,
      list = function() end, read = function() end }
    local invalid = { id = "invalid", list = function() return { { id = "x" }, { id = "x" } } end,
      read = function() end }
    local c = controller({ adapters = { skipped, broken, invalid } })
    local sources, errors = c.list(job)
    eq(#sources, 1); eq(#errors, 2)
    assert(errors[1]:find("no credentials", 1, true))
    assert(errors[2]:find("Duplicate", 1, true))
  end)

  test("incremental logs isolate cursors between sources, jobs, projects and retry ids", function()
    local seen = {}
    local custom = adapter(function(ctx, item, cursor)
      seen[#seen + 1] = { ctx.job_id, ctx.project_id, item.id, cursor }
      eq(ctx.project, target.project); eq(ctx.provider, "gitlab")
      local start = cursor or 0
      return { content = tostring(start) .. "\n", cursor = start + 1, mode = "append" }
    end)
    local c = controller({ adapters = { custom } })
    local sources = c.list(job)
    eq(c.read(job, sources[2]).trace, "0\n")
    eq(c.read(job, sources[2]).trace, "0\n1\n")
    eq(c.read(job, sources[3]).trace, "0\n")
    eq(c.read(vim.tbl_extend("force", job, { id = 8 }), sources[2]).trace, "0\n")
    eq(c.read(vim.tbl_extend("force", job, { project_id = 99 }), sources[2]).trace, "0\n")
    eq(seen[2][4], 1)
    c.select(job, sources[2]); eq(c.selected(job).key, "custom/one")
    eq(c.selected(vim.tbl_extend("force", job, { id = 8 })).key, "gitlab-trace/trace")
  end)

  test("failed or invalid incremental reads retain content and retry the previous cursor", function()
    local count, fail = 0, false
    local c = controller({ adapters = { adapter(function(_, _, cursor)
      count = count + 1
      if count > 1 then eq(cursor, { offset = 1 }) end
      if fail then cursor.offset = 99; error("read failed") end
      return { content = "line\n", cursor = { offset = 1 }, mode = "append" }
    end) } })
    local s = c.list(job)[2]
    eq(c.read(job, s).trace, "line\n")
    fail = true
    local failure = c.read(job, s)
    eq(failure.trace, "line\n"); assert(failure.log_error:find("read failed", 1, true))
    fail = false
    eq(c.read(job, s).trace, "line\nline\n")
    s.adapter.read = function() return { content = "lost", mode = "append" } end
    local invalid = c.read(job, s)
    eq(invalid.trace, "line\nline\n"); assert(invalid.log_error:find("cursor", 1, true))
  end)

  test("parsers are optional, preserve raw stream cursors and fall back to original text on failure", function()
    local c = controller({ adapters = { adapter(function(_, _, cursor)
      return { content = "info\n", cursor = (cursor or 0) + 1, mode = "append" }
    end, function(content) return content:upper() end) } })
    local s = c.list(job)[2]
    eq(c.read(job, s).trace, "INFO\n")
    s.adapter.parse = function() error("invalid JSON") end
    local value = c.read(job, s)
    eq(value.trace, "info\ninfo\n"); assert(value.parse_error:find("invalid JSON", 1, true))
    s.adapter.parse = function() return {} end
    assert(c.read(job, s).parse_error:find("must return text", 1, true))
    local global = controller({ parse = function(content) return "parsed: " .. content end })
    mocked({ { provider, "job_trace", function() return "trace" end } }, function()
      eq(global.read(job, global.selected(job)).trace, "parsed: trace")
    end)
  end)

  test("adapter hooks can yield through argument-array processes without blocking other requests", function()
    local c = controller({ adapters = { adapter(function(ctx)
      return ctx.system({ "mock-reader", "--job", tostring(ctx.job_id) })
    end) } })
    mocked({ { vim, "system", function(argv, opts, done)
      eq(argv, { "mock-reader", "--job", "7" }); eq(opts.text, true)
      vim.schedule(function() done({ code = 0, stdout = "async log" }) end)
      return {}
    end } }, function()
      local value = run(function()
        local s = c.list(job)[2]
        return c.read(job, s)
      end)
      eq(value.trace, "async log")
    end)
  end)

  test("incremental buffers keep a bounded UTF-8 tail and never reset the remote cursor", function()
    local calls = 0
    local c = controller({ adapters = { adapter(function(_, _, cursor)
      calls = calls + 1
      if calls == 1 then
        return { content = ("é\n"):rep(logs.max_bytes), cursor = 900000, mode = "append" }
      end
      eq(cursor, 900000)
      return { content = "last line\n", cursor = 900010, mode = "append" }
    end) } })
    local s = c.list(job)[2]
    local value = c.read(job, s)
    assert(#value.trace <= logs.max_bytes); eq(value.truncated, true)
    assert(value.trace:sub(1, 3) == "é\n")
    value = c.read(job, s)
    assert(#value.trace <= logs.max_bytes); eq(value.truncated, true)
    assert(value.trace:sub(-10) == "last line\n")
    s.adapter.read = function() return "replacement" end
    value = c.read(job, s)
    eq(value.trace, "replacement"); eq(value.truncated, false)
  end)

  test("closing a log controller drops late content and skips parsers and subsequent hooks", function()
    local done, parsed, reads = nil, 0, 0
    local c = controller({ adapters = { adapter(function()
      reads = reads + 1
      return coroutine.yield(function(finish) done = finish end)
    end, function(content) parsed = parsed + 1; return content end) } })
    local s = c.list(job)[2]
    local future = require("review.async").future(function() return c.read(job, s) end)
    c.close()
    done("late content")
    local value = run(function() return require("review.async").await(future) end)
    eq(value.deferred, true); eq(value.trace, nil); eq(parsed, 0)
    eq(c.read(job, s).deferred, true); eq(reads, 1)
    eq(#c.list(job), 1)
  end)
end
