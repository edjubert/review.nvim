return function(t)
  local test, eq, mocked = t.test, t.eq, t.mocked
  local input = require("review.input")
  local valid = "https://github.com/owner/repo/pull/123"
  local names = {
    "telescope.pickers", "telescope.finders", "telescope.config",
    "telescope.actions", "telescope.actions.set", "telescope.actions.state",
  }

  local function with_telescope(available, fn)
    local original, captured, handlers = {}, {}, {}
    for _, name in ipairs(names) do
      original[name] = { loaded = package.loaded[name], preload = package.preload[name] }
      package.loaded[name] = nil
      package.preload[name] = function() error("Telescope unavailable in this fixture") end
    end
    if available then
      package.loaded["telescope.pickers"] = { new = function(_, options)
        captured.options = options
        return { find = function()
          options.attach_mappings(42, function(mode, key, action)
            captured[mode .. key] = action
          end)
        end }
      end }
      package.loaded["telescope.finders"] = { new_table = function(options) return options end }
      package.loaded["telescope.config"] = { values = { generic_sorter = function() return {} end } }
      package.loaded["telescope.actions"] = { close = function(buf) captured.closed = buf end }
      package.loaded["telescope.actions.set"] = {
        select = { replace = function(_, action) handlers.select = action end },
        edit = { replace = function(_, action) handlers.edit = action end },
      }
      package.loaded["telescope.actions.state"] = {
        get_current_line = function() return captured.line or "" end,
        get_selected_entry = function() return captured.selected end,
      }
    end
    local ok, err = xpcall(function()
      mocked({ { require("review.history"), "list", function() return {} end } },
        function() fn(captured, handlers) end)
    end, debug.traceback)
    for _, name in ipairs(names) do
      package.loaded[name], package.preload[name] = original[name].loaded, original[name].preload
    end
    assert(ok, err)
  end

  test("Review without a URL uses Telescope and treats input as a URL, never a filename", function()
    with_telescope(true, function(captured, handlers)
      local opened = {}
      mocked({
        { vim.ui, "input", function() error("Unexpected native input") end },
        { vim, "schedule", function(callback) callback() end },
      }, function()
        input.url(function(value) opened[#opened + 1] = value end)
        eq(captured.options.initial_mode, "insert")
        eq(captured.options.previewer, false)
        captured.line = "  " .. valid .. "  "
        handlers.select()
        eq(captured.closed, 42)
        eq(opened, { valid })
        captured.line = "https://gitlab.example/a/b/-/merge_requests/12"
        handlers.edit()
        eq(opened[2], captured.line)
      end)
    end)
  end)

  test("Telescope searches recent titles, opens selections and prioritizes a pasted URL", function()
    with_telescope(true, function(captured, handlers)
      local recent = { { url = valid, title = "Fix review picker" } }
      local opened = {}
      mocked({
        { require("review.history"), "list", function() return recent end },
        { vim, "schedule", function(callback) callback() end },
        { vim, "notify", function() end },
      }, function()
        input.url(function(value) opened[#opened + 1] = value end)
        eq(captured.options.finder.results, recent)
        captured.selected = captured.options.finder.entry_maker(recent[1])
        assert(captured.selected.ordinal:find("Fix review picker", 1, true))
        captured.line = "picker"
        handlers.select()
        eq(opened, { valid })
        captured.line = "https://github.com/another/repo/pull/9"
        handlers.select()
        eq(opened[2], captured.line)
        captured.closed = nil
        captured.line = "https://invalid"
        handlers.select()
        eq(#opened, 2)
        eq(captured.closed, nil)
      end)
    end)
  end)

  test("Without Telescope recent reviews remain selectable and new URL entry is available", function()
    with_telescope(false, function()
      local opened, selected, choices, prompts = {}, nil, nil, 0
      mocked({
        { require("review.history"), "list", function() return { { url = valid, title = "Recent" } } end },
        { vim.ui, "select", function(items, _, callback) choices = items; callback(selected and items[selected]) end },
        { vim.ui, "input", function(_, callback) prompts = prompts + 1; callback(valid) end },
      }, function()
        local function open(value) opened[#opened + 1] = value end
        input.url(open)
        eq(#choices, 2)
        eq(#opened, 0)
        selected = 2
        input.url(open)
        eq(opened, { valid })
        eq(prompts, 0)
        selected = 1
        input.url(open)
        eq(prompts, 1)
        eq(#opened, 2)
      end)
    end)
  end)

  test("Telescope keeps invalid and blank URLs editable and Escape cancels without opening", function()
    with_telescope(true, function(captured, handlers)
      local opened, warnings = 0, 0
      mocked({ { vim, "notify", function() warnings = warnings + 1 end } }, function()
        input.url(function() opened = opened + 1 end)
        handlers.select()
        eq(captured.closed, nil)
        captured.line = "file:///tmp/repo"
        handlers.select()
        eq(captured.closed, nil)
        eq(warnings, 1)
        captured["i<Esc>"](42)
        eq(captured.closed, 42)
        eq(opened, 0)
      end)
    end)
  end)

  test("URL input falls back without Telescope and ignores cancel, empty or invalid answers", function()
    with_telescope(false, function()
      local answer, opened = nil, {}
      mocked({
        { vim.ui, "input", function(_, callback) callback(answer) end },
        { vim, "notify", function() end },
      }, function()
        for _, value in ipairs({ false, "", "   ", "invalid", "  " .. valid .. " " }) do
          answer = value or nil
          input.url(function(url) opened[#opened + 1] = url end)
        end
        eq(opened, { valid })
      end)
    end)
  end)

  test("Review command delegates missing URLs to the picker but explicit URLs bypass it", function()
    local review = require("review")
    local prompts, loads = 0, 0
    local previous = review.session
    mocked({
      { input, "url", function() prompts = prompts + 1 end },
      { vim.fn, "executable", function() return 1 end },
      { require("review.session"), "new", function(target)
        eq(target.url, valid)
        return { load = function() loads = loads + 1 end }
      end },
    }, function()
      review.session = nil
      review._commands()
      vim.cmd.Review()
      review.open("   ")
      eq(prompts, 2)
      vim.cmd.Review(valid)
      eq(prompts, 2)
      eq(loads, 1)
    end)
    review.session = previous
  end)
end
