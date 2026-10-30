local M = {}

-- Optional status endpoints must not prevent reading the review diff.
function M.read(fn)
  local ok, result = pcall(fn)
  if ok then return result end
  return { state = "unknown", error = tostring(result) }
end

function M.pipeline(states)
  if #states == 0 then return "none" end
  local priority = {
    none = 0, skipped = 1, neutral = 1, success = 2,
    canceled = 3, cancelled = 3, unknown = 4,
    pending = 5, queued = 5, created = 5, waiting_for_resource = 5,
    running = 6, in_progress = 6, preparing = 6,
    manual = 7, blocked = 7, action_required = 7,
    failed = 8, failure = 8, error = 8, timed_out = 8, startup_failure = 8,
  }
  local selected, rank = "none", 0
  for _, state in ipairs(states) do
    local value = priority[state] and state or "unknown"
    if priority[value] > rank then selected, rank = value, priority[value] end
  end
  local normalized = {
    failure = "failed", error = "failed", timed_out = "failed", startup_failure = "failed",
    in_progress = "running", preparing = "running", cancelled = "canceled",
    queued = "pending", created = "pending", waiting_for_resource = "pending",
    action_required = "blocked", neutral = "skipped",
  }
  return normalized[selected] or selected
end

-- Comment-only reviews do not revoke an existing approval or change request.
-- The APIs return reviews oldest first; dismissed decisions clear that user.
function M.reviews(reviews)
  local decisions = {}
  for _, review in ipairs(reviews) do
    local user = type(review.user) == "table" and review.user.login
    local state = ({
      APPROVED = "approved", CHANGES_REQUESTED = "changes_requested",
      REQUEST_CHANGES = "changes_requested", DISMISSED = "pending",
    })[review.state]
    if user and state then
      decisions[user] = {
        username = user,
        state = review.dismissed and "pending" or state,
        stale = review.stale == true,
      }
    end
  end
  local result = { state = "pending", approvals = 0, reviewers = {} }
  for _, decision in pairs(decisions) do
    result.reviewers[#result.reviewers + 1] = decision
    if decision.state == "changes_requested" then result.state = "changes_requested" end
    if decision.state == "approved" and not decision.stale then result.approvals = result.approvals + 1 end
  end
  table.sort(result.reviewers, function(a, b) return a.username < b.username end)
  if result.state ~= "changes_requested" and result.approvals > 0 then result.state = "approved" end
  return result
end

function M.label(state)
  if type(state) ~= "string" then return "unavailable" end
  return ({
    none = "none", unknown = "unavailable", loading = "loading…", pending = "pending",
    approved = "approved", changes_requested = "changes requested",
    review_started = "in progress", reviewed = "reviewed",
    unreviewed = "pending", unapproved = "approval revoked",
  })[state] or state:gsub("_", " ")
end

function M.highlight(state)
  if state == "approved" or state == "success" then return "ReviewStatusOk" end
  if state == "changes_requested" or state == "failed" then return "ReviewStatusError" end
  if state == "none" or state == "unknown" or state == "skipped" then return "ReviewHelp" end
  return "ReviewStatusWarn"
end

return M
