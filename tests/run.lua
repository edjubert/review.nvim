vim.opt.runtimepath:prepend(vim.fn.getcwd())
local passed, failed = 0, 0
local function test(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if ok then passed = passed + 1; print("ok " .. name)
  else failed = failed + 1; print("FAIL " .. name .. "\n" .. err) end
end
local function eq(actual, expected)
  assert(vim.deep_equal(actual, expected), "expected " .. vim.inspect(expected) .. ", got " .. vim.inspect(actual))
end
local function raises(fn, pattern)
  local ok, err = pcall(fn)
  assert(not ok, "expected an error")
  assert(tostring(err):find(pattern, 1, true), tostring(err))
end
local function run(fn)
  local done, result, err
  require("review.async").run(function() result = fn(); done = true end, function(e) err = e; done = true end)
  assert(vim.wait(10000, function() return done end, 10), "async operation timed out")
  assert(not err, err)
  return result
end

local url = require("review.url")
local diff = require("review.diff")
local position = require("review.position")
local sha1 = require("review.sha1")
local drafts = require("review.drafts")
local git = require("review.git")
local provider = require("review.providers.gitlab")
local Session = require("review.session")
local ui = require("review.ui")
local target = assert(url.parse("https://gitlab.example/group/nested/repo/-/merge_requests/12/commits?x=1"))
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
local config = { state_dir = root .. "/state", cache_dir = root .. "/cache", panel_width = 30 }
local refs = { base_sha = "base", start_sha = "start", head_sha = "head" }
local file = { old_path = "old.txt", new_path = "new.txt" }

test("nested MR URL, suffix and query", function()
  eq(target.project, "group/nested/repo")
  eq(target.iid, 12)
  eq(target.provider, "gitlab")
  eq(target.url, "https://gitlab.example/group/nested/repo/-/merge_requests/12")
  eq(url.encode("a/b c"), "a%2Fb%20c")
end)
test("reject malformed URLs and credential-bearing URLs", function()
  for _, value in ipairs({
    "file:///tmp/repo", "https://user:secret@gitlab.example/a/b/-/merge_requests/1",
    "https://gitlab.example/a/../b/-/merge_requests/1",
    "https://gitlab.example/a/b/-/merge_requests/1oops",
  }) do eq(url.parse(value), nil) end
end)
test("remote URL matching", function()
  assert(url.remote_matches("git@gitlab.example:group/nested/repo.git\n", target))
  assert(url.remote_matches("https://gitlab.example/group/nested/repo.git", target))
  assert(not url.remote_matches("git@elsewhere:group/nested/repo.git", target))
end)
test("SHA-1 standard vectors", function()
  eq(sha1(""), "da39a3ee5e6b4b0d3255bfef95601890afd80709")
  eq(sha1("abc"), "a9993e364706816aba3e25717850c26c9cd0d89d")
  eq(sha1(string.rep("a", 1000)), "291e9a6c66994949b57ba5e650361e98fc36b1ba")
end)
test("inline rows reconstruct both snapshots including boundary insertions", function()
  for _, pair in ipairs({
    { "", "" }, { "", "new\n" }, { "old\n", "" },
    { "a\nb\n", "z\na\nb\nx\n" },
    { "a\nb\nc\n", "a\nB\nc\n" },
    { "a\nb\nc\n", "a\nc\n" },
    { "a\n", "\na\n" }, { "\n", "" },
    { "a", "a\n" }, { "a\r\nb\r\n", "a\r\nB\r\n" },
  }) do
    local rows = assert(diff.build(pair[1], pair[2]))
    local before, after = {}, {}
    for _, row in ipairs(rows) do
      assert(row.text ~= nil)
      if row.old_line then eq(row.old_line, #before + 1); before[#before + 1] = row.text end
      if row.new_line then eq(row.new_line, #after + 1); after[#after + 1] = row.text end
    end
    eq(before, diff.lines(pair[1])); eq(after, diff.lines(pair[2]))
  end
end)
test("binary notice", function() eq(diff.build("a\0b", "text"), nil) end)
test("intraline highlights use UTF-8 byte offsets", function()
  local old, new = diff.spans("héllo world", "héllo person")
  assert(#old > 0 and #new > 0)
  for _, span in ipairs(old) do assert(span[1] >= 7 and span[2] <= #"héllo world") end
  for _, span in ipairs(new) do assert(span[1] >= 7 and span[2] <= #"héllo person") end
end)
test("unchanged-line mapping shifts positions and excludes rewritten lines", function()
  eq(diff.line_map("a\nb\nc\n", "x\na\nB\nc\n"), { [1] = 2, [3] = 4 })
end)
test("change navigation groups replacements and honors direction, count and boundaries", function()
  local rows = assert(diff.build("a\nb\nc\nd\ne\nf\n", "a\nB\nc\nd\nE\nf\n"))
  eq(diff.hunk_starts(rows), { 2, 6 })
  eq(diff.jump(rows, 1, 1), 2)
  eq(diff.jump(rows, 2, 1), 6)
  eq(diff.jump(rows, 3, -1), 2)
  eq(diff.jump(rows, 6, -1), 2)
  eq(diff.jump(rows, 1, 1, 2), 6)
  eq(diff.jump(rows, 6, 1), nil)
  eq(diff.jump(rows, 2, -1), nil)
  eq(diff.jump(rows, 1, 1, 3), nil)
  eq(diff.jump(assert(diff.build("same\n", "same\n")), 1, 1), nil)
end)
test("GitLab patch positions", function()
  local p = diff.patch("@@ -2,3 +2,4 @@\n same\n-old\n+new\n+extra\n tail\n")
  eq(p.by_old[3].kind, "delete")
  eq(p.by_new[3].kind, "add")
  eq(p.by_new[5].old_line, 4)
end)
test("single addition and deletion payloads omit the opposite side", function()
  local p = assert(position.build(refs, file, { { kind = "add", new_line = 4 } }))
  eq(p.old_line, nil); eq(p.new_line, 4); eq(p.head_sha, "head")
  p = assert(position.build(refs, file, { { kind = "delete", old_line = 3 } }))
  eq(p.new_line, nil); eq(p.old_line, 3)
end)
test("range payload includes filename SHA-1 and endpoint types", function()
  local patch = diff.patch("@@ -3,1 +3,3 @@\n same\n+line four\n+line five\n")
  local p = assert(position.build(refs, file, { patch.by_new[4], patch.by_new[5] }))
  eq(p.line_range.start.line_code, sha1("new.txt") .. "_4_4")
  eq(p.line_range["end"].line_code, sha1("new.txt") .. "_4_5")
  eq(p.line_range["end"].new_line, 5)
  eq(p.line_range.start.type, "new")
end)
test("deleted-line range retains the running new counter", function()
  local patch = diff.patch("@@ -3,3 +3,1 @@\n same\n-old four\n-old five\n")
  local p = assert(position.build(refs, file, { patch.by_old[4], patch.by_old[5] }))
  eq(p.line_range.start.line_code, sha1("new.txt") .. "_4_4")
  eq(p.line_range["end"].line_code, sha1("new.txt") .. "_5_4")
  eq(p.line_range["end"].new_line, nil)
end)
test("reject mixed-side and discontiguous ranges", function()
  eq(position.build(refs, file, {
    { kind = "delete", old_line = 1 }, { kind = "add", new_line = 1 },
  }), nil)
  eq(position.build(refs, file, {
    { kind = "add", new_line = 1 }, { kind = "add", new_line = 3 },
  }), nil)
end)
test("drafts survive restart with private file permissions", function()
  local list = { drafts.new("A comment\nwith a range", assert(position.build(refs, file, {
    { kind = "add", new_line = 4 },
  })), "commit") }
  drafts.save(config, target, list)
  eq(drafts.load(config, target), list)
  local paths = vim.fn.glob(config.state_dir .. "/drafts/*.json", false, true)
  eq(bit.band(vim.uv.fs_stat(paths[1]).mode, 511), 384)
  vim.fn.writefile({ "not-json" }, paths[1])
  raises(function() drafts.load(config, target) end, "preserved")
  drafts.save(config, target, {})
end)

test("API pagination consumes all pages", function()
  local original, calls = provider.request, 0
  provider.request = function()
    calls = calls + 1
    if calls == 1 then
      local list = {}; for i = 1, 100 do list[i] = { id = i } end; return list
    end
    return { { id = 101 } }
  end
  local result = provider.pages(target, "/test")
  provider.request = original
  eq(#result, 101); eq(calls, 2)
end)
test("write transport passes literal JSON through stdin", function()
  local async = require("review.async")
  local original, captured = async.checked, nil
  async.checked = function(argv, opts)
    captured = { argv = argv, body = vim.json.decode(opts.stdin) }
    return '{"id":"discussion"}'
  end
  local body = "Literal `$(command)` and\nnewlines"
  provider.post(target, { body = body, position = refs })
  async.checked = original
  eq(captured.body.body, body)
  eq(captured.argv[6], "POST")
  eq(captured.argv[#captured.argv], "-")
end)

local saved_content, saved_rename = git.content, git.rename_path
local function mapping_session()
  local s = Session.new(target, config)
  s.repo = "/explicit/real/repo"
  s.data = { mr = { diff_refs = refs }, diffs = {
    { old_path = "code.txt", new_path = "code.txt",
      diff = "@@ -1,2 +1,4 @@\n a\n+later\n+reviewed\n b\n" },
  } }
  s.current = {
    file = { old_path = "code.txt", new_path = "code.txt" },
    base = "parent", head = "early", old = "a\nb\n", new = "a\nreviewed\nb\n",
    rows = assert(diff.build("a\nb\n", "a\nreviewed\nb\n")),
  }
  git.rename_path = function(_, _, _, path) return path end
  git.content = function(_, sha)
    if sha == "head" then return "a\nlater\nreviewed\nb\n" end
    return "a\nb\n"
  end
  return s
end
test("early-commit line is attached to its current MR position", function()
  local s = mapping_session()
  local p = s:comment_position(s.current, 2, 2)
  eq(p.new_line, 3); eq(p.head_sha, "head")
  git.content, git.rename_path = saved_content, saved_rename
end)
test("rewritten historical lines are rejected", function()
  local s = mapping_session()
  git.content = function() return "a\nreplacement\nb\n" end
  raises(function() s:comment_position(s.current, 2, 2) end, "later commit")
  git.content, git.rename_path = saved_content, saved_rename
end)
test("saving a comment never calls the write transport", function()
  local original, calls = provider.post, 0
  provider.post = function() calls = calls + 1 end
  local s = Session.new(target, config)
  s:save_draft("local", assert(position.build(refs, file, { { kind = "add", new_line = 4 } })), "early")
  eq(#drafts.load(config, target), 1); eq(calls, 0)
  provider.post = original
  drafts.save(config, target, {})
end)
test("Ctrl-S persists the draft and closes the editor without publication", function()
  local original, calls = provider.post, 0
  provider.post = function() calls = calls + 1 end
  local s = Session.new(target, config)
  local p = assert(position.build(refs, file, { { kind = "add", new_line = 4 } }))
  local buf, win = ui.compose("Ctrl-S fixture", "", function(body) s:save_draft(body, p, "head") end)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Persist this draft" })
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("i<C-s>", true, false, true), "xt", false)
  eq(#drafts.load(config, target), 1)
  eq(drafts.load(config, target)[1].body, "Persist this draft")
  eq(vim.api.nvim_win_is_valid(win), false)
  eq(calls, 0)
  provider.post = original
  drafts.save(config, target, {})
end)

local original_select, original_document, original_notify = vim.ui.select, ui.document, vim.notify
local old_current, old_post, old_pages = provider.current, provider.post, provider.pages
ui.document = function() end
vim.notify = function() end
local function submission_session()
  local s = Session.new(target, config)
  s.ready = true
  s.data = { mr = { diff_refs = refs } }
  s.drafts = {
    drafts.new("first", assert(position.build(refs, file, { { kind = "add", new_line = 4 } })), "head"),
    drafts.new("second", assert(position.build(refs, file, { { kind = "add", new_line = 5 } })), "head"),
  }
  drafts.save(config, target, s.drafts)
  provider.current = function() return { diff_refs = refs } end
  provider.pages = function() return {} end
  return s
end
test("submission requires explicit publication choice", function()
  local s, calls = submission_session(), 0
  provider.post = function() calls = calls + 1; return { id = "ok" } end
  vim.ui.select = function(items, _, selected) selected(items[1]) end
  s:submit()
  eq(calls, 0); eq(#s.drafts, 2)
end)
test("partial submission preserves only remaining drafts and blocks ambiguous retry", function()
  local s, calls = submission_session(), 0
  provider.post = function()
    calls = calls + 1
    if calls == 2 then error("simulated connection loss") end
    return { id = "posted" }
  end
  vim.ui.select = function(items, _, selected) selected(items[2]) end
  s:submit()
  eq(calls, 2); eq(s.submitting, false); eq(#s.drafts, 1)
  eq(s.drafts[1].status, "uncertain")
  eq(#drafts.load(config, target), 1)
  s:submit(); eq(calls, 2)
end)
test("changed MR diff prevents publication", function()
  local s, calls = submission_session(), 0
  provider.current = function() return { diff_refs = { head_sha = "different" } } end
  provider.post = function() calls = calls + 1 end
  s:submit()
  eq(calls, 0); eq(#s.drafts, 2); eq(s.submitting, false)
end)
vim.ui.select, ui.document, vim.notify = original_select, original_document, original_notify
provider.current, provider.post, provider.pages = old_current, old_post, old_pages
drafts.save(config, target, {})

test("Git snapshot and rename loading use the explicit repository", function()
  local repo = root .. "/repo"
  local function command(args)
    local result = vim.system(args, { text = true }):wait()
    assert(result.code == 0, result.stderr)
    return vim.trim(result.stdout)
  end
  command({ "git", "init", "-b", "main", repo })
  command({ "git", "-C", repo, "config", "user.name", "Review Test" })
  command({ "git", "-C", repo, "config", "user.email", "review-test@example.invalid" })
  vim.fn.writefile({ "one", "two", "three" }, repo .. "/old name.txt")
  command({ "git", "-C", repo, "add", "." })
  command({ "git", "-C", repo, "commit", "-m", "base" })
  local base = command({ "git", "-C", repo, "rev-parse", "HEAD" })
  command({ "git", "-C", repo, "mv", "old name.txt", "new name.txt" })
  command({ "git", "-C", repo, "commit", "-m", "rename" })
  local head = command({ "git", "-C", repo, "rev-parse", "HEAD" })
  run(function()
    local files = git.files(repo, base, head)
    eq(#files, 1); eq(files[1].status, "R")
    eq(files[1].old_path, "old name.txt"); eq(files[1].new_path, "new name.txt")
    eq(git.content(repo, head, files[1].new_path), "one\ntwo\nthree\n")
  end)
end)
test("URL-only opening fetches into an isolated bare cache", function()
  local repo = root .. "/repo"
  local cache = config.cache_dir .. "/repos/" .. vim.fn.sha256(target.host .. "/" .. target.project)
  local clone_url = "git@gitlab.example:group/nested/repo.git"
  local function command(args)
    local result = vim.system(args, { text = true }):wait()
    assert(result.code == 0, result.stderr)
    return vim.trim(result.stdout)
  end
  local head = command({ "git", "-C", repo, "rev-parse", "HEAD" })
  command({ "git", "-C", repo, "update-ref", "refs/merge-requests/12/head", head })
  vim.fn.mkdir(cache, "p")
  command({ "git", "init", "--bare", cache })
  -- Redirect the test SSH URL to a local fixture; no real remote is contacted.
  command({ "git", "-C", cache, "config", "url.file://" .. repo .. ".insteadOf", clone_url })
  run(function()
    local fetched = git.prepare(target, { ssh_url_to_repo = clone_url }, config)
    eq(fetched, cache)
    assert(git.has(cache, head))
    eq(git.content(cache, head, "new name.txt"), "one\ntwo\nthree\n")
  end)
  eq(command({ "git", "-C", repo, "rev-parse", "HEAD" }), head)
end)
test("review buffers render selectable deleted rows and register comment mapping", function()
  local s = Session.new(target, config)
  s.data = { mr = { title = "Review fixture" }, commits = {} }
  ui.create(s)
  s.current = {
    file = { new_path = "test.lua" }, head = "abcd",
    rows = assert(diff.build("old\n", "new\n")),
  }
  ui.render(s, s.current)
  eq(vim.api.nvim_buf_get_lines(s.viewer_buf, 0, -1, false), { "old", "new" })
  eq(vim.bo[s.viewer_buf].modifiable, false)
  local maps = vim.api.nvim_buf_get_keymap(s.viewer_buf, "x")
  assert(not vim.iter(maps):any(function(map) return map.lhs == "gc" end))
  assert(vim.fn.maparg("<leader>rc", "x", false, true).buffer == 1)
  local selection
  s.comment = function(_, first, last) selection = { first, last } end
  local keys = "<Esc>ggVj" .. (vim.g.mapleader or "\\") .. "rc"
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "xt", false)
  eq(selection, { 1, 2 })
  s:close()
end)
test("sidebar footer stays at the bottom while scrolling and resizing", function()
  local s = Session.new(target, config)
  s.data = { mr = { title = "Colored tree" }, commits = {} }
  s.files, s.file_index = {}, 1
  for i = 1, 50 do
    s.files[i] = { status = i == 1 and "A" or "M", new_path = "directory/file-" .. i .. ".lua" }
  end
  ui.create(s)
  local hints = table.concat(vim.api.nvim_buf_get_lines(s.help_buf, 0, -1, false), "\n")
  assert(hints:find("gA complete MR", 1, true))
  assert(hints:find("<leader>rc comment line/range", 1, true))
  assert(hints:find("]h/[h", 1, true))
  local footer = vim.api.nvim_win_get_config(s.help_win)
  eq(footer.focusable, false)
  eq(footer.row + footer.height, vim.api.nvim_win_get_height(s.panel_win))
  vim.api.nvim_set_current_win(s.panel_win)
  vim.api.nvim_win_set_cursor(s.panel_win, { 45, 0 })
  vim.cmd.normal({ args = { "zz" }, bang = true })
  eq(vim.api.nvim_win_get_config(s.help_win).row, footer.row)
  vim.api.nvim_win_set_width(s.panel_win, 35)
  vim.api.nvim_exec_autocmds("WinResized", { modeline = false })
  eq(vim.api.nvim_win_get_config(s.help_win).width, vim.api.nvim_win_get_width(s.panel_win))
  eq(vim.api.nvim_get_hl(0, { name = "ReviewHelp", link = true }).link, "Comment")
  local marks = vim.api.nvim_buf_get_extmarks(s.panel_buf,
    vim.api.nvim_create_namespace("review.panel"), 0, -1, { details = true })
  local groups = {}
  for _, mark in ipairs(marks) do groups[mark[4].hl_group or mark[4].line_hl_group] = true end
  assert(groups.ReviewFileAdded and groups.ReviewDirectory and groups.ReviewSelected)
  local help_win = s.help_win
  s:close()
  eq(vim.api.nvim_win_is_valid(help_win), false)
end)
test("change shortcuts move focus to the diff and honor counts", function()
  local s = Session.new(target, config)
  s.data = { mr = { title = "Change shortcuts" }, commits = {} }
  ui.create(s)
  s.current = {
    file = { new_path = "test.lua" }, head = "abcd",
    rows = assert(diff.build("a\nb\nc\nd\ne\nf\n", "a\nB\nc\nd\nE\nf\n")),
  }
  ui.render(s, s.current)
  vim.api.nvim_set_current_win(s.panel_win)
  vim.api.nvim_feedkeys("]h", "xt", false)
  eq(vim.api.nvim_get_current_win(), s.viewer_win)
  eq(vim.api.nvim_win_get_cursor(s.viewer_win)[1], 2)
  vim.api.nvim_feedkeys("]h", "xt", false)
  eq(vim.api.nvim_win_get_cursor(s.viewer_win)[1], 6)
  vim.api.nvim_feedkeys("[h", "xt", false)
  eq(vim.api.nvim_win_get_cursor(s.viewer_win)[1], 2)
  vim.api.nvim_win_set_cursor(s.viewer_win, { 1, 0 })
  vim.api.nvim_feedkeys("2]h", "xt", false)
  eq(vim.api.nvim_win_get_cursor(s.viewer_win)[1], 6)
  s:close()
end)
test("comment shortcut can be customized or disabled without claiming gc", function()
  for _, key in ipairs({ "<leader>rC", false }) do
    local customized = vim.deepcopy(config)
    customized.keymaps = { comment = key }
    local s = Session.new(target, customized)
    s.data = { mr = { title = "Custom shortcut" }, commits = {} }
    ui.create(s)
    local maps = vim.api.nvim_buf_get_keymap(s.viewer_buf, "n")
    assert(not vim.iter(maps):any(function(map) return map.lhs == "gc" end))
    local hint = key or ":ReviewComment"
    local hints = table.concat(vim.api.nvim_buf_get_lines(s.help_buf, 0, -1, false), "\n")
    assert(hints:find(hint .. " comment line/range", 1, true))
    if key then assert(vim.fn.maparg(key, "n", false, true).buffer == 1) end
    s:close()
  end
end)
test("submit shortcut previews from either review window and keeps publication explicit", function()
  local select_before, document_before, post_before = vim.ui.select, ui.document, provider.post
  local previews, writes = 0, 0
  vim.ui.select = function(items, _, selected) selected(items[1]) end
  ui.document = function(_, lines)
    previews = previews + 1
    assert(table.concat(lines, "\n"):find("Shortcut draft", 1, true))
  end
  provider.post = function() writes = writes + 1; error("Unexpected write") end
  local s = Session.new(target, config)
  s.ready = true
  s.data = { mr = { title = "Submit shortcut", diff_refs = refs }, commits = {} }
  s.drafts = { drafts.new("Shortcut draft",
    assert(position.build(refs, file, { { kind = "add", new_line = 4 } })), "head") }
  ui.create(s)
  local hints = table.concat(vim.api.nvim_buf_get_lines(s.help_buf, 0, -1, false), "\n")
  assert(hints:find("<leader>rs submit", 1, true))
  for _, win in ipairs({ s.panel_win, s.viewer_win }) do
    vim.api.nvim_set_current_win(win)
    vim.api.nvim_feedkeys((vim.g.mapleader or "\\") .. "rs", "xt", false)
  end
  eq(previews, 2)
  eq(writes, 0)
  eq(#s.drafts, 1)
  s:close()
  vim.ui.select, ui.document, provider.post = select_before, document_before, post_before
end)

local function inline_fixture(opts)
  local s = Session.new(target, vim.tbl_deep_extend("force", config, opts or {}))
  s.ready, s.repo = true, "/explicit/inline/repo"
  local path = "code.lua"
  local function discussion(id, side, author, body)
    local p = {
      old_path = path, new_path = path, base_sha = refs.base_sha, head_sha = refs.head_sha,
      [side .. "_line"] = 3,
      line_range = { start = { [side .. "_line"] = 2 }, ["end"] = { [side .. "_line"] = 3 } },
    }
    return { id = id, notes = {
      { author = { username = author }, body = body, position = p },
    } }
  end
  local new = discussion("new", "new", "alice", "First message\nSecond line")
  new.notes[#new.notes + 1] = { system = true, body = "System event" }
  new.notes[#new.notes + 1] = { author = { username = "bob" }, body = "A reply" }
  local other_file = discussion("other-file", "new", "other", "Other file")
  other_file.notes[1].position.new_path = "other.lua"
  s.data = {
    mr = { title = "Inline discussions", diff_refs = refs },
    commits = { { id = "early", parent_ids = { "base" }, title = "Early commit" } },
    diffs = {
      { old_path = path, new_path = path,
        diff = "@@ -1,4 +1,4 @@\n one\n-old-a\n-old-b\n+new-a\n+new-b\n four\n" },
    },
    discussions = {
      new, discussion("old", "old", "carol", "Deleted range"),
      discussion("second", "new", "dave", "Another discussion"),
      { notes = { { author = { username = "general" }, body = "General comment" } } },
      other_file,
    },
  }
  s.base, s.head = refs.base_sha, refs.head_sha
  s.files, s.file_index = { { old_path = path, new_path = path, status = "M" } }, 1
  ui.create(s)
  s.current = {
    file = s.files[1], base = s.base, head = s.head,
    old = "one\nold-a\nold-b\nfour\n", new = "one\nnew-a\nnew-b\nfour\n",
  }
  s.current.rows = assert(diff.build(s.current.old, s.current.new))
  ui.render(s, s.current)
  return s
end

local function comment_marks(s)
  return vim.api.nvim_buf_get_extmarks(s.viewer_buf,
    vim.api.nvim_create_namespace("review.comments"), 0, -1, { details = true })
end
local function virtual_text(mark)
  local lines = {}
  for _, chunks in ipairs(mark[4].virt_lines or {}) do
    local parts = {}
    for _, chunk in ipairs(chunks) do parts[#parts + 1] = chunk[1] end
    lines[#lines + 1] = table.concat(parts)
  end
  return table.concat(lines, "\n")
end

test("inline discussions default to hidden and validate their configuration", function()
  local review = require("review")
  local before = vim.deepcopy(review.config)
  review.setup()
  eq(review.config.inline_comments, false)
  eq(review.config.keymaps.toggle_comments, "<leader>rt")
  raises(function() review.setup({ inline_comments = "yes" }) end, "must be a boolean")
  raises(function() review.setup({ keymaps = { toggle_comments = true } }) end, "toggle_comments")
  review.setup(before)
  local s = inline_fixture()
  eq(s.inline_comments, false)
  for _, mark in ipairs(comment_marks(s)) do eq(#(mark[4].virt_lines or {}), 0) end
  s:close()
end)

test("inline discussion ranges anchor on added and deleted lines with all replies", function()
  local s = inline_fixture({ inline_comments = true })
  local marks = comment_marks(s)
  eq(#marks, 2)
  eq(marks[1][2], 2) -- Last deleted line: old line 3, zero-based buffer row 2.
  eq(marks[2][2], 4) -- Last added line: new line 3, zero-based buffer row 4.
  local old, new = virtual_text(marks[1]), virtual_text(marks[2])
  assert(old:find("@carol", 1, true) and old:find("old 2–3", 1, true))
  assert(new:find("@alice", 1, true) and new:find("new 2–3", 1, true))
  assert(new:find("First message", 1, true) and new:find("@bob", 1, true))
  assert(new:find("A reply", 1, true) and new:find("@dave", 1, true))
  assert(not new:find("System event", 1, true))
  assert(not new:find("General comment", 1, true) and not new:find("Other file", 1, true))
  s:close()
end)

test("inline toggle keeps buffer positions, cursor, local drafts and transports unchanged", function()
  local review = require("review")
  local before = review.session
  local content, rename, request, post = git.content, git.rename_path, provider.request, provider.post
  local s = inline_fixture()
  s.drafts = { drafts.new("Local", assert(position.build(refs, s.current.file,
    { { kind = "add", new_line = 3 } })), "head") }
  ui.comments(s)
  git.content = function(_, sha) return sha == "head" and s.current.new or s.current.old end
  git.rename_path = function(_, _, _, path) return path end
  local reads, writes = 0, 0
  provider.request = function() reads = reads + 1; error("Unexpected request") end
  provider.post = function() writes = writes + 1; error("Unexpected write") end
  review.session = s
  review._commands()
  local lines = vim.api.nvim_buf_get_lines(s.viewer_buf, 0, -1, false)
  vim.api.nvim_win_set_cursor(s.viewer_win, { 5, 2 })
  local before_position = s:comment_position(s.current, 4, 5)
  vim.cmd.ReviewToggleComments()
  eq(s.inline_comments, true)
  eq(vim.api.nvim_win_get_cursor(s.viewer_win), { 5, 2 })
  eq(vim.api.nvim_buf_get_lines(s.viewer_buf, 0, -1, false), lines)
  eq(vim.bo[s.viewer_buf].modifiable, false)
  eq(s:comment_position(s.current, 4, 5), before_position)
  local marks = comment_marks(s)
  assert(marks[2][4].virt_text[1][1]:find("local draft", 1, true))
  assert(#marks[2][4].virt_lines > 0)
  local hints = table.concat(vim.api.nvim_buf_get_lines(s.help_buf, 0, -1, false), "\n")
  assert(hints:find("inline comments (on)", 1, true))
  vim.cmd.ReviewToggleComments()
  for _, mark in ipairs(comment_marks(s)) do eq(#(mark[4].virt_lines or {}), 0) end
  eq(reads, 0); eq(writes, 0); eq(#s.drafts, 1)
  s:close()
  review.session = before
  git.content, git.rename_path, provider.request, provider.post = content, rename, request, post
end)

test("inline comment shortcut toggles from both windows and can be customized or disabled", function()
  for _, key in ipairs({ "<leader>rt", "<leader>rT", false }) do
    local s = inline_fixture({ keymaps = { toggle_comments = key } })
    if key then
      for _, win in ipairs({ s.panel_win, s.viewer_win }) do
        vim.api.nvim_set_current_win(win)
        local mapping = vim.fn.maparg(key, "n", false, true)
        eq(mapping.buffer, 1)
        mapping.callback()
      end
      eq(s.inline_comments, false)
    else
      for _, buf in ipairs({ s.panel_buf, s.viewer_buf }) do
        local maps = vim.api.nvim_buf_get_keymap(buf, "n")
        assert(not vim.iter(maps):any(function(map)
          return map.desc == "Show or hide inline discussions"
        end))
      end
      local hints = table.concat(vim.api.nvim_buf_get_lines(s.help_buf, 0, -1, false), "\n")
      assert(hints:find(":ReviewToggleComments", 1, true))
      s:toggle_comments()
      eq(s.inline_comments, true)
    end
    s:close()
  end
end)

test("inline discussions wrap Unicode text and reflow on window resize", function()
  local s = inline_fixture({ inline_comments = true })
  local body = string.rep("é🙂界 long-word ", 8) .. "\tend"
  s.data.discussions = { s.data.discussions[1] }
  s.data.discussions[1].notes = { s.data.discussions[1].notes[1] }
  s.data.discussions[1].notes[1].body = body
  local counts = {}
  for _, width in ipairs({ 35, 60 }) do
    vim.api.nvim_win_set_width(s.viewer_win, width)
    vim.api.nvim_exec_autocmds("WinResized", { modeline = false })
    local marks = comment_marks(s)
    local parts = {}
    for _, chunks in ipairs(marks[1][4].virt_lines) do
      local text = ""
      for _, chunk in ipairs(chunks) do
        text = text .. chunk[1]
        if chunk[2] == "ReviewCommentBody" then parts[#parts + 1] = chunk[1] end
      end
      assert(vim.fn.strdisplaywidth(text) <= vim.api.nvim_win_get_width(s.viewer_win))
    end
    eq(table.concat(parts), body:gsub("\t", "    "))
    counts[#counts + 1] = #marks[1][4].virt_lines
  end
  assert(counts[1] > counts[2])
  s:close()
end)

test("inline discussion blocks use mapped commit lines and disappear for unavailable ranges", function()
  local s = inline_fixture({ inline_comments = true })
  s.data.discussions = { s.data.discussions[1] }
  local content, files = git.content, git.files
  local root_note = s.data.discussions[1].notes[1]
  root_note.position.new_line = 4
  root_note.position.line_range.start.new_line = 3
  root_note.position.line_range["end"].new_line = 4
  git.content = function() return "one\nlater\nnew-a\nnew-b\nfour\n" end
  git.files = function() return {} end
  s.current.head = "early"
  s:map_threads(s.current, s.generation)
  ui.comments(s)
  local marks = comment_marks(s)
  eq(#marks, 1); eq(marks[1][2], 4)
  assert(virtual_text(marks[1]):find("new 2–3", 1, true))
  s.current.new = "one\nrewritten\nnew-b\nfour\n"
  s.current.rows = assert(diff.build(s.current.old, s.current.new))
  s:map_threads(s.current, s.generation)
  ui.render(s, s.current)
  eq(#comment_marks(s), 0)
  s.current = { file = s.files[1], error = "Binary file" }
  ui.render(s, s.current)
  eq(#comment_marks(s), 0)
  s:close()
  git.content, git.files = content, files
end)

test("inline toggle survives file and commit navigation and successful or failed refreshes", function()
  local s = inline_fixture()
  local saved = {
    load = provider.load, current = provider.current,
    prepare = git.prepare, ensure = git.ensure, files = git.files, content = git.content,
  }
  local data, old, new = vim.deepcopy(s.data), s.current.old, s.current.new
  provider.load = function() return vim.deepcopy(data) end
  provider.current = function() return { diff_refs = refs } end
  git.prepare = function() return s.repo end
  git.ensure = function() end
  git.files = function()
    return {
      { old_path = "code.lua", new_path = "code.lua", status = "M" },
      { old_path = "other.lua", new_path = "other.lua", status = "M" },
    }
  end
  git.content = function(_, sha) return sha == refs.base_sha and old or new end
  local ok, err = xpcall(function()
    local function displayed(path, commit)
      assert(vim.wait(10000, function()
        return s.error or (s.current and s.current.file.new_path == path and s.commit_index == commit)
      end, 10))
      assert(not s.error, s.error)
      eq(s.inline_comments, true)
      assert(#comment_marks(s) > 0 and #comment_marks(s)[1][4].virt_lines > 0)
    end
    s:toggle_comments()
    s:select_commit(0)
    displayed("code.lua", 0)
    s:select_file(2)
    displayed("other.lua", 0)
    s:select_commit(1)
    displayed("code.lua", 1)
    s:refresh()
    displayed("code.lua", 1)
    s:select_commit(0)
    displayed("code.lua", 0)
    local lines = vim.api.nvim_buf_get_lines(s.viewer_buf, 0, -1, false)
    local blocks = comment_marks(s)
    provider.load = function() error("Simulated refresh failure") end
    s:refresh()
    assert(vim.wait(10000, function() return not s.refreshing end, 10))
    assert(s.error:find("Simulated refresh failure", 1, true))
    eq(s.inline_comments, true)
    eq(vim.api.nvim_buf_get_lines(s.viewer_buf, 0, -1, false), lines)
    eq(comment_marks(s), blocks)
  end, debug.traceback)
  s:close()
  provider.load, provider.current = saved.load, saved.current
  git.prepare, git.ensure, git.files, git.content = saved.prepare, saved.ensure, saved.files, saved.content
  assert(ok, err)
end)

local reply_serial = 0
local function reply_fixture(opts)
  reply_serial = reply_serial + 1
  local s = inline_fixture(vim.tbl_deep_extend("force",
    { state_dir = root .. "/reply-state-" .. reply_serial }, opts or {}))
  for index, discussion in ipairs(s.data.discussions) do
    local note = require("review.threads").root(discussion)
    if note then note.id = 100 + index end
  end
  return s
end

local function mocked(overrides, fn)
  local saved = {}
  for _, override in ipairs(overrides) do
    saved[#saved + 1] = { override[1], override[2], override[1][override[2]] }
    override[1][override[2]] = override[3]
  end
  local ok, err = xpcall(fn, debug.traceback)
  for _, original in ipairs(saved) do original[1][original[2]] = original[3] end
  assert(ok, err)
end

local function comment_url_fixture(opts)
  local s = reply_fixture(opts)
  for index, discussion in ipairs(s.data.discussions) do
    for note_index, note in ipairs(discussion.notes or {}) do
      if not note.system then
        note.id = note.id or 1000 + 10 * index + note_index
        note.web_url = target.url .. "#note_" .. note.id
      end
    end
  end
  return s
end

test("providers expose individual comment URLs, including replies and nullable API links", function()
  local github, codeberg = require("review.providers.github"), require("review.providers.codeberg")
  local gh_target = assert(url.parse("https://github.example/owner/repo/pull/7"))
  local cb_target = assert(url.parse("https://codeberg.org/owner/repo/pulls/8"))
  local gh_root, gh_reply = gh_target.url .. "#discussion_r42", gh_target.url .. "#discussion_r43"
  local cb_url = cb_target.url .. "#discussioncomment-52"
  mocked({
    { provider, "pages", function(_, endpoint)
      eq(endpoint, provider.mr_path(target) .. "/discussions")
      return { { notes = {
        { id = 41 }, { id = 42 }, { id = 43, system = true }, { id = vim.NIL },
      } } }
    end },
    { github, "pages", function(_, endpoint)
      eq(endpoint, github.pr_path(gh_target) .. "/comments")
      return {
        { id = 43, in_reply_to_id = 42, html_url = gh_reply },
        { id = 42, html_url = gh_root },
        { id = 44, html_url = vim.NIL },
      }
    end },
    { codeberg, "pages", function(_, endpoint)
      eq(endpoint, codeberg.pr_path(cb_target) .. "/reviews")
      return { { id = 5, state = "COMMENT", comments_count = 2 } }
    end },
    { codeberg, "request", function(_, endpoint, body)
      eq(body, nil); eq(endpoint, codeberg.pr_path(cb_target) .. "/reviews/5/comments")
      return { { id = 52, html_url = cb_url }, { id = 53, html_url = vim.NIL } }
    end },
  }, function()
    local gl_notes = provider.discussions(target)[1].notes
    eq(gl_notes[1].web_url, target.url .. "#note_41")
    eq(gl_notes[2].web_url, target.url .. "#note_42")
    eq(gl_notes[3].web_url, nil); eq(gl_notes[4].web_url, nil)
    local gh = github.discussions(gh_target, refs, {})
    eq(gh[1].notes[1].web_url, gh_root); eq(gh[1].notes[2].web_url, gh_reply)
    eq(gh[2].notes[1].web_url, nil)
    local cb = codeberg.discussions(cb_target, refs, {})
    eq(cb[1].notes[1].web_url, cb_url); eq(cb[2].notes[1].web_url, nil)
  end)
end)

test("ReviewOpenComment opens old/new range comments without API requests or draft changes", function()
  local s, review = comment_url_fixture(), require("review")
  local new, old = s.data.discussions[1], s.data.discussions[2]
  s.data.discussions = { new, old }
  s.drafts = { drafts.new("Keep local", vim.deepcopy(new.notes[1].position), "head") }
  local before, opened = vim.deepcopy(s.drafts), {}
  mocked({
    { review, "session", s },
    { provider, "request", function() error("Opening a comment must not request the API") end },
    { vim.ui, "open", function(value) opened[#opened + 1] = value; return {} end },
  }, function()
    review._commands()
    for _, row in ipairs({ 2, 3, 4, 5 }) do
      vim.api.nvim_win_set_cursor(s.viewer_win, { row, 0 })
      vim.cmd.ReviewOpenComment()
    end
    eq(opened, { old.notes[1].web_url, old.notes[1].web_url, new.notes[1].web_url, new.notes[1].web_url })
    eq(vim.api.nvim_get_current_win(), s.viewer_win)
    eq(s.drafts, before)
  end)
  s:close()
end)

test("opening overlapping discussions supports selection, cancellation and stale-session guards", function()
  local s, opened, pending = comment_url_fixture(), {}
  mocked({
    { vim.ui, "open", function(value) opened[#opened + 1] = value; return {} end },
    { vim.ui, "select", function(items, opts, selected)
      eq(opts.prompt, "Open which discussion in the browser?")
      eq(#items, 2)
      assert(opts.format_item(items[2]):find("@dave", 1, true))
      pending = selected
    end },
  }, function()
    vim.api.nvim_win_set_cursor(s.viewer_win, { 4, 0 })
    s:open_comment()
    eq(#opened, 0)
    pending(nil)
    eq(#opened, 0)
    s:open_comment()
    pending(s.data.discussions[3])
    eq(opened, { s.data.discussions[3].notes[1].web_url })
    s:open_comment()
    s.generation = s.generation + 1
    pending(s.data.discussions[1])
    eq(#opened, 1)
    s:open_comment()
    s:close()
    pending(s.data.discussions[1])
    eq(#opened, 1)
  end)
end)

test("comment URLs follow discussions mapped into an individual commit view", function()
  local s, opened = comment_url_fixture()
  local discussion, original = s.data.discussions[1], s.current.new
  s.data.discussions = { discussion }
  s.current.head, s.current.new = "early", "zero\n" .. original
  s.current.rows = assert(diff.build(s.current.old, s.current.new))
  mocked({
    { git, "files", function(repo) eq(repo, s.repo); return {} end },
    { git, "content", function(repo, sha)
      eq(repo, s.repo); eq(sha, refs.head_sha); return original
    end },
    { vim.ui, "open", function(value) opened = value; return {} end },
  }, function()
    s:map_threads(s.current, s.generation)
    ui.render(s, s.current)
    for row, entry in ipairs(s.current.rows) do
      if entry.new_line == 3 then vim.api.nvim_win_set_cursor(s.viewer_win, { row, 0 }); break end
    end
    s:open_comment()
    eq(opened, discussion.notes[1].web_url)
  end)
  s:close()
end)

test("discussion windows open the exact reply or general comment and retain Enter navigation", function()
  local s, review, opened = comment_url_fixture(), require("review"), {}
  local discussion, general = s.data.discussions[1], s.data.discussions[4]
  discussion.notes[1].resolved = true
  mocked({
    { review, "session", s },
    { vim.ui, "open", function(value) opened[#opened + 1] = value; return {} end },
  }, function()
    review._commands()
    s:show_threads({ discussion })
    local buf, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
    vim.cmd.ReviewOpenComment() -- Discussion heading opens its root.
    local reply_row
    for row, text in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
      if text == "A reply" then reply_row = row; break end
    end
    assert(reply_row)
    vim.api.nvim_win_set_cursor(win, { reply_row, 0 })
    vim.cmd.ReviewOpenComment()
    vim.api.nvim_win_set_cursor(win, { reply_row - 1, 0 }) -- Reply author heading.
    vim.fn.maparg("<leader>ro", "n", false, true).callback()
    s:show_threads({ general })
    local general_buf, general_win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
    vim.cmd.ReviewOpenComment()
    eq(opened, {
      discussion.notes[1].web_url, discussion.notes[3].web_url,
      discussion.notes[3].web_url, general.notes[1].web_url,
    })
    vim.api.nvim_win_close(general_win, true)
    eq(s.thread_documents[general_buf], nil)
    vim.api.nvim_set_current_win(win)
    vim.fn.maparg("<CR>", "n", false, true).callback()
    eq(s.thread_documents[buf], nil)
    eq(vim.api.nvim_get_current_win(), s.viewer_win)
    eq(vim.api.nvim_win_get_cursor(s.viewer_win)[1], 5)
  end)
  s:close()
end)

test("comment opening reports missing links, invalid contexts and browser launch errors", function()
  local s, review, messages, opened = comment_url_fixture(), require("review"), {}, 0
  s.data.discussions = { s.data.discussions[1] }
  local note = s.data.discussions[1].notes[1]
  mocked({
    { review, "session", s },
    { vim, "notify", function(message) messages[#messages + 1] = message end },
    { vim.ui, "open", function() opened = opened + 1; return nil, "No browser handler" end },
  }, function()
    review._commands()
    vim.api.nvim_win_set_cursor(s.viewer_win, { 1, 0 })
    vim.cmd.ReviewOpenComment()
    assert(messages[#messages]:find("No discussion", 1, true))
    vim.api.nvim_win_set_cursor(s.viewer_win, { 4, 0 })
    for _, value in ipairs({ false, vim.NIL, "", "file:///tmp/comment", "https://example/\ncomment" }) do
      note.web_url = value
      vim.cmd.ReviewOpenComment()
      assert(messages[#messages]:find("No URL", 1, true))
    end
    note.web_url = nil
    vim.cmd.ReviewOpenComment()
    eq(opened, 0)
    note.web_url = target.url .. "#note_101"
    vim.cmd.ReviewOpenComment()
    assert(messages[#messages]:find("No browser handler", 1, true))
    mocked({ { vim.ui, "open", function() error("Browser spawn failed") end } }, function()
      vim.cmd.ReviewOpenComment()
      assert(messages[#messages]:find("Browser spawn failed", 1, true))
    end)
    vim.api.nvim_set_current_win(s.panel_win)
    vim.cmd.ReviewOpenComment()
    assert(messages[#messages]:find("commented diff line or in a discussion window", 1, true))
    s:show_threads({})
    vim.cmd.ReviewOpenComment()
    assert(messages[#messages]:find("No comment under the cursor", 1, true))
    vim.api.nvim_win_close(vim.api.nvim_get_current_win(), true)
    mocked({ { review, "session", false } }, function()
      vim.cmd.ReviewOpenComment()
      assert(messages[#messages]:find("Open a review", 1, true))
    end)
    eq(opened, 1); eq(#s.drafts, 0)
  end)
  s:close()
end)

test("comment browser shortcut is configurable in diff and discussion buffers and can be disabled", function()
  local review, before = require("review"), vim.deepcopy(require("review").config)
  review.setup()
  eq(review.config.keymaps.open_comment, "<leader>ro")
  raises(function() review.setup({ keymaps = { open_comment = true } }) end, "keymaps.open_comment")
  review.setup(before)
  for _, key in ipairs({ "<leader>ro", "<leader>rO", false }) do
    local s, opened = comment_url_fixture({ keymaps = { open_comment = key } }), 0
    s.data.discussions = { s.data.discussions[1] }
    mocked({
      { review, "session", s },
      { vim.ui, "open", function() opened = opened + 1; return {} end },
    }, function()
      vim.api.nvim_win_set_cursor(s.viewer_win, { 4, 0 })
      local hints = table.concat(vim.api.nvim_buf_get_lines(s.help_buf, 0, -1, false), "\n")
      assert(hints:find((key or ":ReviewOpenComment") .. " open comment URL", 1, true))
      local function check_mapping()
        if key then
          local mapping = vim.fn.maparg(key, "n", false, true)
          eq(mapping.buffer, 1)
          mapping.callback()
        else
          local maps = vim.api.nvim_buf_get_keymap(vim.api.nvim_get_current_buf(), "n")
          assert(not vim.iter(maps):any(function(map) return map.desc == "Open this comment in the browser" end))
          vim.cmd.ReviewOpenComment()
        end
      end
      check_mapping()
      local maps = vim.api.nvim_buf_get_keymap(s.panel_buf, "n")
      assert(not vim.iter(maps):any(function(map) return map.desc == "Open this comment in the browser" end))
      s:show_threads()
      check_mapping()
      eq(opened, 2)
      vim.api.nvim_win_close(vim.api.nvim_get_current_win(), true)
    end)
    s:close()
  end
end)

test("ReviewReply saves a persistent local reply from any line in a commented range", function()
  local s, review = reply_fixture(), require("review")
  s.data.discussions = { s.data.discussions[1] }
  local reads, writes = 0, 0
  mocked({
    { review, "session", s },
    { provider, "request", function() reads = reads + 1; error("Unexpected request") end },
    { provider, "reply", function() writes = writes + 1; error("Unexpected write") end },
  }, function()
    review._commands()
    vim.api.nvim_win_set_cursor(s.viewer_win, { 4, 0 }) -- First line of the new-side range.
    vim.cmd.ReviewReply()
    local editor = vim.api.nvim_get_current_buf()
    eq(vim.bo[editor].buftype, "acwrite")
    vim.api.nvim_buf_set_lines(editor, 0, -1, false, { "A local reply", "with two lines" })
    vim.cmd.write()
    eq(reads, 0); eq(writes, 0); eq(#s.drafts, 1)
    local draft = s.drafts[1]
    eq(draft.reply.discussion_id, "new"); eq(draft.reply.note_id, 101)
    eq(draft.reply.author, "alice"); eq(draft.body, "A local reply\nwith two lines")
    eq(draft.display.new_line, 3)
    eq(draft.position.head_sha, refs.head_sha)
    eq(drafts.load(s.config, s.target), s.drafts)
    assert(comment_marks(s)[1][4].virt_text[1][1]:find("local reply", 1, true))
    local restarted = Session.new(target, s.config)
    eq(restarted.drafts[1].reply, draft.reply)
  end)
  s:close()
end)

test("ReviewReply chooses among overlapping threads, supports deletions and ignores stale selections", function()
  local s = reply_fixture()
  local composer, pending
  mocked({
    { ui, "compose", function(title, _, saved) composer = { title = title, save = saved } end },
    { vim.ui, "select", function(items, opts, selected)
      eq(opts.prompt, "Reply to which discussion?")
      eq(#items, 2)
      assert(opts.format_item(items[2]):find("@dave", 1, true))
      pending = function() selected(items[2]) end
    end },
  }, function()
    vim.api.nvim_win_set_cursor(s.viewer_win, { 4, 0 })
    s:reply()
    eq(composer, nil)
    pending()
    assert(composer.title:find("@dave", 1, true))
    composer.save("Selected reply")
    eq(s.drafts[1].reply.discussion_id, "second")
    eq(s.drafts[1].reply.note_id, 103)
    composer = nil
    s:reply()
    s.generation = s.generation + 1
    pending()
    eq(composer, nil)
    vim.api.nvim_win_set_cursor(s.viewer_win, { 2, 0 }) -- First deleted line in old-side range.
    s:reply()
    assert(composer.title:find("@carol", 1, true))
    composer.save("Deleted-side reply")
    eq(s.drafts[2].reply.discussion_id, "old")
    eq(s.drafts[2].display.old_line, 3)
  end)
  s:close()
end)

test("reply shortcut is configurable, diff-only, and cancellation leaves no draft", function()
  for _, key in ipairs({ "<leader>rR", "<leader>rp", false }) do
    local s = reply_fixture({ keymaps = { reply = key } })
    s.data.discussions = { s.data.discussions[1] }
    vim.api.nvim_win_set_cursor(s.viewer_win, { 4, 0 })
    if key then
      local mapping = vim.fn.maparg(key, "n", false, true)
      eq(mapping.buffer, 1)
      mapping.callback()
      eq(vim.bo[vim.api.nvim_get_current_buf()].buftype, "acwrite")
      vim.api.nvim_win_close(vim.api.nvim_get_current_win(), true)
    else
      local maps = vim.api.nvim_buf_get_keymap(s.viewer_buf, "n")
      assert(not vim.iter(maps):any(function(map) return map.desc == "Draft a reply to this discussion" end))
      local hints = table.concat(vim.api.nvim_buf_get_lines(s.help_buf, 0, -1, false), "\n")
      assert(hints:find(":ReviewReply", 1, true))
    end
    local maps = vim.api.nvim_buf_get_keymap(s.panel_buf, "n")
    assert(not vim.iter(maps):any(function(map) return map.desc == "Draft a reply to this discussion" end))
    eq(#s.drafts, 0)
    s:close()
  end
end)

test("reply commands reject empty lines, unavailable root IDs and unsupported providers", function()
  local s = reply_fixture()
  local messages, editors = {}, 0
  mocked({
    { vim, "notify", function(message) messages[#messages + 1] = message end },
    { ui, "compose", function() editors = editors + 1 end },
  }, function()
    vim.api.nvim_win_set_cursor(s.viewer_win, { 1, 0 })
    s:reply()
    assert(messages[#messages]:find("No discussion", 1, true))
    s.data.discussions = { s.data.discussions[1] }
    s.data.discussions[1].notes[1].id = nil
    vim.api.nvim_win_set_cursor(s.viewer_win, { 4, 0 })
    s:reply()
    assert(messages[#messages]:find("root comment ID", 1, true))
    s.provider = require("review.providers.codeberg")
    s:reply()
    assert(messages[#messages]:find("not supported", 1, true))
    eq(editors, 0); eq(#s.drafts, 0)
  end)
  s:close()
end)

test("GitLab and GitHub replies use existing thread endpoints with body-only payloads", function()
  local github = require("review.providers.github")
  local gh_target = assert(url.parse("https://github.com/owner/repo/pull/7"))
  local body = "Literal `$(command)`\nand Markdown"
  local gl_reply = assert(provider.reply_target({ id = "thread/id", notes = { { id = 41 } } }))
  local gh_reply = assert(github.reply_target({ id = 42, notes = { { id = 42 } } }))
  local calls = {}
  mocked({
    { provider, "request", function(_, endpoint, payload)
      calls[#calls + 1] = { endpoint = endpoint, body = payload }
      if payload then return { id = 51 } end
      return { id = "thread/id", notes = { { id = 41, system = false } } }
    end },
    { github, "request", function(_, endpoint, payload)
      calls[#calls + 1] = { endpoint = endpoint, body = payload }
      if payload then return { id = 52, in_reply_to_id = 42 } end
      return { id = 42, in_reply_to_id = vim.NIL,
        pull_request_url = "https://api.github.com/repos/owner/repo/pulls/7" }
    end },
  }, function()
    provider.validate_reply(target, { reply = gl_reply })
    provider.reply(target, { reply = gl_reply, body = body })
    github.validate_reply(gh_target, { reply = gh_reply })
    github.reply(gh_target, { reply = gh_reply, body = body })
    eq(calls[1].endpoint, provider.mr_path(target) .. "/discussions/thread%2Fid")
    eq(calls[2].endpoint, calls[1].endpoint .. "/notes")
    eq(calls[2].body, { body = body })
    eq(calls[3].endpoint, "repos/owner/repo/pulls/comments/42")
    eq(calls[4].endpoint, "repos/owner/repo/pulls/7/comments/42/replies")
    eq(calls[4].body, { body = body })
  end)
  eq(github.reply_target({ id = 42, notes = { { id = 43 } } }), nil)
  raises(function() github.reply(gh_target, { reply = { note_id = "42", discussion_id = 42 } }) end,
    "no valid GitHub")
end)

test("GitHub range discussions preserve their root ID for replies from any range line", function()
  local github = require("review.providers.github")
  local gh_target = assert(url.parse("https://github.com/owner/repo/pull/7"))
  mocked({
    { github, "pages", function()
      return {
        { id = 43, in_reply_to_id = 42, path = "code.lua", side = "RIGHT", line = 3,
          commit_id = "head", body = "Reply" },
        { id = 42, path = "code.lua", side = "RIGHT", start_side = "RIGHT", start_line = 2, line = 3,
          commit_id = "head", body = "Root" },
      }
    end },
  }, function()
    local discussions = github.discussions(gh_target, refs, {})
    eq(#discussions, 1); eq(discussions[1].notes[1].id, 42)
    eq(github.reply_target(discussions[1]).note_id, 42)
    local current = { head = "head", base = "base", file = { new_path = "code.lua" },
      rows = { { new_line = 1 }, { new_line = 2 }, { new_line = 3 } } }
    assert(require("review.threads").contains(discussions[1], current, 2))
    assert(require("review.threads").contains(discussions[1], current, 3))
  end)
end)

test("explicit submission previews reply context and publishes to the selected thread only", function()
  local s = reply_fixture()
  local reply = assert(provider.reply_target(s.data.discussions[1]))
  reply.author, reply.body = "alice", "Original comment"
  s.drafts = { drafts.new("My reply", vim.tbl_extend("force",
    vim.deepcopy(s.data.discussions[1].notes[1].position), refs), "head", nil, reply) }
  drafts.save(s.config, s.target, s.drafts)
  local requests, choice, preview = {}, 1
  mocked({
    { vim, "notify", function() end },
    { vim.ui, "select", function(items, _, selected) selected(items[choice]) end },
    { ui, "document", function(_, lines) preview = table.concat(lines, "\n") end },
    { provider, "current", function() return { diff_refs = refs } end },
    { provider, "discussions", function() return s.data.discussions end },
    { provider, "post", function() error("A reply must never create a new discussion") end },
    { provider, "request", function(_, endpoint, body)
      requests[#requests + 1] = { endpoint = endpoint, body = body }
      if body then return { id = 201 } end
      return { id = "new", notes = { { id = 101, system = false } } }
    end },
  }, function()
    s:submit()
    eq(#requests, 0); eq(#s.drafts, 1)
    assert(preview:find("Reply to @alice", 1, true) and preview:find("> Original comment", 1, true))
    assert(preview:find("My reply", 1, true))
    choice = 2
    s:submit()
    eq(#requests, 2)
    eq(requests[2].endpoint, provider.mr_path(target) .. "/discussions/new/notes")
    eq(requests[2].body, { body = "My reply" })
    eq(#s.drafts, 0); eq(#drafts.load(s.config, s.target), 0)
  end)
  s:close()
end)

test("missing or mismatched reply targets block publication before any write", function()
  local s = reply_fixture()
  local reply = assert(provider.reply_target(s.data.discussions[1]))
  s.drafts = { drafts.new("My reply", vim.deepcopy(refs), "head", nil, reply) }
  drafts.save(s.config, s.target, s.drafts)
  local writes = 0
  mocked({
    { vim, "notify", function() end },
    { vim.ui, "select", function(items, _, selected) selected(items[2]) end },
    { ui, "document", function() end },
    { provider, "current", function() return { diff_refs = refs } end },
    { provider, "request", function(_, _, body)
      if body then writes = writes + 1 end
      return { id = "new", notes = { { id = 999 } } }
    end },
  }, function()
    s.drafts[1].position.new_path, s.drafts[1].position.new_line = "code.lua", 3
    s:submit()
    eq(writes, 0); eq(s.submitting, false)
    eq(s.drafts[1].status, nil)
    eq(drafts.load(s.config, s.target)[1].reply, reply)
    assert(s.error:find("no longer available", 1, true))
  end)
  s:close()
  local github = require("review.providers.github")
  local gh_target = assert(url.parse("https://github.com/owner/repo/pull/7"))
  mocked({
    { github, "request", function()
      return { id = 42, pull_request_url = "https://api.github.com/repos/owner/repo/pulls/8" }
    end },
  }, function()
    raises(function() github.validate_reply(gh_target, { reply = { discussion_id = 42, note_id = 42 } }) end,
      "no longer available in this PR")
  end)
end)

test("reply drafts remove nullable API fields before saving or previewing", function()
  local s = reply_fixture()
  s.data.discussions = { s.data.discussions[1] }
  local p = s.data.discussions[1].notes[1].position
  p.old_line, p.line_range = vim.NIL, vim.NIL
  local save
  mocked({
    { ui, "compose", function(_, _, saved) save = saved end },
    { ui, "document", function(_, lines)
      local text = table.concat(lines, "\n")
      assert(text:find("code.lua:3", 1, true) and not text:find("vim.NIL", 1, true))
    end },
    { vim.ui, "select", function(items, _, selected) selected(items[1]) end },
    { provider, "reply", function() error("Unexpected publication") end },
  }, function()
    vim.api.nvim_win_set_cursor(s.viewer_win, { 5, 0 })
    s:reply()
    assert(save)
    save("Reply with a nullable API position")
    eq(s.drafts[1].position.line_range, nil)
    eq(s.drafts[1].position.old_line, nil)
    eq(p.line_range, vim.NIL) -- Cleaning a draft must not mutate provider metadata.
    s:submit()
    eq(#s.drafts, 1)
  end)
  s:close()
end)

test("legacy JSON null fields reload safely and preserve single-line and range publication", function()
  local s = reply_fixture()
  local null = vim.NIL
  local new = vim.tbl_extend("force", refs, {
    position_type = "text", old_path = "code.lua", new_path = "code.lua",
    old_line = null, new_line = 3, line_range = null,
  })
  local old = vim.tbl_extend("force", refs, {
    position_type = "text", old_path = "code.lua", new_path = "code.lua",
    old_line = 3, new_line = null, line_range = null,
  })
  local ranged = vim.deepcopy(old)
  ranged.line_range = {
    start = { old_line = 2, new_line = null, type = "old" },
    ["end"] = { old_line = 3, new_line = null, type = "old" },
  }
  local list = {
    { id = "new", body = "New-side draft", position = new, display = null, reply = null, status = null },
    { id = "old", body = "Old-side draft", position = old, display = null, reply = null },
    { id = "range", body = "Range reply", position = ranged, display = null,
      reply = { discussion_id = "old", note_id = 102, author = "carol", body = "Original comment" } },
  }
  -- Simulate existing files written before nullable fields were normalized.
  drafts.save(s.config, s.target, list)
  s.drafts = drafts.load(s.config, s.target)
  eq(#s.drafts, 3)
  eq(s.drafts[1].reply, nil); eq(s.drafts[1].display, nil); eq(s.drafts[1].position.line_range, nil)
  eq(s.drafts[2].position.new_line, nil)
  eq(s.drafts[3].position.line_range.start.new_line, nil)
  local posts, replies, choice = {}, {}, 1
  mocked({
    { vim, "notify", function() end },
    { ui, "document", function(_, lines)
      local text = table.concat(lines, "\n")
      assert(text:find("code.lua:2–3", 1, true) and not text:find("vim.NIL", 1, true))
    end },
    { vim.ui, "select", function(items, _, selected) selected(items[choice]) end },
    { provider, "current", function() return { diff_refs = refs } end },
    { provider, "discussions", function() return {} end },
    { provider, "validate_reply", function(_, draft) eq(draft.reply.note_id, 102) end },
    { provider, "post", function(_, draft)
      posts[#posts + 1] = vim.deepcopy(draft)
      return { id = "posted" }
    end },
    { provider, "reply", function(_, draft)
      replies[#replies + 1] = vim.deepcopy(draft)
      return { id = 201 }
    end },
  }, function()
    ui.comments(s)
    s:submit()
    eq(#posts, 0); eq(#replies, 0); eq(#s.drafts, 3)
    choice = 2
    s:submit()
    eq(#posts, 2); eq(#replies, 1)
    eq(posts[1].position.new_line, 3); eq(posts[1].position.old_line, nil)
    eq(posts[2].position.old_line, 3); eq(posts[2].position.new_line, nil)
    eq(replies[1].position.line_range.start.old_line, 2)
    eq(#s.drafts, 0); eq(#drafts.load(s.config, s.target), 0)
  end)
  s:close()
end)

test("partial reply publication preserves the remaining target and blocks ambiguous retry", function()
  local s = reply_fixture()
  s.drafts = {}
  for _, index in ipairs({ 1, 2 }) do
    local reply = assert(provider.reply_target(s.data.discussions[index]))
    local p = vim.tbl_extend("force", vim.deepcopy(s.data.discussions[index].notes[1].position), refs)
    s.drafts[#s.drafts + 1] = drafts.new("Reply " .. index, p, "head", nil, reply)
  end
  drafts.save(s.config, s.target, s.drafts)
  local writes = 0
  mocked({
    { vim, "notify", function() end },
    { vim.ui, "select", function(items, _, selected) selected(items[2]) end },
    { ui, "document", function() end },
    { provider, "current", function() return { diff_refs = refs } end },
    { provider, "request", function(_, endpoint, body)
      if not body then
        local id = endpoint:match("/discussions/(.+)$")
        return { id = id, notes = { { id = id == "new" and 101 or 102 } } }
      end
      writes = writes + 1
      if writes == 2 then error("Simulated reply connection loss") end
      return { id = 201 }
    end },
  }, function()
    s:submit()
    eq(writes, 2); eq(#s.drafts, 1); eq(s.submitting, false)
    eq(s.drafts[1].reply.discussion_id, "old")
    eq(s.drafts[1].reply.note_id, 102)
    eq(s.drafts[1].status, "uncertain")
    eq(drafts.load(s.config, s.target), s.drafts)
    s:submit()
    eq(writes, 2)
  end)
  s:close()
end)

vim.fn.delete(root, "rf")
print(("%d passed, %d failed"):format(passed, failed))
if failed > 0 then vim.cmd("cquit 1") end
