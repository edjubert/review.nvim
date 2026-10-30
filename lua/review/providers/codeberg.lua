local async = require("review.async")
local url = require("review.url")
local position = require("review.position")
local patches = require("review.providers.codeberg_diff")
local status = require("review.status")
local reactions = require("review.reactions")
local M = { name = "Codeberg", cli = "curl", kind = "PR", label = "pull request", prefix = "#" }
local page_size

local function token(required)
  local value = vim.env.CODEBERG_TOKEN
  if not value or value == "" then
    if required then error("Set CODEBERG_TOKEN in Neovim's environment to publish Codeberg reviews.", 0) end
    return nil
  end
  if value:find("[%c]") then error("CODEBERG_TOKEN contains invalid control characters.", 0) end
  return value
end

local function quote(value)
  local escaped = value:gsub("\\", "\\\\"):gsub('"', '\\"')
    :gsub("\r", "\\r"):gsub("\n", "\\n"):gsub("\t", "\\t")
  return '"' .. escaped .. '"'
end

local function response(output)
  while true do
    local first, last = output:find("\r?\n\r?\n")
    if not first then return nil, {}, output end
    local block, headers = output:sub(1, first - 1), {}
    local status = tonumber(block:match("^HTTP/%S+ (%d%d%d)"))
    if not status then return nil, {}, output end
    for line in block:gmatch("[^\r\n]+") do
      local name, value = line:match("^([^:]+):%s*(.*)$")
      if name then headers[name:lower()] = value end
    end
    output = output:sub(last + 1)
    if status >= 200 then return status, headers, output end
  end
end

function M.head_ref(target)
  return ("refs/pull/%d/head"):format(target.iid)
end

function M.request(target, endpoint, body, raw)
  -- This environment token belongs exclusively to Codeberg, not other Forgejo
  -- installations. Redirects and curlrc are disabled to preserve that boundary.
  if target.host ~= "codeberg.org" then error("The Codeberg provider only supports codeberg.org.", 0) end
  local auth
  -- Pagination settings are public. Do not require extra token scopes outside
  -- the repository just to read the server's maximum page size.
  if endpoint ~= "settings/api" then auth = token(body ~= nil) end
  local config = {
    "url = " .. quote("https://codeberg.org/api/v1/" .. endpoint),
    "request = " .. quote(body and "POST" or "GET"),
    "header = " .. quote("Accept: " .. (raw and "text/plain" or "application/json")),
  }
  if auth then config[#config + 1] = "header = " .. quote("Authorization: token " .. auth) end
  if body then
    config[#config + 1] = 'header = "Content-Type: application/json"'
    config[#config + 1] = "data = " .. quote(vim.json.encode(body))
  end
  -- Credentials and comment bodies travel through stdin, never process args
  -- or temporary files. There are no automatic retries of write requests.
  local result = async.system({
    "curl", "--disable", "--silent", "--show-error",
    "--include", "--suppress-connect-headers", "--globoff",
    "--connect-timeout", "15", "--max-time", "120", "--config", "-",
  }, { stdin = table.concat(config, "\n") .. "\n" })
  local status, headers, output = response(result.stdout or "")
  if result.code ~= 0 or not status or status < 200 or status >= 300 then
    local detail = status and ("HTTP " .. status) or ("curl exit " .. tostring(result.code))
    if status == 401 or status == 403 then
      detail = detail .. "; check CODEBERG_TOKEN and repository permissions"
    end
    error("Codeberg API request failed (" .. detail .. ").", 0)
  end
  if raw then return output, headers end
  local ok, data = pcall(vim.json.decode, output)
  if not ok then error("Codeberg returned an invalid JSON response.", 0) end
  return data, headers
end

function M.repo_path(target)
  return "repos/" .. target.project:gsub("[^/]+", url.encode)
end

function M.pr_path(target)
  return M.repo_path(target) .. "/pulls/" .. target.iid
end

function M.pages(target, endpoint, filtered)
  if not page_size then
    local settings = M.request(target, "settings/api")
    local maximum = type(settings) == "table" and settings.max_response_items
    if type(maximum) ~= "number" or maximum < 1 or maximum % 1 ~= 0 then
      error("Codeberg did not provide valid pagination settings.", 0)
    end
    page_size = math.min(50, maximum)
  end
  local all, count = {}, nil
  for page = 1, 1000 do
    local separator = endpoint:find("?", 1, true) and "&" or "?"
    local data, headers = M.request(target, endpoint .. separator .. "limit=" .. page_size .. "&page=" .. page)
    local total = tonumber(headers["x-total-count"])
    if not total or total < 0 or total % 1 ~= 0 or (count and count ~= total) then
      error("Codeberg's result count changed or is missing. Run :ReviewRefresh.", 0)
    end
    count = total
    if data == vim.NIL and total == 0 then data = {} end
    if type(data) ~= "table" or not vim.islist(data) then error("Expected a Codeberg result list.", 0) end
    vim.list_extend(all, data)
    local size = tonumber(headers["x-perpage"]) or page_size
    local returned_page = tonumber(headers["x-page"])
    if size < 1 or size % 1 ~= 0 or (returned_page and returned_page ~= page) then
      error("Codeberg returned an invalid pagination response.", 0)
    end
    if #all > total then error("Codeberg's result count changed. Run :ReviewRefresh.", 0) end
    local last = headers["x-hasmore"] == "false" or page * size >= total
    if last then
      -- The reviews count includes other users' hidden pending reviews. Fetch
      -- every page even if a filtered page is short or empty.
      if not filtered and #all ~= total then
        error("Codeberg returned an incomplete result list. Run :ReviewRefresh.", 0)
      end
      return all
    end
  end
  error("Codeberg pagination exceeded 1000 pages; refusing an incomplete result.", 0)
end

local function sha(value)
  return type(value) == "string" and value:match("^%x+$") and (#value == 40 or #value == 64)
end

function M.current(target)
  local pr = M.request(target, M.pr_path(target))
  if type(pr) ~= "table" or type(pr.base) ~= "table" or type(pr.head) ~= "table"
      or not sha(pr.base.sha) or not sha(pr.head.sha) or not sha(pr.merge_base) then
    error("Codeberg did not provide valid PR references or its merge base. Run :ReviewRefresh.", 0)
  end
  pr.diff_refs = { base_sha = pr.merge_base, head_sha = pr.head.sha, start_sha = pr.base.sha }
  pr.description = type(pr.body) == "string" and pr.body or ""
  return pr
end

local function line(value)
  return type(value) == "number" and value > 0 and value % 1 == 0 and value or nil
end

function M.discussions(target, refs, files)
  local discussions, by_path = {}, {}
  for _, file in ipairs(files or {}) do by_path[file.new_path] = file end
  for _, review in ipairs(M.pages(target, M.pr_path(target) .. "/reviews", true)) do
    -- Browser drafts are not published discussions.
    if review.state ~= "PENDING" and review.comments_count and review.comments_count > 0 then
      local comments = M.request(target, M.pr_path(target) .. "/reviews/" .. review.id .. "/comments")
      if type(comments) ~= "table" or not vim.islist(comments) then
        error("Expected a Codeberg review comment list.", 0)
      end
      for _, comment in ipairs(comments) do
        local awards, reactions_error
        if type(comment.id) == "number" and comment.id > 0 and comment.id % 1 == 0 then
          local ok, result = pcall(M.pages, target,
            M.repo_path(target) .. "/issues/comments/" .. comment.id .. "/reactions")
          if ok then awards = reactions.aggregate(result) else reactions_error = tostring(result) end
        end
        local old, new = line(comment.original_position), line(comment.position)
        local file = by_path[comment.path]
        local current = not review.stale and comment.commit_id == refs.head_sha
        local p = {
          old_path = file and file.old_path or comment.path, new_path = comment.path,
          head_sha = current and refs.head_sha or nil, base_sha = current and refs.base_sha or nil,
          old_line = old, new_line = new,
        }
        local extra = type(comment.extra_lines_count) == "number" and math.max(0, comment.extra_lines_count) or 0
        local first, key = new or old, new and "new_line" or "old_line"
        if first and extra > 0 then
          p[key] = first + extra
          p.line_range = { start = { [key] = first }, ["end"] = { [key] = first + extra } }
        end
        discussions[#discussions + 1] = {
          id = comment.id,
          notes = { {
            id = comment.id, body = comment.body or "", position = p, system = false,
            web_url = type(comment.html_url) == "string" and comment.html_url or nil,
            author = { username = type(comment.user) == "table" and comment.user.login or "unknown" },
            resolved = type(comment.resolver) == "table" and comment.resolver.id ~= nil,
            outdated = review.stale == true,
            reactions = awards, reactions_error = reactions_error,
          } },
        }
      end
    end
  end
  return discussions
end

M.info = M.current

function M.commits(target, pr)
  local raw_commits = M.pages(target, M.pr_path(target) .. "/commits?verification=false&files=false")
  local commits, seen = {}, {}
  if #raw_commits > 0 and raw_commits[1].sha ~= pr.head.sha then
    error("Codeberg's PR commit list changed while loading. Run :ReviewRefresh.", 0)
  end
  -- Forgejo uses git log (newest first); the sidebar shows oldest first.
  for i = #raw_commits, 1, -1 do
    local commit = raw_commits[i]
    if not sha(commit.sha) or seen[commit.sha] or type(commit.commit) ~= "table"
        or type(commit.commit.message) ~= "string" or type(commit.parents) ~= "table" then
      error("Codeberg returned an invalid PR commit.", 0)
    end
    seen[commit.sha] = true
    local parents = {}
    for _, parent in ipairs(commit.parents) do
      if not sha(parent.sha) then error("Codeberg returned an invalid parent commit.", 0) end
      parents[#parents + 1] = parent.sha
    end
    commits[#commits + 1] = {
      id = commit.sha, parent_ids = parents, title = commit.commit.message:match("^[^\r\n]*"),
    }
  end
  return commits
end

function M.diffs(target, pr)
  local endpoint = M.pr_path(target)
  local raw_files, diffs = M.pages(target, endpoint .. "/files"), {}
  if type(pr.changed_files) ~= "number" or #raw_files ~= pr.changed_files then
    error("Codeberg's PR file list changed or is incomplete. Run :ReviewRefresh.", 0)
  end
  local names = {}
  for _, file in ipairs(raw_files) do
    if type(file.filename) ~= "string" or file.filename == "" or names[file.filename] then
      error("Codeberg returned an invalid PR file.", 0)
    end
    names[file.filename] = true
    local old = type(file.previous_filename) == "string" and file.previous_filename ~= ""
      and file.previous_filename or file.filename
    diffs[#diffs + 1] = {
      old_path = old, new_path = file.filename, new_file = file.status == "added",
      deleted_file = file.status == "removed" or file.status == "deleted",
      renamed_file = old ~= file.filename, diff = "",
    }
  end
  patches.apply(M.request(target, endpoint .. ".diff", nil, true), diffs)
  return diffs
end

function M.project(target)
  local repo = M.request(target, M.repo_path(target))
  if type(repo) ~= "table" then error("Codeberg returned an invalid repository.", 0) end
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
  local first, last, key = rows[1], rows[#rows], side .. "_line"
  local p = {
    base_sha = refs.base_sha, head_sha = refs.head_sha, start_sha = refs.start_sha,
    old_path = file.old_path, new_path = file.new_path,
  }
  p[key] = last[key]
  if #rows > 1 then
    p.line_range = { start = { [key] = first[key] }, ["end"] = { [key] = last[key] } }
  end
  return p
end

function M.validate_submission(target)
  token(true)
  for _, review in ipairs(M.pages(target, M.pr_path(target) .. "/reviews", true)) do
    if review.state == "PENDING" then
      error("Finish or discard your pending Codeberg review before submitting. Local drafts remain saved.", 0)
    end
  end
end

M.validate_request_changes = M.validate_submission

function M.pipeline_status(target, pr)
  return status.read(function()
    local result = M.request(target, M.repo_path(target) .. "/commits/" .. pr.diff_refs.head_sha .. "/status")
    return { state = (result.total_count or 0) > 0 and status.pipeline({ result.state or "unknown" }) or "none" }
  end)
end

function M.review_status(target)
  return status.read(function()
    return status.reviews(M.pages(target, M.pr_path(target) .. "/reviews", true))
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
    comments = {},
  })
  if type(result) ~= "table" or not result.id or result.state ~= event or result.comments_count ~= 0
      or result.commit_id ~= refs.head_sha then
    error("Codeberg did not confirm the review decision. Check the PR before retrying.", 0)
  end
  return result
end

function M.approve(target, refs)
  M.validate_submission(target)
  return decision(target, refs, "APPROVED")
end

M.request_changes_requires_body = true

function M.request_changes(target, refs, body)
  if type(body) ~= "string" or vim.trim(body) == "" then error("Request changes requires a summary.", 0) end
  -- Recheck immediately before writing: Forgejo can attach browser drafts.
  M.validate_submission(target)
  return decision(target, refs, "REQUEST_CHANGES", body)
end

function M.post(target, draft)
  local p = draft.position
  local first = p.line_range and p.line_range.start or p
  local start, last = first.new_line or first.old_line, p.new_line or p.old_line
  local body = {
    event = "COMMENT", commit_id = p.head_sha, body = "",
    comments = { {
      body = draft.body, path = p.new_path,
      old_position = first.old_line or 0, new_position = first.new_line or 0,
      extra_lines_count = last - start,
    } },
  }
  -- Only explicit submission reaches this endpoint. COMMENT never approves
  -- or requests changes. Each local draft creates one published review.
  local result = M.request(target, M.pr_path(target) .. "/reviews", body)
  if type(result) ~= "table" or not result.id or result.comments_count ~= 1 or result.state ~= "COMMENT" then
    error("Codeberg did not confirm the expected published comment.", 0)
  end
  return result
end

return M
