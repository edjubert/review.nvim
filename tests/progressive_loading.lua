return function(ctx)
  local test, eq, raises, run = ctx.test, ctx.eq, ctx.raises, ctx.run
  local async = require("review.async")
  local refs = { base_sha = "base", head_sha = "head", start_sha = "start" }
  local discussion = {
    id = "thread",
    notes = { {
      id = 1, body = "A late comment", author = { username = "alice" },
      position = {
        base_sha = refs.base_sha, head_sha = refs.head_sha,
        old_path = "code.lua", new_path = "code.lua", new_line = 2,
      },
    } },
  }
  local function wait(predicate)
    assert(vim.wait(1000, predicate, 1), "Progressive load timed out")
  end
  local function text(buf)
    return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  end
  local function fixture(held, fn)
    local pending, calls, errors, notifications = {}, {}, {}, {}
    local values = {
      info = { title = "Progressive review", description = "Available immediately", diff_refs = refs },
      references = nil,
      project = { ssh_url_to_repo = "git@gitlab.example:group/nested/repo.git" },
      commits = { { id = "head", parent_ids = { "base" }, title = "Change" } },
      diffs = { { old_path = "code.lua", new_path = "code.lua", diff = "@@ -1 +1 @@\n-a\n+b" } },
      discussions = { discussion },
      pipeline = { state = "success" },
      review = { state = "approved", approvals = 1 },
      current = { diff_refs = vim.deepcopy(refs) },
      repository = "/explicit/review/repo",
    }
    local function read(name)
      calls[name] = (calls[name] or 0) + 1
      if held[name] then coroutine.yield(function(done) pending[name] = done end) end
      if errors[name] then error(errors[name], 0) end
      return vim.deepcopy(values[name])
    end
    local s = ctx.Session.new(ctx.target, vim.tbl_deep_extend("force", ctx.config, {
      inline_comments = true, repo = "/explicit/review/repo",
    }))
    s.provider = {
      name = "Mock", prefix = "!", label = "merge request", kind = "MR",
      info = function() return read("info") end,
      references = function(_, mr) read("references"); return mr end,
      project = function() return read("project") end,
      commits = function() return read("commits") end,
      diffs = function() return read("diffs") end,
      discussions = function(_, loaded_refs, files)
        eq(loaded_refs, refs); eq(files, values.diffs)
        return read("discussions")
      end,
      pipeline_status = function() return read("pipeline") end,
      review_status = function() return read("review") end,
      current = function() return read("current") end,
      approve = function() calls.writes = (calls.writes or 0) + 1 end,
      post = function() error("Unexpected write") end,
    }
    local saved = {}
    for _, name in ipairs({ "prepare", "ensure", "files", "content" }) do saved[name] = ctx.git[name] end
    local notify = vim.notify
    vim.notify = function(message) notifications[#notifications + 1] = message end
    ctx.git.prepare = function(_, _, config)
      eq(config.repo, "/explicit/review/repo")
      return read("repository")
    end
    ctx.git.ensure = function(repo) eq(repo, "/explicit/review/repo") end
    ctx.git.files = function(repo)
      eq(repo, "/explicit/review/repo")
      return {
        { old_path = "code.lua", new_path = "code.lua", status = "M" },
        { old_path = "other.lua", new_path = "other.lua", status = "M" },
      }
    end
    ctx.git.content = function(repo, sha)
      eq(repo, "/explicit/review/repo")
      return sha == "base" and "first\nbefore\nlast\n" or "first\nafter\nlast\n"
    end
    local function release(name)
      assert(pending[name], "No pending " .. name .. " request")
      held[name] = nil
      local done = pending[name]
      pending[name] = nil
      done()
    end
    local ok, err = xpcall(function()
      fn(s, {
        pending = pending, calls = calls, errors = errors, values = values,
        notifications = notifications, release = release, held = held,
      })
    end, debug.traceback)
    s:close()
    for _, name in ipairs({ "prepare", "ensure", "files", "content" }) do ctx.git[name] = saved[name] end
    vim.notify = notify
    assert(ok, err)
  end

  test("async futures start together and retain multiple results and failures", function()
    local pending, results, failures = {}, {}, {}
    for _, name in ipairs({ "first", "second" }) do
      results[name] = async.future(function()
        coroutine.yield(function(done) pending[name] = done end)
        return name, nil, "last"
      end)
    end
    assert(pending.first and pending.second)
    pending.second()
    wait(function() return results.second.done end)
    eq(run(function() return async.await(results.second) end), "second")
    local a, b, c = async.await(results.second)
    eq(a, "second"); eq(b, nil); eq(c, "last")
    pending.first()
    wait(function() return results.first.done end)
    failures[1] = async.future(function() error("Read failed", 0) end)
    raises(function() async.await(failures[1]) end, "Read failed")
  end)

  test("metadata and commits appear while files, Git, comments and statuses are pending", function()
    fixture({
      info = true, references = true, project = true, commits = true,
      diffs = true, repository = true, discussions = true, pipeline = true, review = true,
    }, function(s, f)
      s:load()
      assert(f.pending.info and f.pending.project)
      assert(not text(s.panel_buf):find("No changed files", 1, true))
      f.release("info")
      wait(function() return s.data and f.pending.references and f.pending.diffs end)
      assert(text(s.panel_buf):find("Progressive review", 1, true))
      s:show_info()
      assert(text(vim.api.nvim_get_current_buf()):find("Available immediately", 1, true))
      vim.api.nvim_win_close(vim.api.nvim_get_current_win(), true)
      f.release("references")
      wait(function() return f.pending.commits and f.pending.pipeline and f.pending.review end)
      f.release("commits")
      wait(function() return #s.data.commits == 1 end)
      assert(text(s.panel_buf):find("Change", 1, true))
      eq(s.ready, nil)
      f.release("project")
      wait(function() return f.pending.repository end)
      f.release("repository")
      f.release("diffs")
      wait(function() return s.current and f.pending.discussions end)
      eq(s.refreshing, false); eq(s.ready, true)
      assert(text(s.panel_buf):find("Comments: loading…", 1, true))
      assert(text(s.panel_buf):find("Pipeline: loading…", 1, true))
      eq(f.calls.writes, nil)
      for _, name in ipairs({ "discussions", "pipeline", "review" }) do f.release(name) end
      wait(function() return not next(s.load_state.pending) end)
      eq(s.data.status.pipeline.state, "success")
      eq(s.data.status.review.state, "approved")
      eq(s.error, nil)
    end)
  end)

  test("late comments update the navigated diff and an already open discussion window", function()
    fixture({ discussions = true, pipeline = true, review = true }, function(s, f)
      s:load()
      assert(s.current)
      s:select_file(2)
      s:select_commit(0)
      eq(s.current.file.new_path, "code.lua")
      s:show_threads()
      local buf = vim.api.nvim_get_current_buf()
      eq(text(buf), "Loading discussions…")
      local cursor = vim.api.nvim_win_get_cursor(s.viewer_win)
      f.release("discussions")
      wait(function() return text(buf):find("A late comment", 1, true) ~= nil end)
      eq(vim.api.nvim_win_get_cursor(s.viewer_win), cursor)
      local namespace = vim.api.nvim_get_namespaces()["review.comments"]
      local marks = vim.api.nvim_buf_get_extmarks(s.viewer_buf, namespace, 0, -1, { details = true })
      assert(#marks > 0)
      f.release("pipeline"); f.release("review")
      wait(function() return not next(s.load_state.pending) end)
      eq(s.error, nil)
    end)
  end)

  test("the first diff preserves focus on a description opened during Git loading", function()
    fixture({ repository = true }, function(s, f)
      s:load()
      assert(s.data and not s.current and f.pending.repository)
      s:show_info()
      local win = vim.api.nvim_get_current_win()
      f.release("repository")
      wait(function() return s.current ~= nil end)
      eq(vim.api.nvim_get_current_win(), win)
      assert(text(vim.api.nvim_win_get_buf(win)):find("Available immediately", 1, true))
    end)
  end)

  test("optional read failures leave diffs navigable and refresh retries each section", function()
    fixture({ discussions = true, pipeline = true, review = true }, function(s, f)
      f.errors.discussions, f.errors.pipeline, f.errors.review = "Comments failed", "Pipeline failed", "Review failed"
      s:load()
      assert(s.current)
      s:show_threads()
      local buf = vim.api.nvim_get_current_buf()
      for _, name in ipairs({ "discussions", "pipeline", "review" }) do f.release(name) end
      wait(function() return not next(s.load_state.pending) end)
      assert(text(buf):find("Discussions unavailable", 1, true))
      eq(s.error, nil)
      eq(s.data.status.pipeline.state, "unknown")
      assert(text(s.panel_buf):find("Comments: unavailable", 1, true))
      s:select_file(2)
      eq(s.current.file.new_path, "other.lua")
      for name in pairs(f.errors) do f.errors[name] = nil end
      s:refresh()
      eq(s.current.file.new_path, "other.lua")
      eq(s.data.discussions, { discussion })
      eq(s.data.status.pipeline.state, "success")
      eq(s.error, nil)
    end)
  end)

  test("late statuses and comments preserve the focused file in the panel", function()
    fixture({ discussions = true, pipeline = true, review = true }, function(s, f)
      f.values.review.reviewers = {
        { username = "alice", state = "approved" }, { username = "bob", state = "pending" },
      }
      s:load()
      s:select_file(2)
      vim.api.nvim_set_current_win(s.panel_win)
      assert(ctx.ui.focus_panel_entry(s, { file = 2 }))
      for _, name in ipairs({ "discussions", "pipeline", "review" }) do f.release(name) end
      wait(function() return not next(s.load_state.pending) end)
      local entry = s.panel_entries[vim.api.nvim_win_get_cursor(s.panel_win)[1]]
      eq(entry.file, 2)
      eq(vim.api.nvim_get_current_win(), s.panel_win)
      eq(s.current.file.new_path, "other.lua")
    end)
  end)

  test("a failed initial file load retains metadata and can be retried", function()
    fixture({}, function(s, f)
      f.errors.diffs = "Files failed"
      s:load()
      eq(s.ready, nil); assert(s.error:find("Files failed", 1, true))
      eq(s.data.mr.title, "Progressive review")
      eq(s.refreshing, false)
      f.errors.diffs = nil
      s:refresh()
      eq(s.ready, true); assert(s.current); eq(s.error, nil)
    end)
  end)

  test("a changed revision and failed refresh preserve the previous review snapshot", function()
    fixture({}, function(s, f)
      s:load()
      local data, current, lines = s.data, s.current, text(s.viewer_buf)
      f.values.current.diff_refs.head_sha = "new-head"
      s:refresh()
      assert(s.error:find("changed while loading", 1, true))
      assert(s.data == data and s.current == current)
      eq(text(s.viewer_buf), lines)
      f.values.current.diff_refs.head_sha = "head"
      s:refresh()
      eq(s.error, nil); assert(s.current)
    end)
  end)

  test("late results from an older refresh cannot replace the latest comments or statuses", function()
    fixture({ discussions = true, pipeline = true }, function(s, f)
      s:load()
      assert(s.current)
      local old_comments, old_pipeline = f.pending.discussions, f.pending.pipeline
      f.held.discussions, f.held.pipeline = nil, nil
      f.values.discussions[1].notes[1].body = "New comments"
      f.values.pipeline.state = "failed"
      s:refresh()
      eq(s.data.discussions[1].notes[1].body, "New comments")
      eq(s.data.status.pipeline.state, "failed")
      f.values.discussions[1].notes[1].body = "Obsolete comments"
      f.values.pipeline.state = "success"
      old_comments(); old_pipeline()
      wait(function() return s.data.discussions[1].notes[1].body == "New comments" end)
      -- Schedule a barrier after both continuations to verify they were ignored.
      local settled = false
      vim.schedule(function() settled = true end)
      wait(function() return settled end)
      eq(s.data.discussions[1].notes[1].body, "New comments")
      eq(s.data.status.pipeline.state, "failed")
    end)
  end)

  test("closing a review ignores pending results and starts no dependent requests", function()
    fixture({ info = true, project = true }, function(s, f)
      s:load()
      s:close()
      f.release("info"); f.release("project")
      local settled = false
      vim.schedule(function() settled = true end)
      wait(function() return settled end)
      eq(s.data, nil); eq(f.calls.commits, nil); eq(f.calls.repository, nil)
      eq(#f.notifications, 0)
    end)
  end)

  test("explicit writes wait for outstanding reads before changing server state", function()
    fixture({ pipeline = true }, function(s, f)
      s:load()
      s:decision("approve")
      eq(f.calls.writes, nil)
      f.release("pipeline")
      wait(function() return not next(s.load_state.pending) end)
      -- The fake status reader avoids all live write and read transports.
      s.provider.status = function()
        return { pipeline = { state = "success" }, review = { state = "approved" } }
      end
      s:decision("approve")
      eq(f.calls.writes, 1)
    end)
  end)

  test("provider commit and file safeguards remain enforced after splitting reads", function()
    local github = require("review.providers.github")
    local codeberg = require("review.providers.codeberg")
    local pages, request = github.pages, github.request
    local cb_pages = codeberg.pages
    local ok, err = xpcall(function()
      github.pages = function() return {} end
      raises(function() github.commits(ctx.target, { commits = 1, changed_files = 1 }) end, "commit list changed")
      raises(function() github.diffs(ctx.target, { changed_files = 3001 }) end, "limited to 3000")
      raises(function() github.diffs(ctx.target, { changed_files = 1 }) end, "file list changed")
      github.request = function() return { merge_base_commit = { sha = "merge-base" } } end
      local pr = github.references(ctx.target, { base = { sha = "base" }, head = { sha = "head" } })
      eq(pr.diff_refs, { base_sha = "merge-base", start_sha = "base", head_sha = "head" })
      cb_pages = codeberg.pages
      codeberg.pages = function() return {} end
      raises(function() codeberg.diffs(ctx.target, { changed_files = 1 }) end, "file list changed")
    end, debug.traceback)
    github.pages, github.request, codeberg.pages = pages, request, cb_pages
    assert(ok, err)
  end)

  test("GitHub comparisons retain the exact paginated commit list beyond 250 commits", function()
    local github = require("review.providers.github")
    local request, pages = github.request, github.pages
    local requests = {}
    local function commits(first, last)
      local result = {}
      for i = first, last do
        result[#result + 1] = { sha = "commit-" .. i, parents = { { sha = "parent-" .. i } },
          commit = { message = "Commit " .. i .. "\nDetails" } }
      end
      return result
    end
    local comparison = { total_commits = 251, commits = commits(1, 100) }
    local ok, err = xpcall(function()
      github.pages = function() error("The capped commits endpoint must not be used") end
      github.request = function(_, endpoint)
        requests[#requests + 1] = endpoint
        assert(endpoint:find("/compare/base...head", 1, true))
        if endpoint:find("page=2", 1, true) then
          return { total_commits = 251, commits = commits(101, 200) }
        end
        assert(endpoint:find("page=3", 1, true))
        return { total_commits = 251, commits = commits(201, 251) }
      end
      local result = github.commits(ctx.target, {
        commits = 251, base = { sha = "base" }, head = { sha = "head" },
      }, comparison)
      eq(#requests, 2); eq(#result, 251)
      eq(result[1].id, "commit-1"); eq(result[251].title, "Commit 251")
    end, debug.traceback)
    github.request, github.pages = request, pages
    assert(ok, err)
  end)

  test("complete provider loads preserve normalized metadata, ordered commits and renamed files", function()
    for _, name in ipairs({ "gitlab", "github", "codeberg" }) do
      local provider = require("review.providers." .. name)
      local target = vim.tbl_extend("force", ctx.target, {
        provider = name, host = name == "codeberg" and "codeberg.org" or ctx.target.host,
      })
      local saved_request, saved_pages, saved_discussions = provider.request, provider.pages, provider.discussions
      local head, base, start = string.rep("a", 40), string.rep("b", 40), string.rep("c", 40)
      local ordered = {
        { sha = "commit-1", parents = { { sha = base } }, commit = { message = "First\nDetails" } },
        { sha = head, parents = { { sha = "commit-1" } }, commit = { message = "Second\nDetails" } },
      }
      if name == "codeberg" then
        ordered[1].sha, ordered[2].parents[1].sha = string.rep("d", 40), string.rep("d", 40)
      end
      local mr = {
        title = "Loaded review", body = "Description", commits = 2, changed_files = 1,
        base = { sha = start }, head = { sha = head }, merge_base = base,
        diff_refs = { base_sha = base, head_sha = head, start_sha = start },
      }
      local renamed = {
        old_path = "old.lua", new_path = "new.lua",
        filename = "new.lua", previous_filename = "old.lua", status = "renamed",
        renamed_file = true, diff = "@@ -1 +1 @@\n-before\n+after\n",
        patch = "@@ -1 +1 @@\n-before\n+after\n",
      }
      local ok, err = xpcall(function()
        provider.request = function(_, endpoint, body)
          eq(body, nil)
          if endpoint:find("/compare/", 1, true) then return { merge_base_commit = { sha = base } } end
          if endpoint:sub(-5) == ".diff" then
            return "diff --git a/old.lua b/new.lua\n--- a/old.lua\n+++ b/new.lua\n@@ -1 +1 @@\n-before\n+after\n"
          end
          if endpoint == (name == "gitlab" and provider.project_path(target) or provider.repo_path(target)) then
            return { http_url_to_repo = "https://example/repo.git", ssh_url_to_repo = "git@example:repo.git",
              clone_url = "https://example/repo.git", ssh_url = "git@example:repo.git" }
          end
          return vim.deepcopy(mr)
        end
        provider.pages = function(_, endpoint)
          if endpoint:find("/commits", 1, true) then
            if name == "gitlab" then
              return { { id = head, title = "Second", parent_ids = { "commit-1" } },
                { id = "commit-1", title = "First", parent_ids = { base } } }
            end
            return name == "codeberg" and { ordered[2], ordered[1] } or vim.deepcopy(ordered)
          end
          return { vim.deepcopy(renamed) }
        end
        provider.discussions = function(_, loaded_refs, files)
          eq(loaded_refs, mr.diff_refs)
          eq(files[1].old_path, "old.lua"); eq(files[1].new_path, "new.lua")
          return { discussion }
        end
        local data = run(function() return provider.load(target) end)
        eq(data.mr.diff_refs, mr.diff_refs)
        eq(data.commits[1].title, "First"); eq(data.commits[2].title, "Second")
        eq(data.project.ssh_url_to_repo, "git@example:repo.git")
        eq(data.discussions, { discussion })
        assert(data.diffs[1].diff:find("@@ -1 +1 @@", 1, true))
      end, debug.traceback)
      provider.request, provider.pages, provider.discussions = saved_request, saved_pages, saved_discussions
      assert(ok, name .. ": " .. tostring(err))
    end
  end)
end
