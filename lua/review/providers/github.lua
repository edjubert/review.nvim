local async = require("review.async")
local url = require("review.url")
local position = require("review.position")
local threads = require("review.threads")
local status = require("review.status")
local reactions = require("review.reactions")
local M = { name = "GitHub", cli = "gh", kind = "PR", label = "pull request", prefix = "#" }

function M.head_ref(target)
  return ("refs/pull/%d/head"):format(target.iid)
end

function M.request(target, endpoint, body, method, raw)
  local argv = {
    "gh", "api", "--hostname", target.host, "--method", method or (body and "POST" or "GET"),
    "-H", "Accept: application/vnd.github+json",
  }
  -- Raw log responses carry ANSI escape sequences that gh refuses to print
  -- by default; the shared job log renderer normalizes them itself.
  if raw then vim.list_extend(argv, { "--allow-escape-sequences" }) end
  vim.list_extend(argv, { endpoint })
  local opts = {}
  if body then
    vim.list_extend(argv, { "--input", "-" })
    opts.stdin = vim.json.encode(body)
  end
  local output = async.checked(argv, opts)
  if raw then return output end
  local ok, data = pcall(vim.json.decode, output)
  if not ok then error("GitHub returned an invalid JSON response.", 0) end
  return data
end

function M.repo_path(target)
  return "repos/" .. target.project:gsub("[^/]+", url.encode)
end

function M.pr_path(target)
  return M.repo_path(target) .. "/pulls/" .. target.iid
end

function M.pages(target, endpoint)
  local all = {}
  for page = 1, 1000 do
    local data = M.request(target, endpoint .. "?per_page=100&page=" .. page)
    if type(data) ~= "table" or not vim.islist(data) then error("Expected a GitHub result list.", 0) end
    vim.list_extend(all, data)
    if #data < 100 then return all end
  end
  error("GitHub pagination exceeded 1000 pages; refusing an incomplete result.", 0)
end

local function compare_path(target, pr)
  return M.repo_path(target) .. "/compare/" .. url.encode(pr.base.sha) .. "..." .. url.encode(pr.head.sha)
end

local function with_refs(target, pr)
  if type(pr) ~= "table" or type(pr.base) ~= "table" or type(pr.head) ~= "table"
      or type(pr.base.sha) ~= "string" or type(pr.head.sha) ~= "string" then
    error("GitHub did not provide valid PR commit references.", 0)
  end
  local comparison = M.request(target, compare_path(target, pr) .. "?per_page=100&page=1")
  local base = type(comparison) == "table" and type(comparison.merge_base_commit) == "table"
    and comparison.merge_base_commit.sha or nil
  if type(base) ~= "string" then error("GitHub did not provide the PR merge base.", 0) end
  -- The shared session stores provider-neutral references in this shape.
  pr.diff_refs = { base_sha = base, head_sha = pr.head.sha, start_sha = pr.base.sha }
  pr.description = type(pr.body) == "string" and pr.body or ""
  return pr, comparison
end

local function load_commits(target, pr, comparison)
  if pr.commits <= 250 then return M.pages(target, M.pr_path(target) .. "/commits") end
  -- The PR commits endpoint stops at 250. A comparison of the immutable base
  -- and head SHAs gives the complete BASE..HEAD list with explicit pagination.
  local commits = {}
  for page = 1, 1000 do
    local data = page == 1 and comparison
      or M.request(target, compare_path(target, pr) .. "?per_page=100&page=" .. page)
    if type(data) ~= "table" or type(data.commits) ~= "table" or not vim.islist(data.commits)
        or data.total_commits ~= pr.commits then
      error("GitHub's comparison does not match the PR commit list; refusing an incomplete review.", 0)
    end
    vim.list_extend(commits, data.commits)
    if #data.commits < 100 then return commits end
  end
  error("GitHub commit pagination exceeded 1000 pages; refusing an incomplete review.", 0)
end

function M.current(target)
  return with_refs(target, M.info(target))
end

M.references = with_refs

function M.pipeline_status(target, pr)
  return status.read(function()
    local endpoint = M.repo_path(target) .. "/commits/" .. url.encode(pr.diff_refs.head_sha)
    local combined = M.request(target, endpoint .. "/status")
    local states = {}
    if (combined.total_count or 0) > 0 then states[#states + 1] = combined.state or "unknown" end
    local count = 0
    for page = 1, 1000 do
      local checks = M.request(target, endpoint .. "/check-runs?per_page=100&page=" .. page)
      if type(checks) ~= "table" or type(checks.check_runs) ~= "table"
          or not vim.islist(checks.check_runs) or type(checks.total_count) ~= "number" then
        error("GitHub returned an invalid check run list.", 0)
      end
      for _, check in ipairs(checks.check_runs) do
        states[#states + 1] = check.status == "completed" and
          (type(check.conclusion) == "string" and check.conclusion or "unknown") or check.status or "unknown"
      end
      count = count + #checks.check_runs
      if count >= checks.total_count then return { state = status.pipeline(states) } end
      if #checks.check_runs == 0 then break end
    end
    error("GitHub returned an incomplete check run list.", 0)
  end)
end

function M.review_status(target)
  return status.read(function()
    return status.reviews(M.pages(target, M.pr_path(target) .. "/reviews"))
  end)
end

function M.status(target, pr)
  return async.all({
    pipeline = function() return M.pipeline_status(target, pr) end,
    review = function() return M.review_status(target, pr) end,
  })
end

local function decision(target, refs, event, body)
  local result = M.request(target, M.pr_path(target) .. "/reviews", {
    event = event, commit_id = refs.head_sha, body = body or "",
  })
  local expected = event == "APPROVE" and "APPROVED" or "CHANGES_REQUESTED"
  if type(result) ~= "table" or not result.id or result.state ~= expected
      or result.commit_id ~= refs.head_sha then
    error("GitHub did not confirm the review decision. Check the PR before retrying.", 0)
  end
  return result
end

function M.approve(target, refs)
  return decision(target, refs, "APPROVE")
end

M.request_changes_requires_body = true

function M.request_changes(target, refs, body)
  if type(body) ~= "string" or vim.trim(body) == "" then error("Request changes requires a summary.", 0) end
  return decision(target, refs, "REQUEST_CHANGES", body)
end

local function number(value)
  return type(value) == "number" and value or nil
end

function M.discussions(target, refs, files)
  local comments = M.pages(target, M.pr_path(target) .. "/comments")
  local discussions, by_id, by_path = {}, {}, {}
  for _, file in ipairs(files or {}) do by_path[file.new_path] = file end
  for _, comment in ipairs(comments) do
    local id = number(comment.in_reply_to_id) or comment.id
    if not by_id[id] then
      by_id[id] = { id = id, notes = {} }
      discussions[#discussions + 1] = by_id[id]
    end
    local line = number(comment.line)
    local display_line = line or number(comment.original_line)
    local file = by_path[comment.path]
    local p = {
      new_path = comment.path,
      old_path = file and file.old_path or comment.path,
      head_sha = line and comment.commit_id or nil,
      base_sha = line and refs and comment.commit_id == refs.head_sha and refs.base_sha or nil,
      new_line = comment.side ~= "LEFT" and display_line or nil,
      old_line = comment.side == "LEFT" and display_line or nil,
    }
    local start = number(line and comment.start_line or comment.original_start_line)
    if start and display_line and start < display_line
        and (comment.start_side or comment.side) == comment.side then
      local key = comment.side == "LEFT" and "old_line" or "new_line"
      p.line_range = { start = { [key] = start }, ["end"] = { [key] = display_line } }
    end
    local author = type(comment.user) == "table" and comment.user.login or "unknown"
    local note = {
      id = comment.id, body = comment.body or "", author = { username = author }, position = p,
      web_url = type(comment.html_url) == "string" and comment.html_url or nil,
      -- REST comments do not expose a thread's resolved state.
      outdated = not line, system = false,
      reactions = reactions.summary(comment.reactions),
    }
    if comment.id == id then table.insert(by_id[id].notes, 1, note)
    else by_id[id].notes[#by_id[id].notes + 1] = note end
  end
  return discussions
end

function M.info(target)
  local pr = M.request(target, M.pr_path(target))
  if type(pr) ~= "table" then error("GitHub returned an invalid PR.", 0) end
  pr.description = type(pr.body) == "string" and pr.body or ""
  return pr
end

function M.commits(target, pr, comparison)
  if type(pr.commits) ~= "number" then
    error("GitHub did not provide the PR commit count.", 0)
  end
  local raw_commits = load_commits(target, pr, comparison)
  if #raw_commits ~= pr.commits then error("The PR commit list changed while loading. Run :ReviewRefresh.", 0) end
  local commits = {}
  -- GitHub's PR commits endpoint returns the oldest commits first.
  for _, commit in ipairs(raw_commits) do
    if type(commit.sha) ~= "string" or type(commit.commit) ~= "table"
        or type(commit.commit.message) ~= "string" or type(commit.parents) ~= "table" then
      error("GitHub returned an invalid PR commit.", 0)
    end
    local parents = {}
    for _, parent in ipairs(commit.parents or {}) do parents[#parents + 1] = parent.sha end
    commits[#commits + 1] = {
      id = commit.sha, parent_ids = parents,
      title = (commit.commit.message or ""):match("^[^\r\n]*"),
    }
  end
  return commits
end

function M.diffs(target, pr)
  if type(pr.changed_files) ~= "number" then
    error("GitHub did not provide the PR file count.", 0)
  end
  if pr.changed_files > 3000 then
    error("GitHub's PR files API is limited to 3000 files; refusing an incomplete review.", 0)
  end
  local raw_files = M.pages(target, M.pr_path(target) .. "/files")
  if #raw_files ~= pr.changed_files then error("The PR file list changed while loading. Run :ReviewRefresh.", 0) end
  local diffs = {}
  for _, file in ipairs(raw_files) do
    diffs[#diffs + 1] = {
      old_path = type(file.previous_filename) == "string" and file.previous_filename or file.filename,
      new_path = file.filename,
      new_file = file.status == "added", deleted_file = file.status == "removed",
      renamed_file = file.status == "renamed",
      diff = type(file.patch) == "string" and file.patch or "",
    }
  end
  return diffs
end

local function positive_id(value)
  return type(value) == "number" and value > 0 and value % 1 == 0
end

-- Check suite and check run endpoints reply with an object holding one list,
-- unlike the raw arrays paginated by M.pages.
local function wrapped_pages(target, endpoint, key)
  local all = {}
  for page = 1, 1000 do
    local data = M.request(target, endpoint .. "?per_page=100&page=" .. page)
    if type(data) ~= "table" or not vim.islist(data[key]) then
      error("GitHub returned an invalid " .. key .. " list.", 0)
    end
    vim.list_extend(all, data[key])
    if #data[key] < 100 then return all end
  end
  error("GitHub pagination exceeded 1000 pages; refusing an incomplete result.", 0)
end

-- Check run statuses and conclusions use a vocabulary the shared pipeline
-- picker already renders through its style and label tables.
local function check_state(value)
  if type(value) ~= "table" then return "unknown" end
  if value.status == "queued" then return "queued" end
  if value.status == "in_progress" then return "in_progress" end
  if value.status == "completed" then
    if type(value.conclusion) == "string" and value.conclusion ~= "" then
      return value.conclusion
    end
    return "unknown"
  end
  return type(value.status) == "string" and value.status or "unknown"
end

-- Timestamps are UTC ISO strings; the calendar conversion cancels out except
-- across a DST change, where a duration can drift by one hour.
local function timestamp(value)
  if type(value) ~= "string" then return nil end
  local year, month, day, hour, minute, second =
    value:match("^(%d%d%d%d)-(%d%d)-(%d%d)T(%d%d):(%d%d):(%d%d)")
  if not year then return nil end
  return os.time({ year = year, month = month, day = day, hour = hour, min = minute, sec = second })
end

local function run_duration(run)
  local started, finished = timestamp(run.started_at), timestamp(run.completed_at)
  if not started or not finished then return nil end
  local seconds = finished - started
  return seconds >= 0 and seconds or nil
end

local function suite_metadata(suite)
  local app = type(suite.app) == "table" and suite.app or {}
  return {
    id = suite.id,
    name = type(app.name) == "string" and app.name or "checks",
    state = check_state(suite),
    ref = suite.head_branch, sha = suite.head_sha,
    created_at = suite.created_at, updated_at = suite.updated_at,
  }
end

local function job_metadata(run, pipeline_id)
  if type(run) ~= "table" or not positive_id(run.id) then
    error("GitHub returned an invalid check run.", 0)
  end
  local app = type(run.app) == "table" and run.app or {}
  return {
    id = run.id, name = run.name,
    stage = type(app.name) == "string" and app.name or "checks",
    state = check_state(run), pipeline_id = pipeline_id,
    ref = run.head_branch, sha = run.head_sha,
    duration = run_duration(run),
    started_at = run.started_at, finished_at = run.completed_at,
    web_url = type(run.html_url) == "string" and run.html_url
      or (type(run.details_url) == "string" and run.details_url or nil),
  }
end

-- A PR's pipelines are the check suites anchored to its head commit, the same
-- set GitHub lists in the pull request's Checks tab.
function M.pipelines(target, head_sha)
  if type(head_sha) ~= "string" or head_sha == "" then
    local pr = M.info(target)
    if type(pr) ~= "table" or type(pr.head) ~= "table" or type(pr.head.sha) ~= "string" then
      error("GitHub did not provide the PR head commit.", 0)
    end
    head_sha = pr.head.sha
  end
  local suites = wrapped_pages(target,
    M.repo_path(target) .. "/commits/" .. url.encode(head_sha) .. "/check-suites", "check_suites")
  local pipelines = {}
  for _, suite in ipairs(suites) do
    if type(suite) ~= "table" or not positive_id(suite.id) then
      error("GitHub returned an invalid check suite.", 0)
    end
    pipelines[#pipelines + 1] = suite_metadata(suite)
  end
  table.sort(pipelines, function(a, b) return a.id > b.id end)
  return pipelines
end

function M.pipeline_details(target, pipeline)
  if not positive_id(pipeline.id) then error("This pipeline has no valid GitHub ID.", 0) end
  local result = vim.deepcopy(pipeline)
  result.jobs = {}
  local ok, runs = pcall(wrapped_pages, target,
    M.repo_path(target) .. "/check-suites/" .. pipeline.id .. "/check-runs", "check_runs")
  if not ok then result.jobs_error = tostring(runs); return result end
  for _, run in ipairs(runs) do
    result.jobs[#result.jobs + 1] = job_metadata(run, pipeline.id)
  end
  table.sort(result.jobs, function(a, b) return a.id < b.id end)
  return result
end

-- Actions check runs mirror workflow jobs sharing the same ID, which unlocks
-- runner metadata and the job log. Other apps have no workflow job.
function M.job_details(target, job)
  if not positive_id(job.id) then error("This job has no valid GitHub ID.", 0) end
  local ok, run = pcall(M.request, target, M.repo_path(target) .. "/actions/jobs/" .. job.id)
  if not ok or type(run) ~= "table" or run.id ~= job.id then return vim.deepcopy(job) end
  local result = vim.deepcopy(job)
  result.state = check_state(run)
  result.started_at = run.started_at or result.started_at
  result.finished_at = run.completed_at or result.finished_at
  result.duration = run_duration(run) or result.duration
  result.runner = type(run.runner_name) == "string" and run.runner_name or result.runner
  result.web_url = type(run.html_url) == "string" and run.html_url or result.web_url
  return result
end

-- The shared logs module passes GitLab's trace path template; GitHub reads the
-- workflow job log directly and leaves the template unused.
function M.job_trace(target, job, path)
  if not positive_id(job.id) then error("This job has no valid GitHub ID.", 0) end
  return M.request(target, M.repo_path(target) .. "/actions/jobs/" .. job.id .. "/logs", nil, "GET", true)
end

function M.project(target)
  local repo = M.request(target, M.repo_path(target))
  return {
    http_url_to_repo = repo.clone_url, ssh_url_to_repo = repo.ssh_url,
  }
end

function M.load(target)
  return require("review.providers").load(target)
end

function M.build_position(refs, file, rows)
  local side, err = position.validate(rows)
  if not side then return nil, err end
  local first, last = rows[1], rows[#rows]
  local key = side .. "_line"
  local p = {
    base_sha = refs.base_sha, head_sha = refs.head_sha, start_sha = refs.start_sha,
    old_path = file.old_path, new_path = file.new_path,
    side = side == "old" and "LEFT" or "RIGHT",
  }
  p[key] = last[key]
  if #rows > 1 then
    p.line_range = { start = { [key] = first[key] }, ["end"] = { [key] = last[key] } }
  end
  return p
end

function M.post(target, draft)
  local p = draft.position
  local body = {
    body = draft.body, commit_id = p.head_sha, path = p.new_path,
    line = p.new_line or p.old_line, side = p.side,
  }
  if p.line_range then
    local first = p.line_range.start
    body.start_line = first.new_line or first.old_line
    body.start_side = p.side
  end
  -- Only the explicit submission flow calls this method.
  local response = M.request(target, M.pr_path(target) .. "/comments", body)
  if type(response) ~= "table" or not response.id then error("GitHub did not confirm the comment ID.", 0) end
  return response
end

function M.reply_target(discussion)
  local root = threads.root(discussion)
  if not root or type(root.id) ~= "number" or root.id <= 0 or root.id % 1 ~= 0
      or discussion.id ~= root.id then
    return nil, "GitHub did not expose the top-level review comment ID."
  end
  return { discussion_id = discussion.id, note_id = root.id }
end

local function reply_id(draft)
  local reply = draft.reply
  if type(reply) ~= "table" or type(reply.note_id) ~= "number" or reply.note_id <= 0
      or reply.note_id % 1 ~= 0 or reply.discussion_id ~= reply.note_id then
    error("This reply has no valid GitHub root comment target. Recreate the reply draft.", 0)
  end
  return tostring(reply.note_id)
end

function M.validate_reply(target, draft)
  local comment = M.request(target, M.repo_path(target) .. "/pulls/comments/" .. reply_id(draft))
  local suffix = "/" .. M.pr_path(target)
  if type(comment) ~= "table" or comment.id ~= draft.reply.note_id
      or (comment.in_reply_to_id ~= nil and comment.in_reply_to_id ~= vim.NIL)
      or type(comment.pull_request_url) ~= "string" or comment.pull_request_url:sub(-#suffix) ~= suffix then
    error("The original GitHub comment is no longer available in this PR. The reply remains local.", 0)
  end
end

function M.reply(target, draft)
  -- GitHub only accepts replies to top-level review comments.
  local response = M.request(target, M.pr_path(target) .. "/comments/" .. reply_id(draft) .. "/replies", {
    body = draft.body,
  })
  if type(response) ~= "table" or type(response.id) ~= "number" or response.id <= 0
      or response.in_reply_to_id ~= draft.reply.note_id then
    error("GitHub did not confirm the reply's root comment ID.", 0)
  end
  return response
end

return M
