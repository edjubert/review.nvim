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

vim.fn.delete(root, "rf")
print(("%d passed, %d failed"):format(passed, failed))
if failed > 0 then vim.cmd("cquit 1") end
