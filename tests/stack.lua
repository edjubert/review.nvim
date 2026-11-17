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

  test("the panel lists every review and marks the current one", function()
    local s = h.fixture()
    s.stack = { entries = chain, index = 1 }
    ui.panel(s)
    eq(vim.api.nvim_buf_get_lines(s.panel_buf, 1, 5, false), {
      "▶ !12 Review 12", "  !13 Review 13", "  !14 Review 14", "  !15 Review 15",
    })
    local highlighted = false
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(s.panel_buf,
        vim.api.nvim_create_namespace("review.panel"), 0, -1, { details = true })) do
      if mark[2] == 1 and mark[3] == 0 and mark[4].hl_group == "ReviewPanelTitle" then
        highlighted = true
      end
    end
    assert(highlighted, "the current review is not highlighted")
    s:close()
  end)

  test("stack entries show approvals, change requests and the pipeline", function()
    local s = h.fixture()
    local entries = {
      { iid = 12, title = "Ready", url = "u12",
        status = { pipeline = "success", approvals = 2, changes_requested = 0, approved = true } },
      { iid = 13, title = "Blocked", url = "u13",
        status = { pipeline = "failed", approvals = 0, changes_requested = 1, approved = false } },
      { iid = 14, title = "Waiting", url = "u14",
        status = { pipeline = "running", approvals = 0, changes_requested = 0, approved = false } },
      { iid = 15, title = "Unknown", url = "u15" },
    }
    s.stack = { entries = entries, index = 1 }
    ui.panel(s)
    eq(vim.api.nvim_buf_get_lines(s.panel_buf, 1, 5, false), {
      "▶ !12 👌 👌 ✅ Ready", "  !13 👎 ❌ Blocked", "  !14 🔄 Waiting", "  !15 Unknown",
    })
    local groups = {}
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(s.panel_buf,
        vim.api.nvim_create_namespace("review.panel"), 0, -1, { details = true })) do
      groups[mark[2]] = groups[mark[2]] or {}
      groups[mark[2]][mark[4].hl_group or mark[4].line_hl_group] = true
    end
    assert(groups[1].ReviewStackReady, "a ready review is not green")
    assert(groups[2].ReviewStackBlocked, "a blocked review is not red")
    assert(groups[3].ReviewStackPending, "a waiting review is not blue")
    assert(groups[4].ReviewHelp, "an unknown review has no neutral title")
    s:close()
  end)

  test("stack icons come from the configuration", function()
    local s = h.fixture({ stack_icons = {
      approved = "A", changes_requested = "C",
      pipeline_success = "S", pipeline_running = "R", pipeline_failed = "F",
    } })
    s.stack = { entries = {
      { iid = 12, title = "Ready", url = "u12",
        status = { pipeline = "success", approvals = 1, changes_requested = 0, approved = true } },
      { iid = 13, title = "Blocked", url = "u13",
        status = { pipeline = "failed", approvals = 0, changes_requested = 2, approved = false } },
    }, index = 1 }
    ui.panel(s)
    eq(vim.api.nvim_buf_get_lines(s.panel_buf, 1, 3, false), {
      "▶ !12 A S Ready", "  !13 C C F Blocked",
    })
    s:close()
  end)

  test("a long stack truncates titles and keeps the current review visible", function()
    local s = h.fixture()
    local entries = {}
    for iid = 1, 12 do
      entries[iid] = entry(iid, "b" .. iid, iid == 1 and "main" or ("b" .. (iid - 1)))
      entries[iid].title = "A long review title that does not fit the panel " .. iid
    end
    s.stack = { entries = entries, index = 9 }
    ui.panel(s)
    local lines = vim.api.nvim_buf_get_lines(s.panel_buf, 1, 13, false)
    eq(#lines, 12)
    assert(lines[9]:sub(1, #"▶ !9") == "▶ !9", lines[9])
    for _, line in ipairs(lines) do
      assert(vim.fn.strdisplaywidth(line) <= vim.api.nvim_win_get_width(s.panel_win) - 1, line)
      assert(line:find("…", 1, true), line)
    end
    s:close()
  end)

  test("opening a stack line loads that review", function()
    local s = h.fixture()
    s.stack = { entries = chain, index = 1 }
    ui.panel(s)
    vim.api.nvim_set_current_win(s.panel_win)
    vim.api.nvim_win_set_cursor(s.panel_win, { 3, 0 })
    local opened
    mocked({ { review, "open", function(value) opened = value end } }, function()
      ui.panel_action(s, "open")
    end)
    eq(opened, chain[2].url)
    s:close()
  end)

  test("GitLab reads stack statuses in one aliased query", function()
    local captured
    mocked({ { gitlab, "request", function(t, endpoint, body)
      eq(t, target); eq(endpoint, "graphql")
      captured = body.query
      return { data = { project = {
        m1 = { headPipeline = { status = "SUCCESS" },
          approvedBy = { nodes = { { username = "alice" }, { username = "bob" } } },
          approvalsRequired = 1, detailedMergeStatus = "MERGEABLE" },
        m2 = { headPipeline = { status = "FAILED" }, approvedBy = { nodes = {} },
          approvalsRequired = 1, detailedMergeStatus = "REQUESTED_CHANGES" },
      } } }
    end } }, function()
      local statuses = gitlab.stack_status(target, { { iid = 12 }, { iid = 13 } })
      assert(captured:find('m1: mergeRequest(iid: "12")', 1, true), captured)
      assert(captured:find('m2: mergeRequest(iid: "13")', 1, true), captured)
      eq(statuses[12].pipeline, "success")
      eq(statuses[12].approvals, 2)
      eq(statuses[12].approved, true)
      eq(statuses[12].changes_requested, 0)
      eq(statuses[13].pipeline, "failed")
      eq(statuses[13].approved, false)
      eq(statuses[13].changes_requested, 1)
    end)
  end)

  test("GitHub reads stack statuses in one aliased query", function()
    local gh_target = assert(url.parse("https://github.example/owner/repo/pull/13"))
    local captured
    mocked({ { github, "request", function(t, endpoint, body)
      eq(t, gh_target); eq(endpoint, "graphql")
      captured = body.query
      return { data = { repository = {
        p1 = { reviewDecision = "APPROVED", statusCheckRollup = { state = "SUCCESS" },
          reviews = { nodes = { { state = "APPROVED", author = { login = "alice" } } } } },
        p2 = { reviewDecision = "CHANGES_REQUESTED", statusCheckRollup = { state = "FAILURE" },
          reviews = { nodes = { { state = "CHANGES_REQUESTED", author = { login = "bob" } } } } },
        p3 = { reviewDecision = vim.NIL, statusCheckRollup = vim.NIL, reviews = { nodes = {} } },
      } } }
    end } }, function()
      local statuses = github.stack_status(gh_target, { { iid = 11 }, { iid = 12 }, { iid = 13 } })
      assert(captured:find("p1: pullRequest(number: 11)", 1, true), captured)
      eq(statuses[11].pipeline, "success")
      eq(statuses[11].approvals, 1)
      eq(statuses[11].approved, true)
      eq(statuses[12].pipeline, "failed")
      eq(statuses[12].changes_requested, 1)
      eq(statuses[12].approved, false)
      eq(statuses[13].pipeline, "none")
      eq(statuses[13].approved, true)
    end)
  end)

  test("Codeberg reads each stack entry in turn", function()
    local cb_target = assert(url.parse("https://codeberg.org/owner/repo/pulls/13"))
    mocked({
      { codeberg, "request", function(t, endpoint)
        eq(t, cb_target)
        if endpoint:find("/pulls/12$") then return { head = { sha = "abc" } } end
        if endpoint:find("/commits/abc/status$") then return { total_count = 1, state = "success" } end
        error("Unexpected endpoint: " .. endpoint)
      end },
      { codeberg, "pages", function(t, endpoint)
        eq(t, cb_target)
        eq(endpoint, codeberg.repo_path(cb_target) .. "/pulls/12/reviews")
        return { { state = "APPROVED", user = { login = "alice" } } }
      end },
    }, function()
      local statuses = codeberg.stack_status(cb_target, { { iid = 12 } })
      eq(statuses[12].pipeline, "success")
      eq(statuses[12].approvals, 1)
      eq(statuses[12].approved, true)
    end)
  end)

  test("hovering a truncated stack line shows the full title", function()
    local s = h.fixture()
    local long = "A very long review title that the panel cannot display"
    s.stack = { entries = {
      { iid = 12, title = long, url = "u12" },
      { iid = 13, title = "Short", url = "u13" },
    }, index = 1 }
    ui.panel(s)
    vim.api.nvim_set_current_win(s.panel_win)
    vim.api.nvim_win_set_cursor(s.panel_win, { 2, 0 })
    ui.hover(s)
    assert(s.hover_win and vim.api.nvim_win_is_valid(s.hover_win), "no hover window")
    eq(vim.api.nvim_buf_get_lines(s.hover_buf, 0, -1, false), { long })
    vim.api.nvim_win_set_cursor(s.panel_win, { 3, 0 })
    ui.hover(s)
    eq(s.hover_win, nil)
    s:close()
  end)

  test("hovering a truncated commit line shows the full title", function()
    local s = h.fixture()
    local long = "A very long commit title that the panel cannot display"
    s.data.commits = { { id = "abcdef1234567890", parent_ids = { "base" }, title = long } }
    ui.panel(s)
    vim.api.nvim_set_current_win(s.panel_win)
    local row
    for index, item in pairs(s.panel_entries) do
      if item.commit == 1 then row = index end
    end
    assert(row, "no commit row")
    vim.api.nvim_win_set_cursor(s.panel_win, { row, 0 })
    ui.hover(s)
    assert(s.hover_win and vim.api.nvim_win_is_valid(s.hover_win), "no hover window")
    eq(vim.api.nvim_buf_get_lines(s.hover_buf, 0, -1, false), { long })
    s:close()
  end)

  test("the hover follows the panel cursor after a short delay", function()
    local s = h.fixture()
    local long = "A very long review title that the panel cannot display"
    s.stack = { entries = { { iid = 12, title = long, url = "u12" } }, index = 1 }
    ui.panel(s)
    vim.api.nvim_set_current_win(s.panel_win)
    vim.api.nvim_win_set_cursor(s.panel_win, { 2, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = s.panel_buf })
    assert(vim.wait(1000, function() return s.hover_win ~= nil end, 10), "no hover window")
    eq(vim.api.nvim_buf_get_lines(s.hover_buf, 0, -1, false), { long })
    s:close()
    eq(s.hover_win, nil)
  end)

  test("opening a stack review in the browser uses its URL", function()
    local s = h.fixture()
    s.stack = { entries = chain, index = 1 }
    ui.panel(s)
    vim.api.nvim_set_current_win(s.panel_win)
    vim.api.nvim_win_set_cursor(s.panel_win, { 3, 0 })
    local opened = {}
    mocked({ { vim.ui, "open", function(value) opened[#opened + 1] = value; return true end } }, function()
      s:open_stack_browser()
    end)
    eq(opened, { chain[2].url })
    s:close()
  end)

  test("opening a stack review in the browser requires a stack line", function()
    local s = h.fixture()
    s.stack = { entries = chain, index = 1 }
    ui.panel(s)
    vim.api.nvim_set_current_win(s.panel_win)
    vim.api.nvim_win_set_cursor(s.panel_win, { 1, 0 })
    local messages = {}
    mocked({
      { vim, "notify", function(message) messages[#messages + 1] = message end },
      { vim.ui, "open", function() error("must not open a browser") end },
    }, function() s:open_stack_browser() end)
    eq(messages, { "Use this command on a review in the stack." })
    s:close()
  end)

  test("the hover shows the browser shortcut for a stack review", function()
    local s = h.fixture({ keymaps = { stack_open = "<C-b>" } })
    local long = "A very long review title that the panel cannot display"
    s.stack = { entries = { { iid = 12, title = long, url = "u12" } }, index = 1 }
    ui.panel(s)
    vim.api.nvim_set_current_win(s.panel_win)
    vim.api.nvim_win_set_cursor(s.panel_win, { 2, 0 })
    ui.hover(s)
    eq(vim.api.nvim_buf_get_lines(s.hover_buf, 0, -1, false), { long, "<C-b>: open in browser" })
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
