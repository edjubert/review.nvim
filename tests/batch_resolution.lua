return function(ctx)
  local test, eq, raises, mocked = ctx.test, ctx.eq, ctx.raises, ctx.mocked
  local provider, target = ctx.provider, ctx.target

  local function fixture(count)
    local state = { backend = {}, calls = {}, batches = {}, writes = {}, failures = {}, schema_reads = 0, list_reads = 0 }
    for index = 1, count do
      state.backend[index] = { id = ("thread-%d"):format(index), notes = {
        { id = index, body = "Feedback " .. index, resolvable = true, resolved = false,
          author = { username = "alice" }, reactions = { { name = "heart", count = 1 } } },
      } }
    end
    state.selected = vim.deepcopy(state.backend)
    local function decode(id)
      return (id:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end))
    end
    local function find(id)
      for _, item in ipairs(state.backend) do if item.id == id then return item end end
      error("Unknown discussion " .. id)
    end
    local function resolved(item)
      for _, note in ipairs(item.notes) do
        if not note.system and note.resolvable then note.resolved = true end
      end
    end
    function state.request(_, endpoint, body, method)
      state.calls[#state.calls + 1] = { endpoint = endpoint, body = vim.deepcopy(body), method = method }
      if endpoint == "graphql" and body.query:find("__type", 1, true) then
        state.schema_reads = state.schema_reads + 1
        if state.schema_error then error(state.schema_error) end
        return state.schema or { data = { __type = { fields = { { name = "discussionToggleResolve" } } } } }
      end
      local page = tonumber(endpoint:match("/discussions%?per_page=100&page=(%d+)$"))
      if page then
        state.list_reads = state.list_reads + 1
        if state.before_list then state.before_list(page) end
        if state.list_error_page == page then error("Discussion read failed") end
        local result = {}
        for index = (page - 1) * 100 + 1, math.min(page * 100, #state.backend) do
          local item = vim.deepcopy(state.backend[index])
          for _, note in ipairs(item.notes) do note.reactions, note.reactions_error = nil, nil end
          result[#result + 1] = item
        end
        return result
      end
      if endpoint == "graphql" then
        assert(body.query:find("mutation(", 1, true))
        local batch, response = {}, { data = {} }
        local index = 1
        while body.variables["input" .. index] do
          local input = body.variables["input" .. index]
          eq(input.resolve, true)
          local gid_id = assert(input.id:match("^gid://gitlab/Discussion/(.+)$"))
          local item = find(decode(gid_id))
          batch[#batch + 1] = item.id
          local errors = {}
          if state.failures[item.id] then
            errors[1] = state.failures[item.id]
          else
            resolved(item)
            state.writes[#state.writes + 1] = item.id
          end
          response.data["resolve" .. index] = {
            errors = errors, discussion = { id = input.id, resolved = #errors == 0 },
          }
          index = index + 1
        end
        state.batches[#state.batches + 1] = batch
        if state.response_error then error(state.response_error) end
        return state.respond and state.respond(response) or response
      end
      local id = assert(endpoint:match("/discussions/(.+)$"), "Unexpected endpoint " .. endpoint)
      local item = find(decode(id))
      if body then
        eq(method, "PUT"); eq(body, { resolved = true })
        resolved(item); state.writes[#state.writes + 1] = item.id
      end
      return vim.deepcopy(item)
    end
    state.results = {}
    function state.record(result, changed)
      state.results[#state.results + 1] = { result = result, changed = changed }
    end
    function state.resolve()
      provider.resolve_many(target, state.selected, state.record)
    end
    return state
  end

  test("batch resolution sends aliased mutations and literal variables through the authenticated transport", function()
    local state, calls = fixture(3), {}
    state.backend[1].id, state.selected[1].id = "thread/id", "thread/id"
    mocked({
      { provider, "request", ctx.request },
      { require("review.async"), "checked", function(argv, opts)
        local body = opts.stdin and vim.json.decode(opts.stdin)
        calls[#calls + 1] = { argv = argv, body = body }
        return vim.json.encode(state.request(target, argv[7], body, argv[6]))
      end },
    }, state.resolve)
    eq(#calls, 3); eq(state.list_reads, 1); eq(#state.batches, 1)
    eq(calls[3].argv, { "glab", "api", "--hostname", target.host,
      "--method", "POST", "graphql", "--input", "-" })
    local body = calls[3].body
    eq(body.variables.input1, { id = "gid://gitlab/Discussion/thread%2Fid", resolve = true })
    for index = 1, 3 do
      assert(body.query:find(("resolve%d: discussionToggleResolve(input: $input%d)"):format(index, index), 1, true))
      assert(not body.query:find(state.selected[index].id, 1, true))
      local result = state.results[index].result
      eq(result.notes[1].body, state.selected[index].notes[1].body)
      eq(result.notes[1].reactions, state.selected[index].notes[1].reactions)
      eq(result.notes[1].web_url, target.url .. "#note_" .. index)
      eq(provider.is_resolved(result), true); eq(state.results[index].changed, true)
      eq(provider.is_resolved(state.selected[index]), false)
    end
  end)

  test("batch resolution bounds mutations at twenty and consumes every discussion page", function()
    local state = fixture(102)
    mocked({ { provider, "request", state.request } }, state.resolve)
    eq(state.schema_reads, 1); eq(state.list_reads, 12)
    eq(#state.batches, 6); eq(#state.results, 102)
    for index, batch in ipairs(state.batches) do eq(#batch, index == 6 and 2 or 20) end
    eq(#state.calls, 19)
  end)

  test("batch resolution validates the entire lot before writing changed or missing feedback", function()
    local changes = {
      function(item) item.notes[2] = { id = 999, body = "New reply", resolvable = true, resolved = false } end,
      function(item) item.notes[1].body = "Edited feedback" end,
      function(item) item.notes[1].id = 999 end,
      function(item) item.notes[1].resolvable = false end,
      function(item) item.id = "removed" end,
    }
    for _, change in ipairs(changes) do
      local state = fixture(3)
      change(state.backend[2])
      mocked({ { provider, "request", state.request } }, function()
        eq(pcall(state.resolve), false)
      end)
      eq(state.writes, {}); eq(state.batches, {}); eq(state.results, {})
    end
  end)

  test("batch resolution rereads later lots and preserves earlier successes when new feedback arrives", function()
    local state = fixture(21)
    state.before_list = function()
      if state.list_reads == 2 then
        state.backend[21].notes[2] = { id = 999, body = "New reply", resolvable = true, resolved = false }
      end
    end
    mocked({ { provider, "request", state.request } }, function()
      raises(state.resolve, "conversation changed")
    end)
    eq(#state.batches, 1); eq(#state.results, 20)
    eq(provider.is_resolved(state.backend[21]), false)
  end)

  test("batch resolution skips already resolved conversations and never writes an empty selection", function()
    for _, all in ipairs({ false, true }) do
      local state = fixture(2)
      state.backend[1].notes[1].resolved = true
      state.backend[2].notes[1].resolved = all
      mocked({ { provider, "request", state.request } }, state.resolve)
      eq(#state.results, 2); eq(state.results[1].changed, false)
      eq(#state.batches, all and 0 or 1)
      eq(#state.writes, all and 0 or 1)
    end
    local state = fixture(0)
    mocked({ { provider, "request", state.request } }, state.resolve)
    eq(state.calls, {})
  end)

  test("batch resolution falls back before writes on unsupported schemas and keeps single resolves on REST", function()
    for _, schema in ipairs({
      { data = { __type = { fields = {} } } },
      { errors = { { message = "Introspection disabled" } } },
    }) do
      local state = fixture(2)
      state.schema = schema
      mocked({ { provider, "request", state.request } }, state.resolve)
      eq(state.schema_reads, 1); eq(state.list_reads, 0); eq(state.batches, {})
      eq(#state.writes, 2); eq(#state.results, 2)
    end
    local state = fixture(1)
    mocked({ { provider, "request", state.request } }, state.resolve)
    eq(state.schema_reads, 0); eq(#state.calls, 2); eq(#state.results, 1)
  end)

  test("batch resolution supports the cached complete introspection schema", function()
    local state = fixture(2)
    state.schema = { data = { __schema = { types = {
      { name = "Query", fields = {} },
      { name = "Mutation", fields = { { name = "discussionToggleResolve" } } },
    } } } }
    mocked({ { provider, "request", state.request } }, state.resolve)
    eq(#state.batches, 1); eq(#state.results, 2)
  end)

  test("batch resolution records successes after a failed alias and stops before the next lot", function()
    local state = fixture(21)
    state.failures["thread-2"] = "Permission denied"
    mocked({ { provider, "request", state.request } }, function()
      raises(state.resolve, "thread-2: Permission denied")
    end)
    eq(#state.batches, 1); eq(#state.results, 19)
    eq(state.results[2].result.id, "thread-3")
    eq(provider.is_resolved(state.backend[2]), false)
    eq(provider.is_resolved(state.backend[21]), false)
  end)

  test("batch resolution isolates GraphQL field errors while retaining other confirmed results", function()
    local state = fixture(3)
    state.respond = function(response)
      response.data.resolve2 = vim.NIL
      response.errors = { { message = "GraphQL failure", path = { "resolve2", "discussion" } } }
      return response
    end
    mocked({ { provider, "request", state.request } }, function()
      raises(state.resolve, "GraphQL failure")
    end)
    eq(#state.batches, 1); eq(#state.results, 2)
    eq(state.results[1].result.id, "thread-1"); eq(state.results[2].result.id, "thread-3")
  end)

  test("batch resolution rejects missing, mismatched and unresolved payloads without retrying", function()
    local changes = {
      function(response) response.data.resolve1 = vim.NIL end,
      function(response) response.data.resolve1.discussion.id = "gid://gitlab/Discussion/another" end,
      function(response) response.data.resolve1.discussion.resolved = false end,
      function(response) response.data.resolve1.errors = nil end,
      function(response) response.data.resolve1.errors = { invalid = true } end,
      function(response) response.data.resolve1.errors = { false } end,
    }
    for _, change in ipairs(changes) do
      local state = fixture(2)
      state.respond = function(response) change(response); return response end
      mocked({ { provider, "request", state.request } }, function()
        raises(state.resolve, "did not confirm")
      end)
      eq(#state.batches, 1); eq(#state.results, 1); eq(state.results[1].result.id, "thread-2")
      eq(#state.calls, 3)
    end
  end)

  test("batch resolution stops on malformed global errors while retaining confirmed results", function()
    for _, errors in ipairs({ false, { unexpected = true }, { false } }) do
      local state = fixture(21)
      state.respond = function(response) response.errors = errors; return response end
      mocked({ { provider, "request", state.request } }, function()
        raises(state.resolve, "Unconfirmed GraphQL operation")
      end)
      eq(#state.batches, 1); eq(#state.results, 20)
      eq(provider.is_resolved(state.backend[21]), false)
    end
  end)

  test("batch resolution never falls back or retries when a mutation response is lost", function()
    local state = fixture(21)
    state.response_error = "Connection lost after mutation"
    mocked({ { provider, "request", state.request } }, function()
      raises(state.resolve, "Connection lost after mutation")
    end)
    eq(#state.batches, 1); eq(#state.writes, 20); eq(state.results, {}); eq(#state.calls, 3)
    eq(provider.is_resolved(state.backend[21]), false)
  end)

  test("batch resolution read failures prevent writes even when the first discussion page is complete", function()
    for _, phase in ipairs({ "schema", "discussions" }) do
      local state = fixture(102)
      if phase == "schema" then state.schema_error = "Schema read failed"
      else state.list_error_page = 2 end
      mocked({ { provider, "request", state.request } }, function()
        raises(state.resolve, "read failed")
      end)
      eq(state.batches, {}); eq(state.writes, {}); eq(state.results, {})
    end
  end)

  test("ReviewResolveAll batches only the confirmed author snapshot and preserves local drafts", function()
    local s, state = ctx.fixture({ inline_comments = true }), fixture(3)
    s:save_draft("Keep local", vim.deepcopy(s.data.discussions[1].notes[1].position), "head")
    local drafts, notifications, pending, choice = vim.deepcopy(s.drafts), {}
    s.data.discussions = vim.deepcopy(state.selected)
    local revisions = 0
    mocked({
      { provider, "request", state.request },
      { provider, "current", function() revisions = revisions + 1; return { diff_refs = ctx.refs } end },
      { vim, "notify", function(message) notifications[#notifications + 1] = message end },
      { vim.ui, "select", function(items, _, callback) choice, pending = items[3], callback end },
    }, function()
      s:resolve_all()
      eq(state.schema_reads, 0); eq(state.writes, {}); eq(revisions, 1)
      state.backend[4] = { id = "new-after-warning", notes = {
        { id = 999, body = "New feedback", resolvable = true, resolved = false, author = { username = "alice" } },
      } }
      pending(choice)
      eq(revisions, 2); eq(#state.batches, 1); eq(#state.writes, 3)
      eq(provider.is_resolved(state.backend[4]), false)
      eq(#s.data.discussions, 4); eq(s.resolving, false); eq(s.error, nil)
      for index = 1, 3 do eq(provider.is_resolved(s.data.discussions[index]), true) end
      eq(s.drafts, drafts); eq(ctx.drafts.load(s.config, s.target), drafts)
      eq(notifications[#notifications], "ReviewResolveAll complete: 3 selected conversation(s) resolved on MR !12.")
    end)
    s:close()
  end)

  test("ReviewResolveAll retains every confirmed batch result and reports partial success without completion", function()
    local s, state, notifications = ctx.fixture({ inline_comments = true }), fixture(21), {}
    s.data.discussions = vim.deepcopy(state.selected)
    state.failures["thread-2"] = "Permission denied"
    mocked({
      { provider, "request", state.request },
      { provider, "current", function() return { diff_refs = ctx.refs } end },
      { vim, "notify", function(message) notifications[#notifications + 1] = message end },
      { vim.ui, "select", function(items, _, callback) callback(items[2]) end },
    }, function()
      s:resolve_all()
      eq(#state.batches, 1); eq(s.resolving, false)
      for index = 1, 21 do
        eq(provider.is_resolved(s.data.discussions[index]), index ~= 2 and index ~= 21)
      end
      assert(s.error:find("Permission denied", 1, true))
      local messages = table.concat(notifications, "\n")
      assert(messages:find("after 19 confirmed conversation(s)", 1, true))
      assert(not messages:find("ReviewResolveAll complete:", 1, true))
    end)
    s:close()
  end)
end
