return function(h)
  local test, eq, mocked = h.test, h.eq, h.mocked
  local stack = require("review.stack")
  local gitlab = require("review.providers.gitlab")
  local github = require("review.providers.github")
  local codeberg = require("review.providers.codeberg")
  local url = require("review.url")
  local ui, review = h.ui, require("review")
  local target = assert(url.parse("https://gitlab.example/group/nested/repo/-/merge_requests/13"))
  local function entry(iid, source, base)
    return {
      iid = iid, title = "Review " .. iid, state = "opened", draft = false,
      source_branch = source, target_branch = base,
      url = ("https://gitlab.example/group/nested/repo/-/merge_requests/%d"):format(iid),
    }
  end
  local chain = { entry(12, "a", "main"), entry(13, "b", "a"), entry(14, "c", "b"), entry(15, "d", "main") }

  test("a stack chains reviews through their target branches", function()
    local result = stack.build(chain[2], chain)
    eq(result.index, 2)
    eq({ result.entries[1].iid, result.entries[2].iid, result.entries[3].iid }, { 12, 13, 14 })
    eq(stack.build(chain[4], chain), nil)
    eq(stack.build(entry(99, "z", "main"), chain), nil)
  end)

  test("the current review joins a stack even when the list omits it", function()
    local result = stack.build(entry(13, "b", "a"), { entry(12, "a", "main") })
    eq(result.index, 2)
    eq({ result.entries[1].iid, result.entries[2].iid }, { 12, 13 })
  end)

  test("ambiguous branches stop the chain instead of guessing", function()
    local parallel = { entry(12, "a", "main"), entry(13, "b", "a"), entry(14, "c", "a") }
    eq(stack.build(parallel[1], parallel), nil)
    local result = stack.build(parallel[2], parallel)
    eq(result.index, 2)
    eq({ result.entries[1].iid, result.entries[2].iid }, { 12, 13 })
  end)

  test("a branch cycle cannot loop", function()
    local cyclic = { entry(12, "a", "b"), entry(13, "b", "a") }
    local result = stack.build(cyclic[1], cyclic)
    eq(result.index, 2)
    eq({ result.entries[1].iid, result.entries[2].iid }, { 13, 12 })
  end)

  test("GitLab lists open merge requests and normalizes their branches", function()
    local calls = {}
    mocked({ { gitlab, "pages", function(t, endpoint, query)
      eq(t, target)
      calls[#calls + 1] = { endpoint, query }
      return {
        { iid = 12, title = "Base", state = "opened", draft = true, source_branch = "a",
          target_branch = "main", web_url = chain[1].url },
        { iid = 13, title = "Top", state = "opened", source_branch = "b",
          target_branch = "a", web_url = chain[2].url },
      }
    end } }, function()
      local reviews = gitlab.open_reviews(target)
      eq(calls, { { gitlab.project_path(target) .. "/merge_requests", "state=opened" } })
      eq(reviews[1].draft, true)
      eq(reviews[1].url, chain[1].url)
      eq(reviews[2].draft, false)
      local result = gitlab.stack(target, { iid = 13, title = "Top", source_branch = "b",
        target_branch = "a", web_url = chain[2].url })
      eq(result.index, 2)
      eq({ result.entries[1].iid, result.entries[2].iid }, { 12, 13 })
    end)
  end)

  test("GitHub and Codeberg normalize pull request branches", function()
    local gh_target = assert(url.parse("https://github.example/owner/repo/pull/13"))
    local cb_target = assert(url.parse("https://codeberg.org/owner/repo/pulls/13"))
    local function pull(number, head, base)
      return { number = number, title = "PR " .. number, state = "open", draft = number == 13,
        head = { ref = head }, base = { ref = base },
        html_url = ("https://example/owner/repo/pull/%d"):format(number) }
    end
    mocked({
      { github, "pages", function(t, endpoint)
        eq(t, gh_target); eq(endpoint, github.repo_path(gh_target) .. "/pulls")
        return { pull(12, "a", "main"), pull(13, "b", "a") }
      end },
      { codeberg, "pages", function(t, endpoint)
        eq(t, cb_target); eq(endpoint, codeberg.repo_path(cb_target) .. "/pulls?state=open")
        return { pull(12, "a", "main"), pull(13, "b", "a") }
      end },
    }, function()
      for _, provider in ipairs({ github, codeberg }) do
        local t = provider == github and gh_target or cb_target
        local result = provider.stack(t, pull(13, "b", "a"))
        eq(result.index, 2)
        eq({ result.entries[1].iid, result.entries[2].iid }, { 12, 13 })
        eq(result.entries[2].draft, true)
      end
    end)
  end)

  test("the panel shows the stack position and the current review", function()
    local s = h.fixture()
    s.stack = { entries = chain, index = 1 }
    ui.panel(s)
    local text = table.concat(vim.api.nvim_buf_get_lines(s.panel_buf, 0, -1, false), "\n")
    assert(text:find("Stack 1/4 · !12 !13 !14 !15", 1, true), text)
    local line = vim.api.nvim_buf_get_lines(s.panel_buf, 1, 2, false)[1]
    local start = assert(line:find("!12", 1, true)) - 1
    local highlighted = false
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(s.panel_buf,
        vim.api.nvim_create_namespace("review.panel"), 0, -1, { details = true })) do
      if mark[2] == 1 and mark[3] == start and mark[4].end_col == start + 3
          and mark[4].hl_group == "ReviewPanelTitle" then highlighted = true end
    end
    assert(highlighted, "the current review is not highlighted")
    s:close()
  end)

  test("a long stack keeps the current review visible", function()
    local s = h.fixture()
    local entries = {}
    for iid = 1, 12 do entries[iid] = entry(iid, "b" .. iid, iid == 1 and "main" or ("b" .. (iid - 1))) end
    s.stack = { entries = entries, index = 9 }
    ui.panel(s)
    local text = table.concat(vim.api.nvim_buf_get_lines(s.panel_buf, 0, -1, false), "\n")
    local line = text:match("Stack 9/12[^\n]*")
    assert(line, text)
    assert(line:find("!9", 1, true), line)
    assert(line:find("…", 1, true), line)
    assert(#line <= vim.api.nvim_win_get_width(s.panel_win) - 1, line)
    s:close()
  end)

  test("stack navigation opens the neighbouring review URL", function()
    local s = h.fixture()
    s.stack = { entries = chain, index = 2 }
    local opened = {}
    mocked({ { review, "open", function(value) opened[#opened + 1] = value end } }, function()
      s:move_stack(1)
      s:move_stack(-1)
    end)
    eq(opened, { chain[3].url, chain[1].url })
    s:close()
  end)

  test("stack navigation reports the ends of the stack", function()
    local s = h.fixture()
    s.stack = { entries = chain, index = 1 }
    local messages = {}
    mocked({
      { vim, "notify", function(message) messages[#messages + 1] = message end },
      { review, "open", function() error("must not open another review") end },
    }, function()
      s:move_stack(-1)
      s.stack.index = #chain
      s:move_stack(1)
    end)
    eq(messages, { "This is the first review in the stack.", "This is the last review in the stack." })
    s:close()
  end)

  test("a review without a stack reports it instead of navigating", function()
    local s = h.fixture()
    local messages = {}
    mocked({ { vim, "notify", function(message) messages[#messages + 1] = message end } }, function()
      s:move_stack(1)
      s:show_stack()
      s.stack_error = "GitLab refused the request"
      s:move_stack(-1)
    end)
    eq(messages, {
      "This review is not part of a stack.",
      "This review is not part of a stack.",
      "The review stack is unavailable: GitLab refused the request",
    })
    s:close()
  end)

  test("the stack picker opens the selected review only", function()
    local s = h.fixture()
    s.stack = { entries = chain, index = 2 }
    local opened, formatted = {}, nil
    mocked({
      { vim.ui, "select", function(items, opts, callback)
        eq(items, chain)
        assert(opts.prompt:find("2/4", 1, true), opts.prompt)
        formatted = opts.format_item(chain[4])
        callback(chain[1])
        callback(chain[4])
      end },
      { review, "open", function(value) opened[#opened + 1] = value end },
    }, function() s:show_stack() end)
    assert(formatted:find("!15", 1, true), formatted)
    eq(opened, { chain[4].url })
    s:close()
  end)
end
