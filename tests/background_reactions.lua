return function(ctx)
  local test, eq, wait, text = ctx.test, ctx.eq, ctx.wait, ctx.text
  local reactions = require("review.reactions")
  local function mocked(overrides, fn)
    local saved = {}
    for _, item in ipairs(overrides) do
      saved[#saved + 1] = { item[1], item[2], item[1][item[2]] }
      item[1][item[2]] = item[3]
    end
    local ok, err = xpcall(fn, debug.traceback)
    for _, item in ipairs(saved) do item[1][item[2]] = item[3] end
    assert(ok, err)
  end
  local function comments(f, count)
    local discussion = vim.deepcopy(ctx.discussion)
    for index = 2, count do
      discussion.notes[index] = {
        id = index, body = "Reply " .. index, author = { username = "user" .. index },
      }
    end
    f.values.discussions = { discussion }
  end
  local function transport(s)
    local state = { requests = {}, running = 0, maximum = 0, errors = {} }
    s.provider.note_reactions = function(_, note)
      local request = { note = note, body = note.body }
      state.requests[#state.requests + 1] = request
      state.running = state.running + 1
      state.maximum = math.max(state.maximum, state.running)
      coroutine.yield(function(done) request.done = done end)
      state.running = state.running - 1
      if request.error or state.errors[note.id] then error(request.error or state.errors[note.id], 0) end
      return request.result or { { name = "heart", count = 1, users = { "alice" } } }
    end
    function state.complete(request, result, err)
      assert(request.done and not request.released)
      request.result, request.error, request.released = result, err, true
      request.done()
    end
    function state.finish()
      while s.reaction_load do
        local before = #state.requests
        for _, request in ipairs(state.requests) do
          if not request.released then state.complete(request) end
        end
        wait(function() return not s.reaction_load or #state.requests > before end)
      end
    end
    return state
  end

  test("GitLab and Codeberg return comment bodies without requesting reactions", function()
    local gitlab, codeberg = require("review.providers.gitlab"), require("review.providers.codeberg")
    local cb_target = vim.tbl_extend("force", ctx.target, { host = "codeberg.org", provider = "codeberg" })
    local gl_reads, cb_reads = 0, 0
    mocked({
      { gitlab, "note_reactions", function() error("Reactions must be deferred") end },
      { gitlab, "pages", function(_, endpoint)
        eq(endpoint, gitlab.mr_path(ctx.target) .. "/discussions")
        gl_reads = gl_reads + 1
        return { { id = "thread", notes = { { id = 1, body = "Root" }, { id = 2, body = "Reply" } } } }
      end },
      { codeberg, "note_reactions", function() error("Reactions must be deferred") end },
      { codeberg, "pages", function(_, endpoint)
        eq(endpoint, codeberg.pr_path(cb_target) .. "/reviews")
        cb_reads = cb_reads + 1
        return { { id = 3, state = "COMMENT", comments_count = 1 } }
      end },
      { codeberg, "request", function(_, endpoint, body)
        eq(body, nil)
        eq(endpoint, codeberg.pr_path(cb_target) .. "/reviews/3/comments")
        cb_reads = cb_reads + 1
        return { { id = 4, body = "Comment", path = "new.lua", position = 2, commit_id = "head" } }
      end },
    }, function()
      local gl = gitlab.discussions(ctx.target)
      eq(gl[1].notes[2].body, "Reply"); eq(gl[1].notes[1].reactions, nil); eq(gl_reads, 1)
      local cb = codeberg.discussions(cb_target, ctx.refs, { { old_path = "old.lua", new_path = "new.lua" } })
      eq(cb[1].notes[1].body, "Comment"); eq(cb[1].notes[1].reactions, nil); eq(cb_reads, 2)
      eq(cb[1].notes[1].position.old_path, "old.lua")
      eq(cb[1].notes[1].position.head_sha, "head")
    end)
  end)

  test("reaction loaders skip system notes and invalid IDs and preserve failures independently", function()
    local gitlab, codeberg = require("review.providers.gitlab"), require("review.providers.codeberg")
    for _, provider in ipairs({ gitlab, codeberg }) do
      local endpoints, target = {}, vim.tbl_extend("force", ctx.target, { host = "codeberg.org" })
      local discussions = { { notes = {
        { id = 1, body = "Root" }, { id = 2, body = "Reply" },
        { id = 3, system = true }, { id = vim.NIL }, { id = -1 }, { id = 1.5 },
      } } }
      mocked({ { provider, "pages", function(_, endpoint)
        endpoints[#endpoints + 1] = endpoint
        if endpoint:find("/2/", 1, true) then error("Missing permission") end
        return { { name = "heart", content = "heart", user = { username = "alice", login = "alice" } } }
      end } }, function()
        local read = provider == gitlab and ctx.note_reactions or provider.note_reactions
        local failures = ctx.run(function()
          return reactions.load({ note_reactions = read }, target, discussions)
        end)
        eq(#endpoints, 2); eq(failures, 1)
        local notes = discussions[1].notes
        eq(notes[1].reactions[1].users, { "alice" })
        eq(notes[2].body, "Reply"); assert(notes[2].reactions_error:find("Missing permission", 1, true))
        eq(notes[3].reactions_loading, nil); eq(notes[4].reactions_loading, nil)
        eq(reactions.text(notes[2]), "Reactions unavailable")
      end)
    end
  end)

  test("comments render before reactions and at most four requests run simultaneously", function()
    ctx.fixture({}, function(s, f)
      comments(f, 9)
      local network = transport(s)
      s:load()
      eq(#network.requests, 4); eq(network.running, 4)
      eq(s.ready, true); assert(s.current)
      eq(s.load_state.pending.discussions, nil); eq(s.load_state.pending.reactions, true)
      eq(s:reads_pending(), false)
      s:show_threads()
      local buf = vim.api.nvim_get_current_buf()
      assert(text(buf):find("A late comment", 1, true)); assert(text(buf):find("Reply 9", 1, true))
      assert(text(buf):find("Reactions loading…", 1, true))
      assert(not text(s.panel_buf):find("Comments: loading", 1, true))
      local position, body = vim.deepcopy(s.data.discussions[1].notes[1].position), s.data.discussions[1].notes[1].body
      network.complete(network.requests[1])
      wait(function() return #network.requests == 5 end)
      eq(network.running, 4)
      network.finish()
      eq(network.maximum, 4); eq(#network.requests, 9)
      eq(s.data.discussions[1].notes[1].position, position)
      eq(s.data.discussions[1].notes[1].body, body)
      assert(text(buf):find("Reactions: ❤️ 1 (@alice)", 1, true))
      eq(s.load_state.pending.reactions, nil); eq(s.error, nil)
      eq(s.reaction_limiter.running, 0)
    end)
  end)

  test("late reactions preserve diff lines, document cursor, comment selection and window focus", function()
    ctx.fixture({}, function(s, f)
      comments(f, 6)
      local network = transport(s)
      s:load()
      local original = vim.api.nvim_buf_get_lines(s.viewer_buf, 0, -1, false)
      s:show_threads()
      local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
      local row
      for index, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
        if line == "Reply 6" then row = index; break end
      end
      vim.api.nvim_win_set_cursor(win, { row, 3 })
      local note = s.thread_documents[buf][row]
      local mappings, map_threads = 0, s.map_threads
      s.map_threads = function(...)
        mappings = mappings + 1
        return map_threads(...)
      end
      network.finish()
      local cursor = vim.api.nvim_win_get_cursor(win)
      eq(vim.api.nvim_buf_get_lines(buf, cursor[1] - 1, cursor[1], false), { "Reply 6" })
      eq(cursor[2], 3); eq(s.thread_documents[buf][cursor[1]], note)
      eq(s.thread_views[buf].entries[cursor[1]], s.data.discussions[1])
      eq(vim.api.nvim_get_current_win(), win)
      eq(vim.api.nvim_buf_get_lines(s.viewer_buf, 0, -1, false), original)
      eq(mappings, 0)
    end)
  end)

  test("failed reactions keep comments readable and do not prevent other reactions or a retry", function()
    ctx.fixture({}, function(s, f)
      comments(f, 5)
      local network = transport(s)
      network.errors[2] = "Reaction API unavailable"
      s:load()
      s:show_threads()
      local buf = vim.api.nvim_get_current_buf()
      network.finish()
      local notes = s.data.discussions[1].notes
      eq(notes[2].body, "Reply 2"); assert(notes[2].reactions_error)
      eq(notes[5].reactions[1].count, 1)
      eq(s.error, nil); eq(s:reads_pending(), false)
      assert(text(buf):find("Reactions unavailable", 1, true))
      assert(text(s.panel_buf):find("Reactions: unavailable", 1, true))
      network.errors[2] = nil
      s:refresh()
      network.finish()
      eq(s.data.discussions[1].notes[2].reactions_error, nil)
      eq(s.load_state.errors.reactions, nil); eq(s.error, nil)
    end)
  end)

  test("refresh ignores obsolete reaction results and shares the four-request limit", function()
    ctx.fixture({}, function(s, f)
      comments(f, 7)
      local network = transport(s)
      s:load()
      local old_notes = s.data.discussions[1].notes
      f.values.discussions[1].notes[1].body = "Fresh root"
      s:refresh()
      eq(#network.requests, 4); eq(network.running, 4)
      eq(s.data.discussions[1].notes[1].body, "Fresh root")
      network.complete(network.requests[1], { { name = "thumbsup", count = 99, users = {} } })
      wait(function() return #network.requests == 5 end)
      eq(network.running, 4)
      eq(network.requests[5].body, "Fresh root")
      for index = 2, 4 do
        network.complete(network.requests[index], { { name = "thumbsup", count = 99, users = {} } })
      end
      wait(function() return #network.requests == 8 end)
      network.finish()
      eq(network.maximum, 4); eq(#network.requests, 11)
      eq(s.data.discussions[1].notes[1].reactions[1].count, 1)
      for _, note in ipairs(old_notes) do
        eq(note.reactions, nil); eq(note.reactions_loading, nil)
      end
      eq(s.error, nil)
    end)
  end)

  test("closing a review stops queued reaction reads and ignores in-flight results", function()
    ctx.fixture({}, function(s, f)
      comments(f, 8)
      local network = transport(s)
      s:load()
      local notes = s.data.discussions[1].notes
      s:close()
      for _, request in ipairs(network.requests) do network.complete(request) end
      wait(function() return network.running == 0 end)
      eq(#network.requests, 4)
      for _, note in ipairs(notes) do eq(note.reactions, nil); eq(note.reactions_loading, nil) end
      eq(s.reaction_limiter.running, 0)
    end)
  end)

  test("a failed refresh keeps the previous comments and restarts their canceled reactions", function()
    ctx.fixture({}, function(s, f)
      comments(f, 6)
      local network = transport(s)
      s:load()
      s:show_threads()
      local buf, data, current = vim.api.nvim_get_current_buf(), s.data, s.current
      f.errors.info = "Metadata unavailable"
      s:refresh()
      assert(s.error:find("Metadata unavailable", 1, true))
      eq(s.data, data); eq(s.current, current)
      eq(#network.requests, 4)
      network.finish()
      eq(network.maximum, 4); eq(#network.requests, 10)
      assert(text(buf):find("Reply 6", 1, true))
      assert(text(buf):find("Reactions: ❤️ 1", 1, true))
      assert(not text(buf):find("Reactions loading", 1, true))
      eq(s.data.discussions[1].notes[1].reactions[1].count, 1)
      eq(s.load_state.pending.reactions, nil)
    end)
  end)

  test("resolution need not wait for reactions and obsolete reads cannot undo its result", function()
    ctx.fixture({}, function(s, f)
      comments(f, 5)
      for _, note in ipairs(f.values.discussions[1].notes) do note.resolvable = true; note.resolved = false end
      local network, writes = transport(s), 0
      s.provider.can_resolve = function(discussion) return not discussion.notes[1].resolved end
      s.provider.resolve = function(_, discussion)
        writes = writes + 1
        local result = vim.deepcopy(discussion)
        for _, note in ipairs(result.notes) do note.resolved = true end
        f.values.discussions = { result }
        return result, true
      end
      s:load()
      s:show_threads()
      local buf, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
      for index, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
        if line == "A late comment" then vim.api.nvim_win_set_cursor(win, { index, 0 }); break end
      end
      assert(s:resolution_available())
      s:resolve()
      eq(writes, 1); eq(s.resolving, false)
      eq(s.data.discussions[1].notes[1].resolved, true)
      assert(text(buf):find("Resolved discussion", 1, true))
      for index = 1, 4 do
        network.complete(network.requests[index], { { name = "thumbsup", count = 99, users = {} } })
      end
      wait(function() return #network.requests == 8 end)
      network.finish()
      eq(s.data.discussions[1].notes[1].resolved, true)
      eq(s.data.discussions[1].notes[1].reactions[1].count, 1)
      eq(network.maximum, 4); eq(writes, 1); eq(s.error, nil)
    end)
  end)

  test("resolve all announces loading immediately and reads only revision and discussions before confirmation", function()
    ctx.fixture({}, function(s, f)
      s:load()
      local expected = vim.deepcopy(f.calls)
      expected.current = (expected.current or 0) + 1
      expected.discussions = expected.discussions + 1
      f.held.current, f.held.discussions = true, true
      local root = f.values.discussions[1].notes[1]
      root.resolvable, root.resolved = true, false
      local resolved, unresolvable = vim.deepcopy(f.values.discussions[1]), vim.deepcopy(f.values.discussions[1])
      resolved.id, resolved.notes[1].resolved = "resolved", true
      unresolvable.id, unresolvable.notes[1].resolvable = "unresolvable", false
      f.values.discussions[2], f.values.discussions[3] = resolved, unresolvable
      s.provider.can_resolve = require("review.providers.gitlab").can_resolve
      s.provider.note_reactions = function() error("Resolve all must not fetch reactions") end
      s.provider.resolve = function() error("Resolution needs confirmation") end
      local selections, answer, choice = 0
      mocked({ { vim.ui, "select", function(items, opts, callback)
        selections = selections + 1
        eq(items[1], "Cancel")
        assert(items[2]:find("all 1 conversation(s)", 1, true))
        assert(opts.prompt:find("WARNING", 1, true))
        choice, answer = items[2], callback
      end } }, function()
        s:resolve_all()
        eq(f.notifications[#f.notifications], "Fetching open conversations…")
        eq(s.resolving, true); assert(f.pending.current)
        eq(selections, 0); eq(f.pending.discussions, nil)
        f.release("current")
        wait(function() return f.pending.discussions ~= nil end)
        eq(selections, 0); eq(s.resolving, true)
        f.release("discussions")
        wait(function() return answer ~= nil end)
        eq(f.calls, expected); eq(selections, 1); eq(s.resolving, true)
        assert(choice)
        answer("Cancel")
        eq(s.resolving, false); eq(s.reaction_load, nil)
        eq(f.calls, expected); eq(s.error, nil)
        assert(not table.concat(f.notifications, "\n"):find("ReviewResolveAll complete:", 1, true))
      end)
    end)
  end)

  test("resolve all confirms complete success before reactions finish and never reports partial success as complete", function()
    for _, failure in ipairs({ false, true }) do
      ctx.fixture({}, function(s, f)
        local first = f.values.discussions[1]
        first.notes[1].resolvable, first.notes[1].resolved = true, false
        local second = vim.deepcopy(first)
        second.id, second.notes[1].id = "second", 2
        f.values.discussions[2] = second
        s:load()
        local network, requests = transport(s), {}
        s.provider.can_resolve = require("review.providers.gitlab").can_resolve
        ctx.ui.panel(s)
        assert(text(s.panel_buf):find("Open conversations: 2", 1, true))
        s.provider.resolve = function(_, discussion)
          local index = #requests + 1
          local request = { discussion = discussion }
          requests[index] = request
          coroutine.yield(function(done) request.done = done end)
          if failure and index == 2 then error("Resolution failed", 0) end
          local result = vim.deepcopy(discussion)
          result.notes[1].resolved = true
          f.values.discussions[index] = result
          -- A conversation already resolved by someone else still completes
          -- the selection, without counting it as a new write.
          return result, index == 1
        end
        local answer, choice
        local function completed()
          return table.concat(f.notifications, "\n"):find("ReviewResolveAll complete:", 1, true) ~= nil
        end
        mocked({ { vim.ui, "select", function(items, _, callback)
          answer, choice = callback, items[2]
        end } }, function()
          s:resolve_all()
          assert(answer); eq(completed(), false)
          answer(choice)
          eq(#requests, 1); eq(s.resolving, true); eq(completed(), false)
          requests[1].done()
          wait(function() return requests[2] ~= nil end)
          eq(s.data.discussions[1].notes[1].resolved, true)
          assert(text(s.panel_buf):find("Open conversations: 1", 1, true))
          eq(s.resolving, true); eq(completed(), false)
          requests[2].done()
          wait(function() return not s.resolving end)
          assert(text(s.panel_buf):find("Open conversations: " .. (failure and 1 or 0), 1, true))
          eq(completed(), not failure)
          eq(s.data.discussions[2].notes[1].resolved, not failure)
          if failure then
            assert(s.error:find("Resolution failed", 1, true))
          else
            eq(f.notifications[#f.notifications],
              "ReviewResolveAll complete: 2 selected conversation(s) resolved on MR !12.")
            eq(s.error, nil)
          end
          eq(#network.requests, 2); assert(s.reaction_load)
          network.finish()
          eq(completed(), not failure)
        end)
      end)
    end
  end)

  test("resolve all read failures report the error and allow a later empty read without reactions", function()
    for _, failing in ipairs({ "current", "discussions" }) do
      ctx.fixture({}, function(s, f)
        s:load()
        s.provider.can_resolve = function() return false end
        s.provider.note_reactions = function() error("Resolve all must not fetch reactions") end
        s.provider.resolve = function() error("Unexpected resolution") end
        f.held[failing], f.errors[failing] = true, "Failed " .. failing .. " read"
        mocked({ { vim.ui, "select", function() error("No confirmation for a failed or empty read") end } }, function()
          s:resolve_all()
          eq(f.notifications[#f.notifications], "Fetching open conversations…")
          eq(s.resolving, true)
          assert(f.pending[failing])
          f.release(failing)
          wait(function() return not s.resolving end)
          assert(s.error:find(f.errors[failing], 1, true))
          assert(f.notifications[#f.notifications]:find(f.errors[failing], 1, true))
          eq(s.reaction_load, nil)
          f.errors[failing] = nil
          s:resolve_all()
          eq(s.resolving, false)
          eq(f.notifications[#f.notifications - 1], "Fetching open conversations…")
          eq(f.notifications[#f.notifications], "No unresolved, resolvable conversations in this MR.")
          eq(s.reaction_load, nil)
        end)
      end)
    end
  end)

  test("comments become visible in an open document while Git snapshots are still loading", function()
    ctx.fixture({ repository = true, discussions = true }, function(s, f)
      local network = transport(s)
      s:load()
      s:show_threads()
      local buf = vim.api.nvim_get_current_buf()
      eq(text(buf), "Loading discussions…")
      f.release("discussions")
      wait(function() return text(buf):find("A late comment", 1, true) ~= nil end)
      eq(s.ready, nil); assert(not s.current)
      eq(s.load_state.pending.discussions, nil); eq(s.load_state.pending.reactions, true)
      network.finish()
      f.release("repository")
      wait(function() return s.current ~= nil end)
      eq(s.error, nil)
    end)
  end)
end
