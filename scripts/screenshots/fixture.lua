local M = {}
local project_url = "https://gitlab.example.com/demo/inbox"
local demo_url = project_url .. "/-/merge_requests/42"
local inbox_path = "demo/src/inbox.lua"

local base_inbox = [[local M = {}

local function matches_query(message, query)
  local subject = message.subject:lower()
  return subject:find(query, 1, true) ~= nil
end

local function newest_first(left, right)
  return left.received_at > right.received_at
end

function M.filter(messages, options)
  local query = options.query:lower()
  local matches = {}

  for _, message in ipairs(messages) do
    if matches_query(message, query) then
      matches[#matches + 1] = message
    end
  end

  table.sort(matches, newest_first)
  return matches
end

function M.summary(messages)
  local unread = 0
  for _, message in ipairs(messages) do
    if not message.read then unread = unread + 1 end
  end
  return ("%d messages · %d unread"):format(#messages, unread)
end

return M
]]

local function replace(text, before, after)
  local first, last = text:find(before, 1, true)
  assert(first, "Missing fixture text")
  return text:sub(1, first - 1) .. after .. text:sub(last + 1)
end

local function write(repo, path, text)
  local destination = repo .. "/" .. path
  vim.fn.mkdir(vim.fn.fnamemodify(destination, ":h"), "p")
  local file = assert(io.open(destination, "wb"))
  assert(file:write(text))
  assert(file:close())
end

function M.create(root)
  local fixture = { root = root, repo = root .. "/repo", url = demo_url, actions = {} }
  local repo = fixture.repo
  assert(not vim.uv.fs_stat(repo), "The fixture repository must be new.")
  vim.fn.mkdir(repo, "p")
  vim.fn.mkdir(root .. "/hooks", "p")
  vim.fn.mkdir(root .. "/template", "p")

  local function git(args, date)
    local argv = {
      "git", "-C", repo,
      "-c", "core.hooksPath=" .. root .. "/hooks",
      "-c", "commit.gpgsign=false",
      "-c", "user.name=demo-author",
      "-c", "user.email=demo@example.com",
    }
    vim.list_extend(argv, args)
    local result = vim.system(argv, {
      text = true, timeout = 10000,
      env = { GIT_AUTHOR_DATE = date, GIT_COMMITTER_DATE = date },
    }):wait()
    assert(result.code == 0, vim.trim(result.stderr or "Fixture Git command failed."))
    return result.stdout or ""
  end

  git({ "init", "--initial-branch=demo-review", "--template=" .. root .. "/template" })
  write(repo, inbox_path, base_inbox)
  write(repo, "demo/src/config.lua", "return { query = \"\", unread_only = false }\n")
  write(repo, "demo/legacy.lua", "-- Previous inbox implementation.\nreturn {}\n")
  write(repo, "demo/USAGE.md", "# Inbox filters\n\nSearch messages by subject.\n")
  git({ "add", "--", "demo" })
  git({ "commit", "-m", "chore: prepare inbox example" }, "2026-10-29T09:00:00Z")
  local base = vim.trim(git({ "rev-parse", "HEAD" }))
  local commits = {}
  local function commit(title, date)
    local parent = vim.trim(git({ "rev-parse", "HEAD" }))
    git({ "add", "--all", "--", "demo" })
    git({ "commit", "-m", title }, date)
    commits[#commits + 1] = {
      id = vim.trim(git({ "rev-parse", "HEAD" })), parent_ids = { parent },
      title = title, message = title, author_name = "demo-author", created_at = date,
    }
  end

  local head_inbox = replace(base_inbox, "  local query = options.query:lower()",
    "  options = options or {}\n  local query = (options.query or ''):lower()")
  head_inbox = replace(head_inbox, "    if matches_query(message, query) then",
    "    local visible = not options.unread_only or not message.read\n"
      .. "    if visible and matches_query(message, query) then")
  write(repo, inbox_path, head_inbox)
  write(repo, "demo/src/config.lua", "return { query = \"\", unread_only = true }\n")
  commit("feat: filter unread messages", "2026-10-29T09:01:00Z")
  write(repo, "demo/tests/inbox_spec.lua", [[local inbox = require("demo.src.inbox")
local messages = { { subject = "Hello", read = false, received_at = 1 } }
assert(#inbox.filter(messages) == 1)
assert(#inbox.filter(messages, { unread_only = true }) == 1)
]])
  assert(vim.uv.fs_unlink(repo .. "/demo/legacy.lua"))
  commit("test: cover inbox filters", "2026-10-29T09:02:00Z")
  vim.fn.mkdir(repo .. "/demo/docs", "p")
  assert(vim.uv.fs_rename(repo .. "/demo/USAGE.md", repo .. "/demo/docs/USAGE.md"))
  commit("docs: refresh inbox example", "2026-10-29T09:03:00Z")
  local head = commits[3].id
  local refs = { base_sha = base, start_sha = base, head_sha = head }

  local fields = vim.split(git({
    "diff", "--no-ext-diff", "--no-textconv", "--name-status", "-z", "--find-renames", base, head, "--",
  }), "\0", { plain = true, trimempty = true })
  local diffs, index = {}, 1
  while index <= #fields do
    local status, old_path = fields[index], fields[index + 1]
    local new_path = old_path
    index = index + 2
    if status:match("^[RC]") then new_path, index = fields[index], index + 1 end
    diffs[#diffs + 1] = {
      old_path = old_path, new_path = new_path,
      new_file = status:sub(1, 1) == "A", deleted_file = status:sub(1, 1) == "D",
      renamed_file = status:sub(1, 1) == "R",
      diff = git({ "diff", "--no-ext-diff", "--no-textconv", "--find-renames",
        "--unified=3", base, head, "--", old_path, new_path }),
    }
  end
  assert(#diffs == 5, "Expected five fixture file changes.")
  local inbox_diff
  for _, file in ipairs(diffs) do if file.new_path == inbox_path then inbox_diff = file end end
  local function line(text)
    for number, value in ipairs(vim.split(head_inbox, "\n", { plain = true })) do
      if value:find(text, 1, true) then return number end
    end
    error("Missing fixture anchor: " .. text)
  end
  fixture.query = { first = line("options = options or"), last = line("local query =") }
  fixture.range = { first = line("local visible ="), last = line("if visible and") }
  fixture.inbox_path = inbox_path
  local patch = require("review.diff").patch(inbox_diff.diff)
  local function position(first, last)
    local rows = {}
    for number = first, last do rows[#rows + 1] = assert(patch.by_new[number]) end
    return assert(require("review.position").build(refs, inbox_diff, rows))
  end
  local range_position = position(fixture.range.first, fixture.range.last)
  local query_position = position(fixture.query.first, fixture.query.last)

  fixture.comment_body = "Maybe we could extract this condition into a `matches_filters` helper.\n\n"
    .. "That would keep the loop readable when we add more inbox filters."
  local function note(id, username, body, anchor, resolved)
    return {
      id = id, author = { username = username }, body = body, position = vim.deepcopy(anchor),
      resolvable = true, resolved = resolved, system = false,
      web_url = demo_url .. "#note_" .. id,
    }
  end
  local root_note = note(4201, "demo-reviewer", fixture.comment_body, range_position, false)
  root_note.reactions = {
    { name = "thumbsup", count = 2, users = { "demo-author", "demo-maintainer" } },
    { name = "heart", count = 1, users = { "demo-author" } },
  }
  local reply_note = note(4202, "demo-author",
    "Good idea. I'll keep search and visibility checks together in the helper.", range_position, false)
  reply_note.reactions = { { name = "thumbsup", count = 1, users = { "demo-reviewer" } } }
  local historical_position = vim.deepcopy(query_position)
  historical_position.head_sha = commits[1].id
  local outdated_note = note(4203, "demo-maintainer",
    "Maybe we could make the default query explicit.", historical_position, false)
  outdated_note.outdated = true
  local initial_discussions = {
    { id = "demo-filter", notes = { root_note, reply_note } },
    { id = "demo-outdated", notes = { outdated_note } },
    { id = "demo-resolved", notes = {
      note(4204, "demo-reviewer", "The empty query now behaves as expected. :thumbsup:", query_position, true),
    } },
  }

  local pipelines = {}
  for index_, entry in ipairs({ { 703, "running", head }, { 702, "success", commits[2].id },
      { 701, "failed", commits[1].id } }) do
    pipelines[index_] = {
      id = entry[1], project_id = 420, state = entry[2], sha = entry[3],
      ref = "demo-review", source = "merge_request_event",
      created_at = ("2026-10-29T09:0%d:00Z"):format(6 - index_),
      duration = index_ == 1 and 192 or 140,
      web_url = project_url .. "/-/pipelines/" .. entry[1],
    }
  end
  local jobs = {}
  for index_, entry in ipairs({
    { "manage instance", "create instance", "success", 42 },
    { "manage instance", "wake up instance", "manual" },
    { "test", "lint", "success", 12 },
    { "test", "unit tests", "running", 91 },
    { "test validation", "compare with main", "pending" },
    { "test validation", "integration checks", "failed", 83 },
    { "test validation", "validate models", "created" },
    { "stop and destroy instances", "destroy instance", "manual" },
  }) do
    local finished_at
    if entry[3] == "success" or entry[3] == "failed" then
      local seconds = 302 + entry[4]
      finished_at = ("2026-10-29T09:%02d:%02dZ"):format(math.floor(seconds / 60), seconds % 60)
    end
    jobs[index_] = {
      id = 8100 + index_, stage = entry[1], name = entry[2], state = entry[3], duration = entry[4],
      queued_duration = entry[4] and 2 or nil, runner = "demo-runner",
      allow_failure = entry[3] == "manual" or index_ == 6,
      failure_reason = index_ == 6 and "script_failure" or nil,
      created_at = "2026-10-29T09:05:00Z",
      started_at = entry[4] and "2026-10-29T09:05:02Z" or nil,
      finished_at = finished_at,
      web_url = project_url .. "/-/jobs/" .. (8100 + index_),
    }
  end
  local original = {
    mr = {
      iid = 42, title = "Add inbox filters and cover empty queries", web_url = demo_url,
      diff_refs = refs, head_pipeline = { id = 703, status = "running", web_url = pipelines[1].web_url },
      description = "A fictional inbox change for review.nvim screenshots.\n\n"
        .. "## Changes\n\n- Handle an empty query.\n- Filter unread messages.\n- Refresh the usage example.\n\n"
        .. "## Review checklist\n\n- [x] Keep message ordering stable.\n- [ ] Extract a reusable filter helper.",
    },
    commits = commits, diffs = diffs, discussions = initial_discussions,
    project = { id = 420, path_with_namespace = "demo/inbox", http_url_to_repo = project_url .. ".git" },
  }
  local function target_ok(target)
    assert(type(target) == "table" and target.url == demo_url and target.iid == 42
      and target.project == "demo/inbox", "Only the synthetic demo MR is available.")
  end
  local function refs_ok(value)
    assert(require("review.position").same_refs(value, refs), "Unexpected screenshot diff refs.")
  end
  function fixture.record(kind, value)
    fixture.actions[#fixture.actions + 1] = { kind = kind, value = vim.deepcopy(value) }
    if fixture.on_action then fixture.on_action() end
  end
  function fixture.reset()
    fixture.data, fixture.actions, fixture.next_note = vim.deepcopy(original), {}, 4300
    fixture.decision = "pending"
    if fixture.on_action then fixture.on_action() end
  end
  function fixture.load(target) target_ok(target); return vim.deepcopy(fixture.data) end
  function fixture.current(target) target_ok(target); return vim.deepcopy(fixture.data.mr) end
  function fixture.discussions(target) target_ok(target); return vim.deepcopy(fixture.data.discussions) end
  function fixture.status(target)
    target_ok(target)
    return {
      pipeline = { id = 703, state = "running", web_url = pipelines[1].web_url },
      review = { state = "changes_requested", approvals = fixture.decision == "approved" and 1 or 0,
        required = 2, reviewers = {
          { username = "demo-maintainer", state = "changes_requested" },
          { username = "demo-reviewer", state = fixture.decision },
        } },
    }
  end
  function fixture.pipelines(target) target_ok(target); return vim.deepcopy(pipelines) end
  function fixture.pipeline_details(target, pipeline)
    target_ok(target)
    assert(pipeline.project_id == 420, "Unexpected pipeline project.")
    for _, entry in ipairs(pipelines) do
      if entry.id == pipeline.id then
        local result = vim.deepcopy(entry)
        result.jobs = vim.deepcopy(jobs)
        if entry.id ~= 703 then
          for number, job in ipairs(result.jobs) do
            job.id = (entry.id == 702 and 8020 or 8010) + number
            job.web_url = project_url .. "/-/jobs/" .. job.id
            job.created_at = entry.created_at
            if job.state ~= "manual" then
              job.state = entry.id == 701 and number == 6 and "failed" or "success"
              job.allow_failure = false
              job.failure_reason = job.state == "failed" and "script_failure" or nil
              job.duration = job.duration or 20
              job.queued_duration = 2
              local seconds = tonumber(entry.created_at:match("T09:(%d+):")) * 60 + 2
              job.started_at = ("2026-10-29T09:%02d:%02dZ"):format(math.floor(seconds / 60), seconds % 60)
              seconds = seconds + job.duration
              job.finished_at = ("2026-10-29T09:%02d:%02dZ"):format(math.floor(seconds / 60), seconds % 60)
            end
          end
        end
        return result
      end
    end
    error("Unknown screenshot pipeline.")
  end
  function fixture.approve(target, value)
    target_ok(target); refs_ok(value)
    fixture.decision = "approved"
    fixture.record("approve", { head_sha = value.head_sha })
    return { approved = true }
  end
  function fixture.validate_request_changes(target) target_ok(target) end
  function fixture.request_changes(target, value)
    target_ok(target); refs_ok(value)
    fixture.decision = "changes_requested"
    fixture.record("request_changes", { head_sha = value.head_sha })
    return { iid = "42" }
  end
  local function find_discussion(id)
    for _, discussion in ipairs(fixture.data.discussions) do
      if discussion.id == id then return discussion end
    end
    error("Unknown screenshot conversation.")
  end
  function fixture.resolve(target, expected)
    target_ok(target)
    local discussion = find_discussion(expected.id)
    assert(vim.deep_equal(discussion.notes, expected.notes), "The fixture conversation changed.")
    local changed = require("review.providers.gitlab").can_resolve(discussion)
    for _, value in ipairs(discussion.notes) do if value.resolvable then value.resolved = true end end
    if changed then fixture.record("resolve", { discussion_id = discussion.id }) end
    return vim.deepcopy(discussion), changed
  end
  function fixture.validate_reply(target, draft)
    target_ok(target)
    local destination = assert(draft.reply, "Missing screenshot reply target.")
    local discussion = find_discussion(destination.discussion_id)
    assert(discussion.notes[1].id == destination.note_id, "Unexpected screenshot root note.")
  end
  function fixture.reply(target, draft)
    fixture.validate_reply(target, draft); refs_ok(draft.position)
    fixture.next_note = fixture.next_note + 1
    local discussion = find_discussion(draft.reply.discussion_id)
    local value = note(fixture.next_note, "demo-reviewer", draft.body,
      discussion.notes[1].position, discussion.notes[1].resolved)
    discussion.notes[#discussion.notes + 1] = value
    fixture.record("reply", { discussion_id = discussion.id, note_id = value.id })
    return vim.deepcopy(value)
  end
  function fixture.post(target, draft)
    target_ok(target); refs_ok(draft.position)
    assert(type(draft.body) == "string" and draft.body ~= "", "Missing screenshot comment.")
    local file
    for _, value in ipairs(diffs) do
      if value.old_path == draft.position.old_path and value.new_path == draft.position.new_path then file = value end
    end
    assert(file and type(draft.position.new_line or draft.position.old_line) == "number",
      "Unexpected screenshot comment position.")
    fixture.next_note = fixture.next_note + 1
    local discussion = { id = "demo-post-" .. fixture.next_note,
      notes = { note(fixture.next_note, "demo-reviewer", draft.body, draft.position, false) } }
    fixture.data.discussions[#fixture.data.discussions + 1] = discussion
    fixture.record("post", { discussion_id = discussion.id })
    return vim.deepcopy(discussion)
  end
  fixture.reset()
  return fixture
end

return M
