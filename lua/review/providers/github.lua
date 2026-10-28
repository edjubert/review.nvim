local async = require("review.async")
local url = require("review.url")
local position = require("review.position")
local threads = require("review.threads")
local M = { name = "GitHub", cli = "gh", kind = "PR", label = "pull request", prefix = "#" }

function M.head_ref(target)
  return ("refs/pull/%d/head"):format(target.iid)
end

function M.request(target, endpoint, body)
  local argv = {
    "gh", "api", "--hostname", target.host, "--method", body and "POST" or "GET",
    "-H", "Accept: application/vnd.github+json", endpoint,
  }
  local opts = {}
  if body then
    vim.list_extend(argv, { "--input", "-" })
    opts.stdin = vim.json.encode(body)
  end
  local output = async.checked(argv, opts)
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
  return with_refs(target, M.request(target, M.pr_path(target)))
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
      -- REST comments do not expose a thread's resolved state.
      outdated = not line, system = false,
    }
    if comment.id == id then table.insert(by_id[id].notes, 1, note)
    else by_id[id].notes[#by_id[id].notes + 1] = note end
  end
  return discussions
end

function M.load(target)
  local endpoint = M.pr_path(target)
  local pr, comparison = M.current(target)
  if type(pr.commits) ~= "number" or type(pr.changed_files) ~= "number" then
    error("GitHub did not provide the PR commit and file counts.", 0)
  end
  if pr.changed_files > 3000 then
    error("GitHub's PR files API is limited to 3000 files; refusing an incomplete review.", 0)
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
  local raw_files = M.pages(target, endpoint .. "/files")
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
  local repo = M.request(target, M.repo_path(target))
  return {
    mr = pr, commits = commits, diffs = diffs,
    project = { http_url_to_repo = repo.clone_url, ssh_url_to_repo = repo.ssh_url },
    discussions = M.discussions(target, pr.diff_refs, diffs),
  }
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
