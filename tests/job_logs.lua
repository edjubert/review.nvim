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
    raises(function() logs.validate({ split = true }) end, "split")
    local invalid_split = adapter(function() end)
    invalid_split.split = "pattern"
    raises(function() logs.validate({ adapters = { invalid_split } }) end, ".split")
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

  test("campaign splitting is opt-in and groups interleaved parsed lines without changing the full log", function()
    local reads, parses = 0, 0
    local content = table.concat({
      "global setup",
      "\27[32m[gesteam_first_run] ▶ load: load-csv gesteam-csv\27[0m",
      "[immopen_first_run] ▶ transform: transform",
      "[gesteam_second_run] ▶ load: load-csv gesteam-csv",
      "[gesteam_first_run] ✓ load: load-csv gesteam-csv (9m3s)",
      "[gesteam_compare_with_main] ▶ wait: transformation",
      "[login_extraction] ✗ extraction: execute extraction.login.yml (4m18s)",
    }, "\r\n")
    local custom = {
      id = "steps", list = function() return { { id = "ci-steps", label = "CI steps (parsed trace)" } } end,
      read = function() reads = reads + 1; return "raw input" end,
      parse = function(raw, ctx, item)
        eq(raw, "raw input"); eq(ctx.job_id, 7); eq(item.id, "ci-steps")
        parses = parses + 1
        return content
      end,
    }
    local c = controller({ adapters = { custom } })
    eq(#c.list(job), 2); eq(reads, 0)
    custom.split = function(line, ctx, item)
      eq(ctx.pipeline_id, 42); eq(item.id, "ci-steps")
      assert(not line:find("[\r\n]"), "Classifiers receive a line without its newline")
      return line:match("%[([%w_-]+)%]")
    end
    local sources, errors = c.list(job)
    eq(#sources, 7); eq(errors, {})
    eq(sources[2].label, "CI steps (parsed trace)")
    eq(sources[3].label, "CI steps (parsed trace) · gesteam_first_run")
    eq(sources[4].campaign, "immopen_first_run")
    eq(sources[5].campaign, "gesteam_second_run")
    eq(sources[6].campaign, "gesteam_compare_with_main")
    eq(sources[7].campaign, "login_extraction")
    eq(c.read(job, sources[3]).trace,
      "\27[32m[gesteam_first_run] ▶ load: load-csv gesteam-csv\27[0m\r\n"
      .. "[gesteam_first_run] ✓ load: load-csv gesteam-csv (9m3s)\r\n")
    eq(c.read(job, sources[7]).trace, "[login_extraction] ✗ extraction: execute extraction.login.yml (4m18s)")
    eq(reads, 1); eq(parses, 1)
    eq(c.read(job, sources[2]).trace, content)
    c.select(job, sources[3])
    eq(c.selected(job).campaign, "gesteam_first_run")
    eq(c.selected(vim.tbl_extend("force", job, { id = 8 })).key, "gitlab-trace/trace")
  end)

  test("global split rules run after fallback parsing and adapter split rules take precedence", function()
    local custom = {
      id = "custom", list = function() return { { id = "one" } } end,
      read = function() return "adapter raw" end,
      split = function(line, _, item)
        eq(item.id, "one"); eq(line, "[custom_run] adapter raw")
        return "override_run"
      end,
    }
    local c = controller({
      adapters = { custom },
      parse = function(content, _, item)
        return "[" .. (item.id == "trace" and "trace_run" or "custom_run") .. "] " .. content
      end,
      split = function(line, _, item)
        eq(item.id, "trace")
        return line:match("%[([%w_]+)%]")
      end,
    })
    mocked({ { provider, "job_trace", function() return "trace raw" end } }, function()
      local sources, errors = c.list(job)
      eq(#sources, 4); eq(errors, {})
      eq(sources[2].campaign, "trace_run"); eq(sources[4].campaign, "override_run")
      eq(c.read(job, sources[2]).trace, "[trace_run] trace raw")
      eq(c.read(job, sources[4]).trace, "[custom_run] adapter raw")
    end)
  end)

  test("campaign refreshes share the parent cursor, retain filtered content on failure and reset with snapshots", function()
    local calls, fail, replace, cursors = 0, false, false, {}
    local custom = {
      id = "stream", list = function() return { { id = "runs" } } end,
      split = function(line) return line:match("%[([%w_]+)%]") end,
      read = function(_, _, cursor)
        cursors[#cursors + 1] = cursor or 0
        if fail then error("read failed") end
        if replace then return "[b_run] replacement\n" end
        calls = calls + 1
        return { content = ("[a_run] chunk %d\n[b_run] chunk %d\n"):format(calls, calls),
          cursor = (cursor or 0) + 1, mode = "append" }
      end,
    }
    local c = controller({ adapters = { custom } })
    local sources = c.list(job)
    local a, b = sources[3], sources[4]
    eq(c.read(job, a).trace, "[a_run] chunk 1\n")
    eq(c.read(job, b).trace, "[b_run] chunk 1\n")
    eq(c.read(job, a, true).trace, "[a_run] chunk 1\n[a_run] chunk 2\n")
    eq(c.read(job, b).trace, "[b_run] chunk 1\n[b_run] chunk 2\n")
    fail = true
    local value = c.read(job, b, true)
    eq(value.trace, "[b_run] chunk 1\n[b_run] chunk 2\n")
    assert(value.log_error:find("read failed", 1, true))
    fail = false
    eq(c.read(job, a, true).trace, "[a_run] chunk 1\n[a_run] chunk 2\n[a_run] chunk 3\n")
    eq(cursors, { 0, 1, 2, 2 })
    replace = true
    eq(c.read(job, a, true).trace, "")
    eq(c.read(job, b).trace, "[b_run] replacement\n")
    replace = false
    eq(c.read(job, b, true).trace, "[b_run] replacement\n[b_run] chunk 4\n")
    eq(cursors[#cursors], 0)
    eq(c.read(vim.tbl_extend("force", job, { id = 8 }), a).trace, "[a_run] chunk 5\n")
    eq(cursors[#cursors], 0)
  end)

  test("campaign discovery and previews isolate invalid classifiers and parser failures", function()
    local broken = false
    local custom = {
      id = "custom", list = function() return { { id = "runs" }, { id = "unrelated" } } end,
      read = function() return "[a_run] first\n[b_run] second\n" end,
      split = function(line, _, item)
        if item.id == "unrelated" then return end
        if broken then
          if line:find("first", 1, true) then return "a_run" end
          return {}
        end
        return line:match("%[([%w_]+)%]")
      end,
    }
    local c = controller({ adapters = { custom } })
    local campaign = c.list(job)[3]
    broken = true
    local sources, errors = c.list(job)
    eq(#sources, 3); eq(#errors, 1)
    assert(errors[1]:find("campaign name", 1, true))
    local value = c.read(job, campaign, true)
    eq(value.trace, "[a_run] first\n[b_run] second\n")
    assert(value.split_error:find("campaign name", 1, true))
    custom.parse = function() error("invalid JSON") end
    custom.split = function() error("must not split an unparsed log") end
    value = c.read(job, campaign, true)
    eq(value.trace, "[a_run] first\n[b_run] second\n")
    assert(value.parse_error:find("invalid JSON", 1, true)); eq(value.split_error, nil)
    sources, errors = c.list(job)
    eq(#sources, 3); eq(#errors, 2)
    custom.parse = nil
    custom.read = function() error("transport failure") end
    sources, errors = c.list(job)
    eq(#sources, 3); eq(#errors, 4)
  end)

  test("concurrent campaign discovery shares an in-flight parent read and closing skips late classifiers", function()
    local finish, reads, splits = nil, 0, 0
    local c = controller({
      split = function(line) splits = splits + 1; return line:match("%[([%w_]+)%]") end,
    })
    local async = require("review.async")
    mocked({ { provider, "job_trace", function()
      reads = reads + 1
      return coroutine.yield(function(done) finish = done end)
    end } }, function()
      local trace = async.future(function() return c.read(job, c.selected(job)) end)
      local discovery = async.future(function() return c.list(job) end)
      eq(reads, 1)
      finish("[a_run] first\n[b_run] second\n")
      local sources = run(function() return async.await(discovery) end)
      eq(#sources, 3); eq(reads, 1)
      eq(run(function() return async.await(trace) end).trace, "[a_run] first\n[b_run] second\n")
      local a = async.future(function() return c.read(job, sources[2], true) end)
      local b = async.future(function() return c.read(job, sources[3], true) end)
      eq(reads, 2)
      finish("[a_run] refreshed\n[b_run] refreshed\n")
      eq(run(function() return async.await(a) end).trace, "[a_run] refreshed\n")
      eq(run(function() return async.await(b) end).trace, "[b_run] refreshed\n")
      local late = async.future(function() return c.list(job) end)
      local before = splits
      c.close()
      finish("[late_run] ignored\n")
      eq(#run(function() return async.await(late) end), 1)
      eq(splits, before)
    end)
  end)

  test("closing during a campaign classifier skips subsequent lines and discards discovery or preview results", function()
    local async = require("review.async")
    for _, operation in ipairs({ "list", "read" }) do
      local finish, waiting, calls = nil, false, 0
      local c = controller({
        split = function(line)
          calls = calls + 1
          if waiting then return coroutine.yield(function(done) finish = done end) end
          return line:match("%[([%w_]+)%]")
        end,
      })
      mocked({ { provider, "job_trace", function() return "[a_run] first\n[b_run] second\n" end } }, function()
        local item = operation == "read" and c.list(job)[2] or nil
        waiting = true
        local before = calls
        local future = async.future(function()
          if item then return c.read(job, item) end
          return c.list(job)
        end)
        eq(calls, before + 1)
        c.close()
        finish("a_run")
        local value = run(function() return async.await(future) end)
        if item then eq(value.deferred, true); eq(value.trace, nil)
        else eq(#value, 1) end
        eq(calls, before + 1)
      end)
    end
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
