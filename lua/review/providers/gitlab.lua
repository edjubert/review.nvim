local async = require("review.async")
local url = require("review.url")
local position = require("review.position")
local threads = require("review.threads")
local status = require("review.status")
local reactions = require("review.reactions")
local M = { name = "GitLab", cli = "glab", kind = "MR", label = "merge request", prefix = "!" }

function M.head_ref(target)
  return ("refs/merge-requests/%d/head"):format(target.iid)
end

M.build_position = position.build

function M.request(target, endpoint, body, method, raw)
  local argv = { "glab", "api", "--hostname", target.host, "--method", method or (body and "POST" or "GET"), endpoint }
  local opts = {}
  if body then
    vim.list_extend(argv, { "--input", "-" })
    opts.stdin = vim.json.encode(body)
  end
  local output = async.checked(argv, opts)
  if raw then return output end
  local ok, data = pcall(vim.json.decode, output)
  if not ok then error("GitLab returned an invalid JSON response.", 0) end
  return data
end

function M.project_path(target)
  return "projects/" .. url.encode(target.project)
end

function M.mr_path(target)
  return M.project_path(target) .. "/merge_requests/" .. target.iid
end

function M.pages(target, endpoint)
  local all = {}
  for page = 1, 1000 do
    local data = M.request(target, endpoint .. "?per_page=100&page=" .. page)
    if type(data) ~= "table" or not vim.islist(data) then error("Expected a GitLab result list.", 0) end
    vim.list_extend(all, data)
    if #data < 100 then return all end
  end
  error("GitLab pagination exceeded 1000 pages; refusing an incomplete result.", 0)
end

function M.load(target)
  local endpoint = M.mr_path(target)
  local mr = M.request(target, endpoint)
  if type(mr.diff_refs) ~= "table"
      or type(mr.diff_refs.head_sha) ~= "string"
      or type(mr.diff_refs.base_sha) ~= "string"
      or type(mr.diff_refs.start_sha) ~= "string" then
    error("GitLab is still preparing the MR diff. Try again shortly.", 0)
  end
  local commits = M.pages(target, endpoint .. "/commits")
  -- GitLab returns newest first; browsing starts at the oldest commit.
  local ordered = {}
  for i = #commits, 1, -1 do ordered[#ordered + 1] = commits[i] end
  return {
    mr = mr,
    commits = ordered,
    project = M.request(target, M.project_path(target)),
    diffs = M.pages(target, endpoint .. "/diffs"),
    discussions = M.discussions(target),
  }
end

function M.current(target)
  return M.request(target, M.mr_path(target))
end

local function comment_metadata(target, discussion)
  for _, note in ipairs(discussion.notes or {}) do
    if not note.system and type(note.id) == "number" and note.id > 0 and note.id % 1 == 0 then
      note.web_url = target.url .. "#note_" .. note.id
    end
  end
  return discussion
end

function M.note_reactions(target, note)
  return reactions.aggregate(M.pages(target, M.mr_path(target) .. "/notes/" .. note.id .. "/award_emoji"))
end

function M.discussions(target)
  local discussions = M.pages(target, M.mr_path(target) .. "/discussions")
  for _, discussion in ipairs(discussions) do
    comment_metadata(target, discussion)
    for _, note in ipairs(discussion.notes or {}) do
      if not note.system and type(note.id) == "number" and note.id > 0 and note.id % 1 == 0 then
        local ok, result = pcall(M.note_reactions, target, note)
        if ok then note.reactions = result else note.reactions_error = tostring(result) end
      end
    end
  end
  return discussions
end

function M.is_resolved(discussion)
  local found = false
  for _, note in ipairs(discussion.notes or {}) do
    if not note.system and note.resolvable == true then
      found = true
      if note.resolved ~= true then return false end
    end
  end
  return found
end

function M.can_resolve(discussion)
  if type(discussion.id) ~= "string" or discussion.id == "" then return false end
  for _, note in ipairs(discussion.notes or {}) do
    if not note.system and note.resolvable == true and note.resolved == false then return true end
  end
  return false
end

function M.resolve(target, discussion)
  if type(discussion.id) ~= "string" or discussion.id == "" then
    error("This conversation has no valid GitLab discussion ID.", 0)
  end
  local endpoint = M.mr_path(target) .. "/discussions/" .. url.encode(discussion.id)
  local current = M.request(target, endpoint)
  if type(current) ~= "table" or current.id ~= discussion.id or type(current.notes) ~= "table" then
    error("The original GitLab conversation is no longer available. Refresh the review.", 0)
  end
  if M.is_resolved(current) then return comment_metadata(target, current), false end
  if not M.can_resolve(current) then error("This GitLab conversation cannot be resolved.", 0) end
  local original_root, current_root = threads.root(discussion), threads.root(current)
  if not original_root or not current_root or original_root.id ~= current_root.id then
    error("The original GitLab comment is no longer available. Refresh the review.", 0)
  end
  local expected = {}
  for _, note in ipairs(discussion.notes or {}) do
    if not note.system then
      if type(note.id) ~= "number" or note.id <= 0 or note.id % 1 ~= 0 then
        error("This conversation has no valid GitLab comment ID. Refresh the review.", 0)
      end
      expected[note.id] = note
    end
  end
  for _, note in ipairs(current.notes) do
    if not note.system then
      local old = expected[note.id]
      if not old or old.body ~= note.body then
        error("This conversation changed. Refresh and read it before resolving it.", 0)
      end
    end
  end
  local result = M.request(target, endpoint, { resolved = true }, "PUT")
  if type(result) ~= "table" or result.id ~= discussion.id or not M.is_resolved(result) then
    error("GitLab did not confirm the resolved conversation. Check the MR before retrying.", 0)
  end
  -- Keep known reactions until the subsequent read-only refresh. A failed
  -- reaction read must never turn a confirmed resolution into an uncertain one.
  for _, note in ipairs(result.notes or {}) do
    local old = expected[note.id]
    if old then note.reactions, note.reactions_error = old.reactions, old.reactions_error end
  end
  return comment_metadata(target, result), true
end

function M.post(target, draft)
  -- Only the explicit submission flow calls this method.
  return M.request(target, M.mr_path(target) .. "/discussions", {
    body = draft.body,
    position = draft.position,
  })
end

function M.approve(target, refs)
  -- Approval is only sent by the explicit :ReviewApprove command.
  return M.request(target, M.mr_path(target) .. "/approve", { sha = refs.head_sha })
end

function M.status(target, mr)
  local pipeline = type(mr.head_pipeline) == "table" and mr.head_pipeline or nil
  return {
    pipeline = {
      state = pipeline and status.pipeline({ pipeline.status or "unknown" }) or "none",
      id = pipeline and type(pipeline.id) == "number" and pipeline.id or nil,
      web_url = pipeline and type(pipeline.web_url) == "string" and pipeline.web_url or nil,
    },
    review = status.read(function()
      local approvals = M.request(target, M.mr_path(target) .. "/approvals")
      local reviewers, by_user = {}, {}
      for _, reviewer in ipairs(M.pages(target, M.mr_path(target) .. "/reviewers")) do
        local user = type(reviewer.user) == "table" and reviewer.user.username
        if user then
          local decision = {
            username = user,
            state = reviewer.state == "requested_changes" and "changes_requested"
              or (type(reviewer.state) == "string" and reviewer.state or "unknown"),
          }
          reviewers[#reviewers + 1], by_user[user] = decision, decision
        end
      end
      for _, entry in ipairs(approvals.approved_by or {}) do
        local user = type(entry.user) == "table" and entry.user.username
        if user then
          if by_user[user] then
            if by_user[user].state ~= "changes_requested" then by_user[user].state = "approved" end
          else reviewers[#reviewers + 1] = { username = user, state = "approved" } end
        end
      end
      table.sort(reviewers, function(a, b) return a.username < b.username end)
      local state = approvals.approved == true and "approved" or "pending"
      for _, reviewer in ipairs(reviewers) do
        if reviewer.state == "changes_requested" then state = "changes_requested" end
      end
      if mr.detailed_merge_status == "requested_changes" then state = "changes_requested" end
      return {
        state = state, approvals = #(approvals.approved_by or {}),
        required = type(approvals.approvals_required) == "number" and approvals.approvals_required or nil,
        reviewers = reviewers,
      }
    end),
  }
end

local function positive_id(value)
  return type(value) == "number" and value > 0 and value % 1 == 0
end

local function pipeline_metadata(pipeline)
  if type(pipeline) ~= "table" or not positive_id(pipeline.id) then
    error("GitLab returned an invalid pipeline ID.", 0)
  end
  local user = type(pipeline.user) == "table" and pipeline.user or {}
  return {
    id = pipeline.id,
    project_id = positive_id(pipeline.project_id) and pipeline.project_id or nil,
    name = pipeline.name, state = pipeline.status or "unknown",
    ref = pipeline.ref, sha = pipeline.sha, source = pipeline.source,
    created_at = pipeline.created_at, updated_at = pipeline.updated_at,
    started_at = pipeline.started_at, finished_at = pipeline.finished_at,
    duration = pipeline.duration, queued_duration = pipeline.queued_duration,
    web_url = pipeline.web_url, user_name = user.name, user_username = user.username,
  }
end

local function job_metadata(job, project_id, trigger)
  if type(job) ~= "table" or not positive_id(job.id) then
    error("GitLab returned an invalid pipeline job.", 0)
  end
  local pipeline = type(job.pipeline) == "table" and job.pipeline or {}
  local commit = type(job.commit) == "table" and job.commit or {}
  local runner = type(job.runner) == "table" and job.runner or {}
  local user = type(job.user) == "table" and job.user or {}
  local downstream = type(job.downstream_pipeline) == "table" and job.downstream_pipeline or nil
  return {
    id = job.id, name = job.name, stage = job.stage, state = job.status or "unknown",
    project_id = positive_id(pipeline.project_id) and pipeline.project_id or project_id,
    pipeline_id = positive_id(pipeline.id) and pipeline.id or nil,
    ref = job.ref or pipeline.ref, sha = commit.id or pipeline.sha,
    duration = job.duration, queued_duration = job.queued_duration,
    created_at = job.created_at, started_at = job.started_at, finished_at = job.finished_at,
    erased_at = job.erased_at, allow_failure = job.allow_failure == true,
    failure_reason = job.failure_reason, runner = runner.description,
    user_name = user.name, user_username = user.username,
    web_url = job.web_url, trigger = trigger == true,
    downstream = downstream and pipeline_metadata(downstream) or nil,
  }
end

function M.pipelines(target)
  local pipelines = {}
  for _, pipeline in ipairs(M.pages(target, M.mr_path(target) .. "/pipelines")) do
    pipelines[#pipelines + 1] = pipeline_metadata(pipeline)
  end
  table.sort(pipelines, function(a, b) return a.id > b.id end)
  return pipelines
end

function M.pipeline_details(target, pipeline)
  if not positive_id(pipeline.id) then error("This pipeline has no valid GitLab ID.", 0) end
  -- Fork pipelines belong to their own project, which can differ from the MR.
  local project = positive_id(pipeline.project_id) and ("projects/" .. pipeline.project_id) or M.project_path(target)
  local endpoint = project .. "/pipelines/" .. pipeline.id
  local result = pipeline_metadata(M.request(target, endpoint))
  if result.id ~= pipeline.id or (pipeline.project_id and result.project_id ~= pipeline.project_id) then
    error("GitLab returned a different pipeline.", 0)
  end
  result.jobs = {}
  local function append_jobs(jobs, trigger)
    for _, job in ipairs(jobs) do
      local value = job_metadata(job, result.project_id or pipeline.project_id, trigger)
      value.pipeline_id = value.pipeline_id or result.id
      result.jobs[#result.jobs + 1] = value
    end
  end
  local ok, jobs = pcall(M.pages, target, endpoint .. "/jobs")
  if ok then append_jobs(jobs, false) else result.jobs_error = tostring(jobs) end
  local bridges_ok, bridges = pcall(M.pages, target, endpoint .. "/bridges")
  if bridges_ok then append_jobs(bridges, true) else result.bridges_error = tostring(bridges) end
  table.sort(result.jobs, function(a, b) return a.id < b.id end)
  return result
end

local function job_path(target, job)
  if type(job) ~= "table" or not positive_id(job.id) then
    error("This job has no valid GitLab ID.", 0)
  end
  if job.trigger then error("Downstream pipeline triggers do not have job logs.", 0) end
  local project = positive_id(job.project_id) and ("projects/" .. job.project_id) or M.project_path(target)
  return project .. "/jobs/" .. job.id
end

function M.job_details(target, job)
  local result = job_metadata(M.request(target, job_path(target, job)), job.project_id, false)
  if result.id ~= job.id or (job.project_id and result.project_id ~= job.project_id)
      or (job.pipeline_id and result.pipeline_id ~= job.pipeline_id) then
    error("GitLab returned a different job.", 0)
  end
  return result
end

function M.job_trace(target, job)
  return M.request(target, job_path(target, job) .. "/trace", nil, "GET", true)
end

function M.validate_request_changes(target)
  -- Introspection is read-only and detects older GitLab installations before
  -- any comments are published by the combined submission flow.
  local result = M.request(target, "graphql", {
    query = "{ __type(name: \"Mutation\") { fields { name } } }",
  })
  local data = type(result) == "table" and result.data
  local mutation = type(data) == "table" and data.__type
  -- Some GitLab versions serve a cached complete introspection response even
  -- for a targeted __type query. The Mutation fields then live in schema.types.
  if type(mutation) ~= "table" and type(data) == "table" and type(data.__schema) == "table" then
    for _, candidate in ipairs(data.__schema.types or {}) do
      if candidate.name == "Mutation" then mutation = candidate; break end
    end
  end
  if type(mutation) == "table" then
    for _, field in ipairs(mutation.fields or {}) do
      if field.name == "mergeRequestRequestChanges" then return end
    end
  end
  error("This GitLab server does not expose the Request changes API. Use its web interface.", 0)
end

function M.request_changes(target)
  local result = M.request(target, "graphql", {
    query = [[mutation($input: MergeRequestRequestChangesInput!) {
      mergeRequestRequestChanges(input: $input) { errors mergeRequest { iid } }
    }]],
    variables = { input = { projectPath = target.project, iid = tostring(target.iid) } },
  })
  local data = type(result) == "table" and result.data
  local payload = type(data) == "table" and data.mergeRequestRequestChanges
  local errors = type(payload) == "table" and payload.errors
  if type(errors) == "table" and #errors > 0 then
    error("GitLab refused Request changes: " .. table.concat(errors, "; "), 0)
  end
  if type(payload) ~= "table" or type(errors) ~= "table"
      or type(payload.mergeRequest) ~= "table" or tostring(payload.mergeRequest.iid) ~= tostring(target.iid)
      or (type(result.errors) == "table" and #result.errors > 0) then
    error("GitLab did not confirm Request changes. Check the MR before retrying.", 0)
  end
  return payload.mergeRequest
end

function M.reply_target(discussion)
  local root = threads.root(discussion)
  if type(discussion.id) ~= "string" or discussion.id == ""
      or not root or type(root.id) ~= "number" or root.id <= 0 or root.id % 1 ~= 0 then
    return nil, "GitLab did not expose a valid discussion and root comment ID."
  end
  return { discussion_id = discussion.id, note_id = root.id }
end

local function reply_path(target, draft)
  local reply = draft.reply
  if type(reply) ~= "table" or type(reply.discussion_id) ~= "string" or reply.discussion_id == ""
      or type(reply.note_id) ~= "number" or reply.note_id <= 0 or reply.note_id % 1 ~= 0 then
    error("This reply has no valid GitLab discussion target. Recreate the reply draft.", 0)
  end
  return M.mr_path(target) .. "/discussions/" .. url.encode(reply.discussion_id)
end

function M.validate_reply(target, draft)
  local discussion = M.request(target, reply_path(target, draft))
  if type(discussion) == "table" and discussion.id == draft.reply.discussion_id then
    for _, note in ipairs(discussion.notes or {}) do
      if note.id == draft.reply.note_id and not note.system then return end
    end
  end
  error("The original GitLab comment is no longer available. The reply remains local.", 0)
end

function M.reply(target, draft)
  -- Only explicit submission may publish a reply; it creates a note in the
  -- existing discussion, with no new position and no resolution change.
  local response = M.request(target, reply_path(target, draft) .. "/notes", { body = draft.body })
  if type(response) ~= "table" or type(response.id) ~= "number" or response.id <= 0 then
    error("GitLab did not confirm the reply comment ID.", 0)
  end
  return response
end

return M
