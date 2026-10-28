-- Optional authenticated, read-only integration check. No write transport.
-- nvim --headless -u NONE -i NONE -l tests/smoke_read.lua URL [REPO]
vim.opt.runtimepath:prepend(vim.fn.getcwd())
local url, repo = arg[1], arg[2]
assert(url, "Pass a GitLab MR or GitHub PR URL.")
local plugin = require("review")
local target = assert(require("review.url").parse(url))
local provider = require("review.providers").for_target(target)
provider.post = function() error("Live publication is forbidden in this check.") end
local async = require("review.async")
local checked = async.checked
async.checked = function(argv, opts)
  for i, value in ipairs(argv) do
    if value == "--method" then assert(argv[i + 1] == "GET", "Only GET is allowed.") end
  end
  return checked(argv, opts)
end
local state = vim.fn.tempname()
plugin.setup({ repo = repo, state_dir = state, panel_width = 30 })
plugin._commands()
local ok, err = xpcall(function()
  plugin.open(url)
  local s = plugin.session
  local function wait(predicate)
    assert(vim.wait(60000, function() return s.error or predicate() end, 20), "Timed out")
    assert(not s.error, s.error)
  end
  wait(function() return s.ready and s.current end)
  local commit_count, file_views = #s.data.commits, 0
  for index, commit in ipairs(s.data.commits) do
    s:select_commit(index)
    wait(function() return s.current and s.current.head == commit.id end)
    local count = #s.files
    for file_index = 1, count do
      local path = s.files[file_index].new_path
      s:select_file(file_index)
      wait(function() return s.current and s.current.file.new_path == path end)
      file_views = file_views + 1
      if s.current.rows then
        assert(not vim.bo[s.viewer_buf].modifiable)
        assert(vim.api.nvim_buf_get_name(s.viewer_buf):match("^review://"))
      end
    end
  end
  s:select_commit(0)
  wait(function() return s.current and s.current.head == s.data.mr.diff_refs.head_sha end)
  local mr_file_count = #s.files
  local chosen
  for file_index = 1, #s.files do
    local path = s.files[file_index].new_path
    s:select_file(file_index)
    wait(function() return s.current and s.current.file.new_path == path end)
    if s.current.rows then
      for line, row in ipairs(s.current.rows) do
        if row.kind == "add" or row.kind == "delete" then
          chosen = { first = line, last = line }
          if s.current.rows[line + 1] and s.current.rows[line + 1].kind == row.kind then
            chosen.last = line + 1
          end
          break
        end
      end
    end
    if chosen then break end
  end
  assert(chosen, "No selectable changed text lines found.")
  vim.api.nvim_set_current_win(s.viewer_win)
  vim.cmd(("%d,%dReviewComment"):format(chosen.first, chosen.last))
  wait(function()
    local buf = vim.api.nvim_get_current_buf()
    return buf ~= s.viewer_buf and vim.bo[buf].buftype == "acwrite"
  end)
  local editor = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(editor, 0, -1, false, { "Local integration check; never publish." })
  vim.cmd.write()
  assert(#s.drafts == 1)
  assert(s.drafts[1].position.head_sha == s.data.mr.diff_refs.head_sha)
  if chosen.first ~= chosen.last then assert(s.drafts[1].position.line_range) end
  local persisted = require("review.drafts").load(s.config, s.target)
  assert(#persisted == 1)
  s:close()
  print(("Read-only smoke: %d commits, %d commit/file views, %d MR files; local comment/range saved. No POST.")
    :format(commit_count, file_views, mr_file_count))
end, debug.traceback)
vim.fn.delete(state, "rf")
if not ok then print(err); vim.cmd("cquit 1") end
