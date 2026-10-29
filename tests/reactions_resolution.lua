return function(ctx)
  local test, eq, raises, mocked = ctx.test, ctx.eq, ctx.raises, ctx.mocked
  local provider, ui, refs, target = ctx.provider, ctx.ui, ctx.refs, ctx.target
  local reactions = require("review.reactions")

  test("reaction counts render Unicode, unknown aliases and reacting users without changing bodies", function()
    local note = { body = "Literal :thumbsup:", reactions = reactions.aggregate({
      { name = "thumbsup", user = { username = "bob" } },
      { name = "thumbsup", user = { username = "alice" } },
      { name = "heart" }, { name = "custom_emoji" }, { name = vim.NIL }, { name = "bad\nname" },
    }) }
    eq(#note.reactions, 3)
    local inline, document = reactions.text(note), reactions.text(note, true)
    assert(inline:find("👍 2", 1, true) and inline:find("❤️ 1", 1, true))
    assert(inline:find(":custom_emoji: 1", 1, true))
    assert(document:find("👍 2 (@alice, @bob)", 1, true))
    eq(note.body, "Literal :thumbsup:")
    eq(reactions.text({ reactions = {} }), nil)
    eq(reactions.text({ reactions_error = "Missing permission" }), "Reactions unavailable")
    eq(reactions.text({ reactions = reactions.summary({ ["+1"] = 2, heart = 1, total_count = 3, laugh = 0 }) }),
      "Reactions: 👍 2 · ❤️ 1")
    eq(reactions.text({ reactions = reactions.aggregate({ { content = "🎉", user = { login = "alice" } } }) }),
      "Reactions: 🎉 1")
  end)

  test("GitLab reaction reads include replies, skip system notes and preserve comments on failure", function()
    local endpoints = {}
    mocked({
      { provider, "pages", function(_, endpoint)
        endpoints[#endpoints + 1] = endpoint
        if endpoint:match("/discussions$") then
          return { { id = "thread", notes = {
            { id = 101, body = "Root" }, { id = 102, body = "Reply" },
            { id = 103, system = true }, { id = vim.NIL },
          } } }
        end
        if endpoint:match("/101/award_emoji$") then
          return { { name = "thumbsup", user = { username = "alice" } }, { name = "thumbsup" } }
        end
        eq(endpoint, provider.mr_path(target) .. "/notes/102/award_emoji")
        error("Unavailable reaction API")
      end },
    }, function()
      local notes = provider.discussions(target)[1].notes
      eq(#endpoints, 3); eq(notes[1].reactions[1].count, 2)
      eq(notes[1].web_url, target.url .. "#note_101")
      eq(notes[2].body, "Reply"); assert(notes[2].reactions_error)
      eq(notes[3].reactions, nil); eq(notes[4].reactions, nil)
    end)
  end)

  test("GitHub and Codeberg normalize reactions from their comment APIs", function()
    local github, codeberg = require("review.providers.github"), require("review.providers.codeberg")
    local gh_target = assert(ctx.url.parse("https://github.com/owner/repo/pull/7"))
    local cb_target = assert(ctx.url.parse("https://codeberg.org/owner/repo/pulls/7"))
    mocked({
      { github, "pages", function()
        return { { id = 1, reactions = { ["+1"] = 2, heart = 1 } } }
      end },
      { codeberg, "pages", function(_, endpoint)
        if endpoint:match("/reviews$") then return { { id = 2, state = "COMMENT", comments_count = 1 } } end
        eq(endpoint, "repos/owner/repo/issues/comments/52/reactions")
        return { { content = "🎉", user = { login = "alice" } } }
      end },
      { codeberg, "request", function(_, endpoint, body)
        eq(body, nil); eq(endpoint, codeberg.pr_path(cb_target) .. "/reviews/2/comments")
        return { { id = 52, body = "Review comment", position = 3 } }
      end },
    }, function()
      local gh = github.discussions(gh_target, refs, {})
      eq(reactions.text(gh[1].notes[1]), "Reactions: 👍 2 · ❤️ 1")
      local cb = codeberg.discussions(cb_target, refs, {})
      eq(reactions.text(cb[1].notes[1], true), "Reactions: 🎉 1 (@alice)")
    end)
  end)

  test("reaction rows retain reply navigation and do not alter inline diff positions", function()
    local s = ctx.fixture({ inline_comments = true })
    local discussion = s.data.discussions[1]
    local root, reply = discussion.notes[1], discussion.notes[3]
    root.reactions = reactions.aggregate({ { name = "thumbsup" }, { name = "thumbsup" } })
    reply.reactions = reactions.aggregate({ { name = "heart", user = { username = "carol" } } })
    local original = vim.api.nvim_buf_get_lines(s.viewer_buf, 0, -1, false)
    ui.comments(s)
    local text = ctx.virtual_text(ctx.comment_marks(s)[2])
    assert(text:find("Reactions: 👍 2", 1, true))
    assert(text:find("Reactions: ❤️ 1", 1, true))
    local lines, entries, comments = require("review.threads").document({ discussion })
    for row, line in ipairs(lines) do
      if line:find("Reactions: ❤️ 1", 1, true) then
        eq(entries[row], discussion); eq(comments[row], reply)
      end
    end
    eq(vim.api.nvim_buf_get_lines(s.viewer_buf, 0, -1, false), original)
    s:close()
  end)

  local function conversation(id, note_id, body)
    return { id = id, notes = {
      { id = note_id, body = body or "Feedback", resolvable = true, resolved = false,
        author = { username = "alice" }, reactions = reactions.aggregate({ { name = "thumbsup" } }) },
    } }
  end

  test("GitLab resolution uses GET then PUT with a literal resolved=true payload", function()
    local async, calls = require("review.async"), {}
    local original = conversation("thread/id", 101)
    mocked({
      { async, "checked", function(argv, opts)
        calls[#calls + 1] = { argv = argv, body = opts.stdin and vim.json.decode(opts.stdin) }
        local result = vim.deepcopy(original)
        if argv[6] == "PUT" then result.notes[1].resolved = true end
        return vim.json.encode(result)
      end },
    }, function()
      local result, changed = provider.resolve(target, original)
      eq(changed, true); eq(result.notes[1].resolved, true)
      eq(result.notes[1].web_url, target.url .. "#note_101")
      eq(result.notes[1].reactions, original.notes[1].reactions)
      eq(#calls, 2); eq(calls[1].argv[6], "GET"); eq(calls[2].argv[6], "PUT")
      eq(calls[2].argv[7], provider.mr_path(target) .. "/discussions/thread%2Fid")
      eq(calls[2].body, { resolved = true }); eq(calls[2].argv[#calls[2].argv], "-")
    end)
  end)

  test("changed or missing GitLab conversations cannot be resolved from a stale snapshot", function()
    local original = conversation("thread", 101)
    local added = vim.deepcopy(original)
    added.notes[2] = { id = 102, body = "New reply", resolvable = true, resolved = false }
    local edited = vim.deepcopy(original)
    edited.notes[1].body = "Edited feedback"
    local replaced = conversation("thread", 103)
    for _, fresh in ipairs({ added, edited, replaced, conversation("other", 101) }) do
      local writes = 0
      mocked({
        { provider, "request", function(_, _, body)
          if body then writes = writes + 1 end
          return fresh
        end },
      }, function()
        local ok = pcall(provider.resolve, target, original)
        eq(ok, false); eq(writes, 0)
      end)
    end
  end)

  test("already resolved conversations skip PUT and unconfirmed responses never report success", function()
    local original, calls = conversation("thread", 101), 0
    mocked({
      { provider, "request", function(_, _, body)
        calls = calls + 1
        eq(body, nil)
        local result = vim.deepcopy(original)
        result.notes[1].resolved = true
        return result
      end },
    }, function()
      local _, changed = provider.resolve(target, original)
      eq(changed, false); eq(calls, 1)
    end)
    mocked({
      { provider, "request", function() return vim.deepcopy(original) end },
    }, function()
      raises(function() provider.resolve(target, original) end, "did not confirm")
    end)
    local general = conversation("general", 102)
    general.notes[1].resolvable = false
    mocked({ { provider, "request", function() return general end } }, function()
      raises(function() provider.resolve(target, general) end, "cannot be resolved")
    end)
  end)

  local function fixture()
    local s = ctx.fixture({ inline_comments = true })
    s.data.discussions = { s.data.discussions[1], s.data.discussions[2], s.data.discussions[3] }
    s.data.discussions[3].id = "overlap"
    for _, discussion in ipairs(s.data.discussions) do
      for _, note in ipairs(discussion.notes) do
        if not note.system then note.resolvable, note.resolved = true, false end
      end
    end
    local backend, order = {}, {}
    for _, discussion in ipairs(s.data.discussions) do
      backend[discussion.id] = vim.deepcopy(discussion)
      order[#order + 1] = discussion.id
    end
    local calls = {}
    local overrides = {
      { vim, "notify", function() end },
      { provider, "current", function() return { diff_refs = refs } end },
      { provider, "discussions", function()
        local result = {}
        for _, id in ipairs(order) do result[#result + 1] = vim.deepcopy(backend[id]) end
        return result
      end },
      { provider, "request", function(_, endpoint, body, method)
        local id = endpoint:match("/discussions/(.+)$")
        assert(backend[id], "Unknown discussion " .. tostring(id))
        if body then
          eq(method, "PUT"); eq(body, { resolved = true })
          calls[#calls + 1] = id
          for _, note in ipairs(backend[id].notes) do
            if note.resolvable then note.resolved = true end
          end
        end
        return vim.deepcopy(backend[id])
      end },
    }
    return s, backend, order, calls, overrides
  end

  test("ReviewResolve resolves the whole conversation from a reply and updates open windows", function()
    local s, backend, _, calls, overrides = fixture()
    local review = require("review")
    local discussion = s.data.discussions[1]
    s:save_draft("Keep local", vim.deepcopy(discussion.notes[1].position), "head")
    local drafts = vim.deepcopy(s.drafts)
    overrides[#overrides + 1] = { review, "session", s }
    mocked(overrides, function()
      review._commands()
      s:show_threads({ discussion })
      local buf, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
      for row, text in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
        if text == "A reply" then vim.api.nvim_win_set_cursor(win, { row, 0 }); break end
      end
      vim.cmd.ReviewResolve()
      eq(calls, { "new" }); eq(provider.is_resolved(backend.new), true); eq(s.resolving, false)
      eq(s.drafts, drafts); eq(ctx.drafts.load(s.config, s.target), drafts)
      local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
      assert(text:find("Resolved discussion", 1, true))
      for row, note in pairs(s.thread_documents[buf]) do eq(note.resolved, true); assert(s.thread_views[buf].entries[row]) end
      vim.fn.maparg("<CR>", "n", false, true).callback()
      eq(vim.api.nvim_get_current_win(), s.viewer_win)
      eq(s.thread_views[buf], nil)
    end)
    s:close()
  end)

  test("overlapping conversations require selection and stale selections do not write", function()
    local s, _, _, calls, overrides = fixture()
    local pending
    overrides[#overrides + 1] = { vim.ui, "select", function(items, opts, selected)
      eq(#items, 2); eq(opts.prompt, "Resolve which conversation?")
      pending = selected
    end }
    mocked(overrides, function()
      vim.api.nvim_win_set_cursor(s.viewer_win, { 4, 0 })
      s:resolve(); eq(#calls, 0)
      pending(nil); eq(#calls, 0)
      s:resolve()
      s.generation = s.generation + 1
      pending(s.data.discussions[1]); eq(#calls, 0)
      s:resolve()
      pending(s.data.discussions[3]); eq(calls, { "overlap" })
    end)
    s:close()
  end)

  test("resolve all warns with the exact candidate count and cancellation never writes", function()
    local s, backend, _, calls, overrides = fixture()
    backend.old.notes[1].resolved = true
    backend.overlap.notes[1].resolvable = false
    local pending
    overrides[#overrides + 1] = { vim.ui, "select", function(items, opts, selected)
      eq(items[1], "Cancel"); assert(items[2]:find("all 1 conversation(s)", 1, true))
      assert(opts.prompt:find("WARNING", 1, true)); assert(opts.prompt:find("outdated", 1, true))
      pending = selected
    end }
    mocked(overrides, function()
      s:resolve_all(); eq(#calls, 0); eq(s.resolving, true)
      s:close(); eq(s.closed, false)
      pending(nil); eq(#calls, 0); eq(s.resolving, false)
    end)
    s:close()
  end)

  test("resolve all only mutates confirmed snapshot IDs and leaves newly created conversations open", function()
    local s, backend, order, calls, overrides = fixture()
    local pending, choice
    overrides[#overrides + 1] = { vim.ui, "select", function(items, _, selected) pending, choice = selected, items[2] end }
    mocked(overrides, function()
      s:resolve_all(); eq(#calls, 0)
      backend.added = conversation("added", 900)
      order[#order + 1] = "added"
      pending(choice)
      eq(calls, { "new", "old", "overlap" }); eq(s.resolving, false)
      eq(backend.added.notes[1].resolved, false)
      eq(s.data.discussions[4].notes[1].resolved, false)
    end)
    s:close()
  end)

  test("new replies after the bulk warning prevent unseen feedback from being resolved", function()
    local s, backend, _, calls, overrides = fixture()
    local pending, choice
    overrides[#overrides + 1] = { vim.ui, "select", function(items, _, selected) pending, choice = selected, items[2] end }
    mocked(overrides, function()
      s:resolve_all()
      backend.new.notes[#backend.new.notes + 1] = { id = 999, body = "New feedback", resolvable = true, resolved = false }
      pending(choice)
      eq(#calls, 0); eq(s.resolving, false)
      assert(s.error:find("conversation changed", 1, true))
      eq(backend.new.notes[1].resolved, false)
    end)
    s:close()
  end)

  test("partial resolution keeps confirmed successes and stops before later conversations", function()
    local s, backend, _, calls, overrides = fixture()
    local request = overrides[#overrides][3]
    overrides[#overrides][3] = function(t, endpoint, body, method)
      if body and endpoint:match("/old$") then error("Connection lost") end
      return request(t, endpoint, body, method)
    end
    local notifications = {}
    overrides[1][3] = function(message) notifications[#notifications + 1] = message end
    overrides[#overrides + 1] = { vim.ui, "select", function(items, _, selected) selected(items[2]) end }
    mocked(overrides, function()
      s:resolve_all(); eq(calls, { "new" }); eq(s.resolving, false)
      eq(provider.is_resolved(s.data.discussions[1]), true)
      eq(provider.is_resolved(backend.old), false); eq(provider.is_resolved(backend.overlap), false)
      assert(table.concat(notifications, "\n"):find("after 1 confirmed conversation(s)", 1, true))
    end)
    s:close()
  end)

  test("changed MR revisions block resolution after the bulk confirmation", function()
    local s, _, _, calls, overrides = fixture()
    local pending, choice
    overrides[#overrides + 1] = { vim.ui, "select", function(items, _, selected) pending, choice = selected, items[2] end }
    mocked(overrides, function()
      s:resolve_all()
      mocked({
        { provider, "current", function() return { diff_refs = { head_sha = "new" } } end },
      }, function() pending(choice) end)
      eq(#calls, 0); eq(s.resolving, false)
      assert(s.error:find("MR changed", 1, true))
    end)
    s:close()
  end)

  test("unsupported providers and empty or resolved contexts never attempt resolution", function()
    local s, backend, _, calls, overrides = fixture()
    mocked(overrides, function()
      vim.api.nvim_win_set_cursor(s.viewer_win, { 1, 0 })
      s:resolve(); eq(#calls, 0)
      for _, discussion in ipairs(s.data.discussions) do
        for _, note in ipairs(discussion.notes) do note.resolved = true end
        backend[discussion.id] = vim.deepcopy(discussion)
      end
      s:resolve_all(); eq(#calls, 0); eq(s.resolving, false)
      s.provider = require("review.providers.github")
      s:resolve(); s:resolve_all(); eq(#calls, 0)
    end)
    s:close()
  end)

  test("failed refresh after confirmed resolution does not undo the successful state", function()
    local s, _, _, calls, overrides = fixture()
    overrides[3][3] = function() error("Refresh unavailable") end
    mocked(overrides, function()
      s:resolve_conversations({ s.data.discussions[1] }, refs)
      eq(calls, { "new" }); eq(s.resolving, false)
      eq(provider.is_resolved(s.data.discussions[1]), true); eq(s.error, nil)
    end)
    s:close()
  end)
end
