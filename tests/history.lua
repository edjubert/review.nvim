return function(t)
  local test, eq, mocked = t.test, t.eq, t.mocked
  local history = require("review.history")
  local url = require("review.url")

  local function fixture(fn)
    local root = vim.fn.tempname()
    local config = { state_dir = root .. "/state" }
    local ok, err = xpcall(function() fn(config) end, debug.traceback)
    vim.fn.delete(root, "rf")
    assert(ok, err)
  end

  test("Recent reviews persist, canonicalize URLs and keep the latest title per review", function()
    fixture(function(config)
      eq(history.list(config), {})
      local first = assert(url.parse("https://github.com/owner/repo/pull/1/files?x=1"))
      local second = assert(url.parse("https://gitlab.example/group/repo/-/merge_requests/2"))
      history.record(config, first, { title = "Old title" })
      history.record(config, second, { title = "Other review" })
      history.record(config, first, { title = "Updated\n title" })
      package.loaded["review.history"] = nil
      local recent = require("review.history").list(config)
      eq(#recent, 2)
      eq(recent[1].url, "https://github.com/owner/repo/pull/1")
      eq(recent[1].title, "Updated  title")
      eq(recent[2].url, second.url)
      eq(vim.uv.fs_stat(config.state_dir .. "/history.jsonl").mode % 512, 384)
    end)
  end)

  test("History shows the last 100 unique reviews", function()
    fixture(function(config)
      for id = 1, 105 do
        history.record(config, assert(url.parse("https://codeberg.org/owner/repo/pulls/" .. id)), {})
      end
      local recent = history.list(config)
      eq(#recent, 100)
      eq(recent[1].url, "https://codeberg.org/owner/repo/pulls/105")
      eq(recent[100].url, "https://codeberg.org/owner/repo/pulls/6")
    end)
  end)

  test("An interrupted or invalid history record is preserved without hiding later reviews", function()
    fixture(function(config)
      vim.fn.mkdir(config.state_dir, "p")
      local file = config.state_dir .. "/history.jsonl"
      vim.fn.writefile({ '{"version":1,"url":"file:///tmp"}', '{"incomplete":' }, file, "b")
      history.record(config, assert(url.parse("https://github.com/owner/repo/pull/7")), { title = "Valid" })
      eq(#history.list(config), 1)
      eq(history.list(config)[1].title, "Valid")
      assert(table.concat(vim.fn.readfile(file), "\n"):find('{"incomplete":', 1, true))
    end)
  end)

  test("History bounds reads of a large journal and keeps UTF-8 titles valid", function()
    fixture(function(config)
      vim.fn.mkdir(config.state_dir, "p")
      vim.fn.writefile({ string.rep("x", 1024 * 1024 + 50) }, config.state_dir .. "/history.jsonl", "b")
      history.record(config, assert(url.parse("https://github.com/owner/repo/pull/8")),
        { title = string.rep("é", 400) })
      eq(history.list(config)[1].title, string.rep("é", 300))
    end)
  end)

  test("Concurrent Neovim instances append without losing review history", function()
    fixture(function(config)
      vim.fn.mkdir(config.state_dir, "p")
      local writer = config.state_dir .. "/writer.lua"
      vim.fn.writefile({
        'vim.opt.runtimepath:prepend(arg[1])',
        'local history, url = require("review.history"), require("review.url")',
        'for i = 1, 50 do history.record({ state_dir = arg[2] },',
        '  assert(url.parse("https://github.com/owner/repo/pull/" .. (tonumber(arg[3]) + i))), {}) end',
      }, writer)
      local children = {}
      for _, first in ipairs({ 0, 50 }) do
        children[#children + 1] = vim.system({
          vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-l", writer,
          vim.fn.getcwd(), config.state_dir, tostring(first),
        }, { text = true })
      end
      for _, child in ipairs(children) do
        local result = child:wait(10000)
        eq(result.code, 0)
      end
      eq(#history.list(config), 100)
    end)
  end)

  test("An unreadable history does not prevent entering a new review URL", function()
    mocked({
      { history, "list", function() error("Unreadable history") end },
      { vim, "notify", function() end },
      { vim.ui, "input", function(_, callback) callback("https://github.com/owner/repo/pull/9") end },
    }, function()
      local previous = package.preload["telescope.pickers"]
      package.preload["telescope.pickers"] = function() error("Unavailable") end
      local opened
      -- The module may have been reloaded by the persistence test.
      mocked({ { require("review.history"), "list", history.list } }, function()
        require("review.input").url(function(value) opened = value end, {})
      end)
      package.preload["telescope.pickers"] = previous
      eq(opened, "https://github.com/owner/repo/pull/9")
    end)
  end)
end
