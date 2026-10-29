-- Run in a fresh Neovim session with :luafile or nvim -c 'luafile ...'.
assert(vim.fn.has("nvim-0.11") == 1, "Screenshot mode requires Neovim 0.11+.")
assert(not vim.g.review_screenshot_root, "Start a fresh Neovim session to reload screenshot mode.")
local script = debug.getinfo(1, "S").source:sub(2)
local plugin_dir = vim.fn.fnamemodify(script, ":p:h:h:h")
vim.opt.runtimepath:prepend(plugin_dir)
local review = require("review")
assert(not review.session or review.session.closed, "Use a fresh session for the screenshot demo.")
for _, command in ipairs({ "git", "glab" }) do
  assert(vim.fn.executable(command) == 1, command .. " must be installed.")
end
assert(require("review.telescope").available("Screenshot demo"), "Install Telescope and Plenary first.")

local root = vim.fn.tempname()
local repo = root .. "/repo"
vim.fn.mkdir(root, "p")
local system = vim.system
local allowed_commands = {
  init = true, add = true, commit = true, ["rev-parse"] = true,
  log = true, diff = true, show = true, ["cat-file"] = true,
}
local allowed_config = {
  ["core.hooksPath=" .. root .. "/hooks"] = true, ["commit.gpgsign=false"] = true,
  ["user.name=demo-author"] = true, ["user.email=demo@example.com"] = true,
}
vim.system = function(argv, opts, on_exit)
  assert(type(argv) == "table" and argv[1] == "git" and argv[2] == "-C"
    and argv[3] == repo, "Screenshot mode permits only Git in its temporary repository.")
  local index = 4
  while argv[index] == "-c" do
    assert(allowed_config[argv[index + 1]], "Unexpected screenshot Git configuration.")
    index = index + 2
  end
  assert(allowed_commands[argv[index]], "Git command disabled in screenshot mode: " .. tostring(argv[index]))
  opts = vim.tbl_extend("force", {}, opts or {})
  opts.env = vim.tbl_extend("force", {}, opts.env or {}, {
    GIT_CONFIG_NOSYSTEM = "1", GIT_CONFIG_GLOBAL = "/dev/null",
    GIT_CONFIG_COUNT = "0", GIT_TERMINAL_PROMPT = "0",
  })
  return system(argv, opts, on_exit)
end

local fixture = dofile(plugin_dir .. "/scripts/screenshots/fixture.lua").create(root)
local function publish_log()
  vim.g.review_screenshot_demo = { repo = repo, url = fixture.url, actions = fixture.actions }
end
fixture.on_action = publish_log
publish_log()
vim.g.review_screenshot_root = root

local provider = require("review.providers.gitlab")
for _, name in ipairs({
  "load", "current", "status", "discussions", "pipelines", "pipeline_details", "job_details", "job_trace",
  "post", "reply", "approve", "request_changes", "resolve", "validate_reply", "validate_request_changes",
}) do
  provider[name] = fixture[name]
end
provider.request = function() error("Real GitLab requests are disabled in screenshot mode.", 0) end
require("review.git").prepare = function(target, project, config)
  assert(target.url == fixture.url and project.id == 420 and config.repo == repo,
    "Unexpected screenshot repository.")
  return repo
end
vim.ui.open = function(url)
  assert(type(url) == "string" and url:sub(1, 27) == "https://gitlab.example.com/",
    "Unexpected screenshot browser URL.")
  fixture.record("browser", { url = url })
  vim.notify("Screenshot mode: browser action recorded locally.", vim.log.levels.INFO)
  return { wait = function() return { code = 0, stdout = "", stderr = "" } end }
end

-- Keep the user's selector and choices. Snacks' 80-column select layout clips
-- the bulk-resolution warning, so temporarily widen its existing preset.
local function install_select()
  local select = vim.ui.select
  vim.ui.select = function(items, opts, on_choice)
    local width = opts and type(opts.prompt) == "string" and vim.fn.strdisplaywidth(opts.prompt) or 0
    if width <= 80 or not _G.Snacks then return select(items, opts, on_choice) end
    local ok, layouts = pcall(require, "snacks.picker.config.layouts")
    if not ok or not layouts.select or not layouts.select.layout then return select(items, opts, on_choice) end
    assert(width + 4 <= vim.o.columns - 6, "Widen the demo terminal to show the full warning.")
    local layout = layouts.select.layout
    local saved = { width = layout.width, min_width = layout.min_width, max_width = layout.max_width }
    layout.width, layout.min_width, layout.max_width = width + 4, width + 4, width + 4
    local success, result = pcall(select, items, opts, on_choice)
    layout.width, layout.min_width, layout.max_width = saved.width, saved.min_width, saved.max_width
    if not success then error(result, 0) end
    return result
  end
end
if vim.v.vim_did_enter == 1 then
  install_select()
else
  vim.api.nvim_create_autocmd("VimEnter", { once = true, callback = function() vim.schedule(install_select) end })
end

local preferences = vim.deepcopy(review.config)
local session
local function wait(predicate, label)
  local done = vim.wait(10000, function() return (session and session.error) or predicate() end, 20)
  assert(not session or not session.error, session and session.error)
  assert(done, "Screenshot setup timed out: " .. label)
end

local function display(commit, path)
  path = path or fixture.inbox_path
  session:select_commit(commit, { path = path, require_path = true })
  wait(function()
    return session.current and session.current.file.new_path == path and session.commit_index == commit
  end, "load " .. path)
  vim.api.nvim_set_current_win(session.viewer_win)
  return session.current
end

local function row_for(number)
  for index, row in ipairs(session.current.rows) do
    if row.new_line == number then return index end
  end
  error("Missing screenshot diff line: " .. number)
end

local function seed_drafts()
  local finished = false
  session:task(function()
    for _, example in ipairs({
      { range = fixture.query,
        body = "The default empty query makes `filter(messages)` work without extra configuration." },
      { range = fixture.range, body = fixture.comment_body },
    }) do
      local range = example.range
      local position = session:comment_position(session.current, row_for(range.first), row_for(range.last))
      session:save_draft(example.body, position, session.current.head, {
        path = fixture.inbox_path, base = session.current.base, head = session.current.head,
        new_line = range.last,
      })
    end
    finished = true
  end)
  wait(function() return finished end, "seed drafts")
end

local function reset()
  if session and not session.closed then
    assert(not (session.submitting or session.deciding or session.resolving or session.refreshing),
      "Close the current dialog with Cancel or Keep local before switching scenes.")
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(session.tab)) do
      if vim.api.nvim_win_get_config(win).relative ~= "" then vim.api.nvim_win_close(win, true) end
    end
    session:close()
  end
  fixture.reset()
  vim.fn.delete(root .. "/state", "rf")
  review.setup(vim.tbl_deep_extend("force", preferences, {
    repo = repo, cache_dir = root .. "/cache", state_dir = root .. "/state",
    panel_width = 44, inline_comments = false,
    -- Explicit demo preferences, matching the optional README example.
    keymaps = {
      next_commit = "]c", prev_commit = "[c", next_file = "]f", prev_file = "[f",
      next_hunk = "]h", prev_hunk = "[h", complete = "<leader>ra", drafts = "<leader>rd",
      threads = "<leader>rT", submit = "<leader>rs", refresh = "<leader>rr", info = "<leader>ri",
      help = "<leader>r?",
      toggle_comments = "<leader>rt", toggle_viewed = "<leader>rv", close = "q",
      comment = "<leader>rc", reply = "<leader>rR", thread = "<leader>rl", open_comment = "<leader>ro",
      search_files = "<leader>rf", files_picker = "<leader>rF", filter_exit = "<Esc>",
      panel_open = "<CR>", panel_left = "h", panel_right = "l",
      panel_toggle = "za", panel_expand = "zo", panel_collapse = "zc",
      panel_collapse_all = "zM", panel_expand_all = "zR",
      close_document = "q", select_comment = "<CR>", save_draft = "<C-s>",
      pipeline_open = "<C-o>", pipeline_back = "<C-b>", pipeline_refresh = "<C-r>",
    },
  }))
  review.open(fixture.url)
  session = assert(review.session, "Could not create the screenshot review.")
  wait(function() return session.ready and session.current end, "open review")
  display(0)
  seed_drafts()
  review.approve()
  wait(function() return not session.deciding end, "simulate approval")
  review.viewed(true)
  display(0, "demo/src/config.lua")
  review.viewed(true)
  display(0)
  local ui = require("review.ui")
  for _, path in ipairs({ "demo/docs", "demo/tests" }) do
    assert(ui.focus_panel_entry(session, { directory = path }), "Missing screenshot directory.")
    ui.panel_action(session, "collapse")
  end
  ui.focus_panel_entry(session, { file = session.file_index })
  vim.api.nvim_win_set_cursor(session.viewer_win, { 1, 0 })
  vim.api.nvim_win_call(session.viewer_win, function() vim.cmd.normal({ args = { "gg" }, bang = true }) end)
end

local function current_picker(title)
  local ok, picker = pcall(require("telescope.actions.state").get_current_picker, vim.api.nvim_get_current_buf())
  return ok and picker and picker.prompt_title == title and picker or nil
end

local function preview_contains(text)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.bo[buf].filetype == "review-pipeline" or vim.bo[buf].filetype == "review-job-log" then
      for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
        if line:find(text, 1, true) then return true end
      end
    end
  end
  return false
end

local function pipelines()
  review.pipelines()
  wait(function()
    return current_picker("demo/inbox !42 pipelines") and preview_contains("destroy instance")
  end, "pipeline preview")
end

local scenes = {
  DemoOverview = function() end,
  DemoCommit = function() display(1) end,
  DemoInfo = review.info,
  DemoDrafts = function() session:show_drafts() end,
  DemoSubmit = function() session:submit() end,
  DemoRequestChanges = review.request_changes,
  DemoResolveAll = review.resolve_all,
  DemoPipelines = pipelines,
  DemoCompose = function()
    session:comment(row_for(fixture.range.first), row_for(fixture.range.last))
    wait(function() return vim.bo[vim.api.nvim_get_current_buf()].buftype == "acwrite" end, "comment editor")
    vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.split(fixture.comment_body, "\n", { plain = true }))
  end,
  DemoInline = function()
    review.toggle_comments()
    vim.api.nvim_win_set_cursor(session.viewer_win, { row_for(fixture.query.first) - 1, 0 })
    vim.api.nvim_win_call(session.viewer_win, function() vim.cmd.normal({ args = { "zt" }, bang = true }) end)
    vim.api.nvim_win_set_cursor(session.viewer_win, { row_for(fixture.range.last), 0 })
  end,
  DemoThreads = function()
    vim.api.nvim_win_set_cursor(session.viewer_win, { row_for(fixture.range.last), 0 })
    review.resolve()
    wait(function() return not session.resolving end, "resolve filter conversation")
    assert(session.data.discussions[1].notes[1].resolved, "Fixture conversation was not resolved.")
    session:show_threads({ session.data.discussions[1] })
  end,
  DemoFiles = function()
    review.files("inbox")
    review.files()
    wait(function()
      return session.file_tree.count == 2 and vim.api.nvim_get_current_win() == session.filter_win
    end, "filter file tree")
  end,
  DemoJob = function()
    pipelines()
    local picker = current_picker("demo/inbox !42 pipelines")
    require("telescope.actions").select_default(picker.prompt_bufnr)
    wait(function() return current_picker("Pipeline #703 jobs") end, "job picker")
    current_picker("Pipeline #703 jobs"):reset_prompt("integration checks")
    wait(function()
      local selected = require("telescope.actions.state").get_selected_entry()
      return selected and selected.value.name == "integration checks"
        and preview_contains("ERROR: Job failed: exit code 1")
    end, "failed job preview")
  end,
}

review._commands()
for name, scene in pairs(scenes) do
  vim.api.nvim_create_user_command(name, function()
    local function run()
      local ok, err = pcall(function() reset(); scene() end)
      if not ok then
        vim.notify(tostring(err), vim.log.levels.ERROR, { title = "screenshot demo" })
        error(err, 0)
      end
    end
    if vim.v.vim_did_enter == 1 then run()
    else vim.api.nvim_create_autocmd("VimEnter", { once = true, callback = function() vim.schedule(run) end }) end
  end, { desc = "Prepare the " .. name .. " screenshot scene" })
end
reset()
vim.g.review_demo_ready = true
vim.notify("GitLab demo ready: :DemoPipelines, :DemoJob, :DemoRequestChanges, :DemoResolveAll",
  vim.log.levels.INFO, { title = "screenshot demo" })
