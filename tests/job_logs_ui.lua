return function(h)
  local test, eq, mocked = h.test, h.eq, h.mocked
  local function fixture(opts, fn, interval, extra_jobs, provider_overrides)
    local saved, pickers, buffers, timers, selection, module = {}, {}, {}, {}, nil, nil
    local function buffer()
      local buf = vim.api.nvim_create_buf(false, true)
      buffers[#buffers + 1] = buf
      return buf
    end
    local function wait_for(predicate)
      assert(vim.wait(1000, predicate, 5), "Picker operation timed out")
    end
    local replacements = {
      ["telescope.pickers"] = { new = function(_, spec)
        local picker = {
          spec = spec, closed = false, maps = {}, prompt_text = "", results_win = -1,
          prompt_title = spec.prompt_title, results_title = spec.results_title,
        }
        function picker:get_selection() return self.entry end
        function picker:_get_prompt() return self.prompt_text end
        function picker:set_prompt(value) self.prompt_text = value end
        function picker:get_row(index) return index - 1 end
        function picker:set_selection(row)
          self.entry = self.spec.finder.results[row + 1]
          self.spec.previewer.define_preview(self.spec.previewer, self.entry)
        end
        picker.manager = { iter = function()
          local index = 0
          return function()
            index = index + 1
            return picker.spec.finder.results[index]
          end
        end }
        function picker:find()
          self.prompt, self.results_bufnr = buffer(), buffer()
          self.entry = self.spec.finder.results[1]
          self.spec.attach_mappings(self.prompt, function(mode, key, action) self.maps[mode .. key] = action end)
          if self.spec.previewer then
            self.spec.previewer.state = { bufnr = buffer() }
            self.spec.previewer.define_preview(self.spec.previewer, self.entry)
          end
          vim.api.nvim_set_current_buf(self.prompt)
        end
        function picker:refresh(finder, options)
          self.spec.finder = finder
          self.entry = finder.results[1]
          if options and options.reset_prompt then self.prompt_text = "" end
          for _, callback in ipairs(self.spec.on_complete or {}) do callback(self) end
          self.spec.previewer.define_preview(self.spec.previewer, self.entry)
        end
        pickers[#pickers + 1] = picker
        return picker
      end },
      ["telescope.finders"] = { new_table = function(value) return value end },
      ["telescope.previewers"] = { new_buffer_previewer = function(spec) return spec end },
      ["telescope.config"] = { values = { generic_sorter = function() return { score = function() return 1 end } end } },
      ["telescope.actions"] = { close = function()
        local p = pickers[#pickers]
        p.closed = true
        if p.spec.previewer.teardown then p.spec.previewer.teardown() end
      end },
      ["telescope.actions.set"] = {
        select = { replace = function(_, callback) selection = callback end },
        edit = { replace = function() end },
      },
      ["telescope.actions.state"] = { get_selected_entry = function() return pickers[#pickers]:get_selection() end },
      ["telescope.pickers.entry_display"] = { create = function() return function() return "row" end end },
    }
    saved["review.telescope"] = package.loaded["review.telescope"]
    package.loaded["review.telescope"] = nil
    for name, value in pairs(replacements) do saved[name], package.loaded[name] = package.loaded[name], value end
    local job = { id = 7, project_id = 23, pipeline_id = 42, name = "tests", state = "running", stage = "test" }
    local pipeline = { id = 42, project_id = 23, sha = "head", state = "running", jobs = { job } }
    vim.list_extend(pipeline.jobs, extra_jobs or {})
    local provider = {
      prefix = "!",
      pipeline_details = function() return pipeline end, job_details = function(_, value) return value end,
      job_trace = function() return "\27[32moriginal trace\27[0m\n" end,
      job_artifact = function() return "artifact output\n" end,
    }
    for name, value in pairs(provider_overrides or {}) do provider[name] = value end
    local session = {
      config = { keymaps = {}, pipeline_refresh_interval = interval or 0, job_logs = opts },
      target = { provider = "gitlab", project = "group/repo", host = "gitlab.example", iid = 12 },
      provider = provider, data = { mr = { diff_refs = { head_sha = "head" } } },
    }
    local ok, err = xpcall(function()
      local overrides = { { require("review.ui"), "valid", function() return true end } }
      if interval then
        overrides[#overrides + 1] = { vim.uv, "new_timer", function()
          local timer = {}
          function timer:start(_, _, callback) self.active, self.callback = true, callback end
          function timer:stop() self.active = false end
          function timer:close() self.closed = true end
          function timer:is_active() return self.active end
          timers[#timers + 1] = timer
          return timer
        end }
      end
      mocked(overrides, function()
        module = require("review.telescope")
        module.pipelines(session, { pipeline })
        selection()
        wait_for(function() return #pickers == 2 end)
        local picker = pickers[2]
        local function content()
          return table.concat(vim.api.nvim_buf_get_lines(picker.spec.previewer.state.bufnr, 0, -1, false), "\n")
        end
        local function choose(index)
          mocked({ { vim.ui, "select", function() error("Nested UI must not be opened") end } }, function()
            module.select_job_log(session)
          end)
          if index then
            picker:set_selection(index - 1)
            selection()
          else picker.maps["n<Esc>"]() end
        end
        fn({
          module = module, session = session, picker = picker, provider = provider,
          content = content, choose = choose, wait = wait_for,
          timer = timers[#timers],
          close = function()
            picker.closed = true; picker.spec.previewer.teardown()
          end,
        })
      end)
    end, debug.traceback)
    for name in pairs(replacements) do package.loaded[name] = saved[name] end
    package.loaded["review.telescope"] = saved["review.telescope"]
    for _, buf in ipairs(buffers) do if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_delete(buf, { force = true }) end end
    assert(ok, err)
  end

  test("job log selection preserves the trace, renders custom ANSI and leaves cancellation unchanged", function()
    fixture({ adapters = { {
      id = "custom", list = function() return { { id = "run", label = "Run log" } } end,
      read = function() return "\27[31mcustom output\27[0m\n" end,
    } } }, function(f)
      assert(f.content():find("original trace", 1, true))
      f.choose(nil); assert(f.content():find("original trace", 1, true))
      f.choose(2)
      assert(f.content():find("Log · Run log", 1, true))
      assert(f.content():find("custom output", 1, true))
      assert(not f.content():find("\27", 1, true))
      local namespace = vim.api.nvim_create_namespace("review.pipeline")
      local marks = vim.api.nvim_buf_get_extmarks(f.picker.spec.previewer.state.bufnr, namespace, 0, -1, { details = true })
      local colored = false
      for _, mark in ipairs(marks) do
        if tostring(mark[4].hl_group):find("ReviewJobAnsi_", 1, true) then colored = true end
      end
      assert(colored, "Custom logs must pass through the ANSI renderer")
      f.choose(1); assert(f.content():find("original trace", 1, true))
      f.close()
    end)
  end)

  test("log source discovery stays inside Telescope even when vim.ui.select opens another picker", function()
    fixture({ adapters = { {
      id = "custom", list = function() return { { id = "run", label = "Run log" } } end,
      read = function() return "custom output\n" end,
    } } }, function(f)
      local nested = 0
      mocked({ { vim.ui, "select", function(_, _, done)
        nested = nested + 1
        done(nil)
      end } }, function()
        f.module.select_job_log(f.session)
      end)
      eq(nested, 0)
      eq(f.picker.closed, false)
      eq(#f.picker.spec.finder.results, 2)
      eq(f.picker.spec.finder.results[2].display, "Run log")
      f.close()
    end)
  end)

  test("choosing and canceling log sources preserve the prompt, query and selected job", function()
    fixture({ adapters = { {
      id = "custom", list = function() return { { id = "run", label = "Run log" } } end,
      read = function() return "custom output\n" end,
    } } }, function(f)
      f.picker:set_selection(1)
      eq(f.picker:get_selection().value.id, 7)
      local prompt, title = f.picker.prompt, f.picker.prompt_title
      f.picker:set_prompt("tests")
      f.choose(2)
      eq(f.picker.prompt, prompt)
      eq(f.picker.prompt_title, title)
      eq(f.picker:_get_prompt(), "tests")
      eq(f.picker:get_selection().value.id, 7)
      assert(f.content():find("custom output", 1, true))
      f.module.select_job_log(f.session)
      eq(f.picker:_get_prompt(), "")
      eq(f.picker.prompt_title, "Job #7 log sources")
      f.picker:set_prompt("Run")
      f.picker.maps["i<Esc>"]()
      eq(f.picker.closed, false)
      eq(f.picker:_get_prompt(), "tests")
      eq(f.picker:get_selection().value.id, 7)
      assert(f.content():find("custom output", 1, true))
      f.close()
    end, nil, { { id = 6, project_id = 23, pipeline_id = 42, name = "another", state = "success", stage = "test" } })
  end)

  test("late source discovery cannot replace the results of a closed picker", function()
    local finish
    fixture({ adapters = { {
      id = "slow", list = function()
        return coroutine.yield(function(done) finish = done end)
      end,
      read = function() return "custom output\n" end,
    } } }, function(f)
      f.module.select_job_log(f.session)
      assert(finish)
      local finder = f.picker.spec.finder
      f.close()
      finish({ { id = "run" } })
      local settled = false
      vim.schedule(function() settled = true end)
      f.wait(function() return settled end)
      eq(f.picker.spec.finder, finder)
      eq(f.picker.closed, true)
    end)
  end)

  test("pending job metadata still loads the preview while choosing log sources", function()
    local finish, reads = nil, 0
    fixture({ adapters = { {
      id = "custom", list = function() return { { id = "run", label = "Run log" } } end,
      read = function() return "custom output\n" end,
    } } }, function(f)
      assert(f.content():find("Loading log", 1, true))
      f.module.select_job_log(f.session)
      eq(f.picker.prompt_title, "Job #7 log sources")
      finish()
      f.wait(function() return f.content():find("loaded after metadata", 1, true) ~= nil end)
      eq(reads, 1)
      eq(f.picker.prompt_title, "Job #7 log sources")
      f.close()
    end, nil, nil, {
      job_details = function(_, job)
        coroutine.yield(function(done) finish = done end)
        return job
      end,
      job_trace = function() reads = reads + 1; return "loaded after metadata\n" end,
    })
  end)

  test("a pending log response updates the preview while its source menu is open", function()
    local finish
    fixture({}, function(f)
      assert(f.content():find("Loading log", 1, true))
      f.module.select_job_log(f.session)
      finish("loaded while choosing\n")
      f.wait(function() return f.content():find("loaded while choosing", 1, true) ~= nil end)
      eq(f.picker.prompt_title, "Job #7 log sources")
      eq(f.picker.closed, false)
      f.close()
    end, nil, nil, {
      job_trace = function() return coroutine.yield(function(done) finish = done end) end,
    })
  end)

  test("confirming the trace before metadata arrives shares the pending load and updates the job preview", function()
    local finish, reads = nil, 0
    fixture({}, function(f)
      f.choose(1)
      eq(f.picker.prompt_title, "Pipeline #42 jobs")
      assert(f.content():find("Loading log", 1, true))
      finish()
      f.wait(function() return f.content():find("loaded after Enter", 1, true) ~= nil end)
      eq(reads, 1)
      assert(not f.content():find("Loading log", 1, true))
      f.close()
    end, nil, nil, {
      job_details = function(_, job)
        coroutine.yield(function(done) finish = done end)
        return job
      end,
      job_trace = function() reads = reads + 1; return "loaded after Enter\n" end,
    })
  end)

  test("manual log refresh retains streamed output on read errors and shows parser fallback", function()
    local calls, fail = 0, false
    fixture({ adapters = { {
      id = "stream", list = function() return { { id = "run" } } end,
      read = function(_, _, cursor)
        calls = calls + 1
        if fail then error("transport failure") end
        return { content = "chunk " .. calls .. "\n", mode = "append", cursor = (cursor or 0) + 1 }
      end,
      parse = function() error("parser failure") end,
    } } }, function(f)
      f.choose(2)
      assert(f.content():find("Parser failed; showing original log", 1, true))
      assert(f.content():find("chunk 1", 1, true))
      f.module.refresh_job(f.session)
      assert(f.content():find("chunk 1\nchunk 2", 1, true))
      fail = true
      f.module.refresh_job(f.session)
      assert(f.content():find("transport failure", 1, true))
      assert(f.content():find("chunk 1\nchunk 2", 1, true))
      f.close()
    end)
  end)

  test("late source reads cannot overwrite a different selection or a closed picker", function()
    local finish, reads = nil, 0
    fixture({ adapters = { {
      id = "slow", list = function() return { { id = "run" } } end,
      read = function()
        reads = reads + 1
        return coroutine.yield(function(done) finish = done end)
      end,
    } } }, function(f)
      f.choose(2); eq(reads, 1)
      f.module.refresh_job(f.session); eq(reads, 1)
      f.choose(1); assert(f.content():find("original trace", 1, true))
      finish("late output")
      local settled = false
      vim.schedule(function() settled = true end)
      f.wait(function() return settled end)
      assert(f.content():find("original trace", 1, true))
      f.choose(2)
      eq(reads, 2)
      f.wait(function() return f.content():find("Loading log", 1, true) ~= nil end)
      local buf = f.picker.spec.previewer.state.bufnr
      local before = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      f.close()
      finish("closed output")
      settled = false
      vim.schedule(function() settled = true end)
      f.wait(function() return settled end)
      eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), before)
    end)
  end)

  test("focused automatic refresh follows the selected source cursor and pauses outside Neovim focus", function()
    local reads = 0
    fixture({ adapters = { {
      id = "stream", list = function() return { { id = "run" } } end,
      read = function(_, _, cursor)
        eq(cursor or 0, reads)
        reads = reads + 1
        return { content = "tick " .. reads .. "\n", cursor = reads, mode = "append" }
      end,
    } } }, function(f)
      f.choose(2); eq(reads, 1)
      f.wait(function() return f.timer.active end)
      f.timer.callback()
      f.wait(function() return reads == 2 end)
      assert(f.content():find("tick 1\ntick 2", 1, true))
      vim.api.nvim_exec_autocmds("FocusLost", {})
      f.wait(function() return not f.timer.active end)
      f.timer.callback()
      local settled = false
      vim.schedule(function() settled = true end)
      f.wait(function() return settled end)
      eq(reads, 2)
      vim.api.nvim_exec_autocmds("FocusGained", {})
      f.wait(function() return f.timer.active end)
      f.timer.callback()
      f.wait(function() return reads == 3 end)
      f.close(); eq(f.timer.closed, true)
    end, 1000)
  end)

  test("artifact sources use refreshed job metadata even before the pipeline job list updates", function()
    fixture({ gitlab = { artifacts = { "logs/unit.log" } } }, function(f)
      f.provider.job_details = function(_, job)
        return vim.tbl_extend("force", job, { state = "failed" })
      end
      f.module.refresh_job(f.session)
      f.choose(2)
      assert(f.content():find("Artifact: logs/unit.log", 1, true))
      assert(f.content():find("artifact output", 1, true))
      f.close()
    end)
  end)
end
