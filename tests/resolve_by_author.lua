return function(ctx)
  local test, eq = ctx.test, ctx.eq
  local provider = require("review.providers.gitlab")
  local function discussion(id, note_id, username)
    local result = vim.deepcopy(ctx.discussion)
    result.id = id
    local root = result.notes[1]
    root.id, root.resolvable, root.resolved = note_id, true, false
    root.author = username and { username = username, name = "Same display name" } or nil
    return result
  end

  local function fixture(fn)
    ctx.fixture({}, function(s, f)
      local alice = discussion("alice-current", 1, "alice")
      alice.notes[2] = { id = 2, body = "Bob's reply", author = { username = "bob" } }
      local outdated = discussion("alice-outdated", 3, "alice")
      outdated.notes[1].outdated = true
      table.insert(outdated.notes, 1, { id = 4, system = true, author = { username = "carol" } })
      local bob = discussion("bob-current", 5, "bob")
      bob.notes[2] = { id = 6, body = "Alice's reply", author = { username = "alice" } }
      local general = discussion("bob-general", 7, "bob")
      general.notes[1].position = nil
      local resolved = discussion("alice-resolved", 8, "alice")
      resolved.notes[1].resolved = true
      local unresolvable = discussion("bob-unresolvable", 9, "bob")
      unresolvable.notes[1].resolvable = false
      f.values.discussions = {
        alice, outdated, bob, general, discussion("unknown-author", 10),
        resolved, unresolvable,
      }
      s.provider.can_resolve, s.provider.resolve = provider.can_resolve, provider.resolve
      local writes, dialog = {}, {}
      local saved_request, saved_select = provider.request, vim.ui.select
      provider.request = function(_, endpoint, body, method)
        local prefix = provider.mr_path(s.target) .. "/discussions/"
        eq(endpoint:sub(1, #prefix), prefix)
        local id = endpoint:sub(#prefix + 1)
        local current
        for _, item in ipairs(f.values.discussions) do
          if item.id == id then current = item; break end
        end
        assert(current, "Unknown conversation " .. id)
        if body then
          eq(method, "PUT"); eq(body, { resolved = true })
          writes[#writes + 1] = id
          for _, note in ipairs(current.notes) do
            if note.resolvable then note.resolved = true end
          end
        else
          eq(method, nil)
        end
        return vim.deepcopy(current)
      end
      vim.ui.select = function(items, opts, answer)
        dialog.items, dialog.opts, dialog.answer = items, opts, answer
      end
      local ok, err = xpcall(function()
        s:load()
        fn(s, f, writes, dialog)
      end, debug.traceback)
      provider.request, vim.ui.select = saved_request, saved_select
      assert(ok, err)
    end)
  end

  test("resolve all offers root-author counts and resolves only the chosen snapshot", function()
    local choices = {
      "Cancel",
      "Resolve all 5 conversation(s) on MR !12",
      "Resolve 2 conversation(s) started by @alice on MR !12",
      "Resolve 2 conversation(s) started by @bob on MR !12",
    }
    local expected = {
      {}, { "alice-current", "alice-outdated", "bob-current", "bob-general", "unknown-author" },
      { "alice-current", "alice-outdated" }, { "bob-current", "bob-general" },
    }
    for index, choice in ipairs(choices) do
      fixture(function(s, f, writes, dialog)
        s:resolve_all()
        eq(dialog.items, choices)
        assert(dialog.opts.prompt:find("WARNING", 1, true))
        assert(dialog.opts.prompt:find("outdated", 1, true))
        eq(writes, {}); eq(s.resolving, true)
        -- Neither all nor author choices include conversations created after
        -- the warning, even if their root author matches the selected group.
        f.values.discussions[#f.values.discussions + 1] = discussion("new-alice", 11, "alice")
        dialog.answer(choice)
        eq(writes, expected[index]); eq(s.resolving, false); eq(s.error, nil)
        for _, item in ipairs(s.data.discussions) do
          local included = vim.list_contains(expected[index], item.id)
          if item.id ~= "alice-resolved" then
            local root = require("review.threads").root(item)
            eq(root.resolved, included)
          end
        end
        if index > 1 then
          eq(f.notifications[#f.notifications],
            ("ReviewResolveAll complete: %d selected conversation(s) resolved on MR !12.")
              :format(#expected[index]))
        end
      end)
    end
  end)

  test("new feedback after an author selection warning prevents resolution and success confirmation", function()
    fixture(function(s, f, writes, dialog)
      s:resolve_all()
      f.values.discussions[1].notes[#f.values.discussions[1].notes + 1] = {
        id = 12, body = "New feedback", resolvable = true, resolved = false,
        author = { username = "carol" },
      }
      dialog.answer(dialog.items[3])
      eq(writes, {}); eq(s.resolving, false)
      assert(s.error:find("conversation changed", 1, true))
      for _, item in ipairs(s.data.discussions) do
        if item.id ~= "alice-resolved" then
          eq(require("review.threads").root(item).resolved, false)
        end
      end
      assert(not table.concat(f.notifications, "\n"):find("ReviewResolveAll complete:", 1, true))
    end)
  end)
end
