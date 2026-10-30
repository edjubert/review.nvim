local M = {}
local async = require("review.async")
function M.for_target(target)
  if target.provider == "gitlab" then return require("review.providers.gitlab") end
  if target.provider == "github" then return require("review.providers.github") end
  if target.provider == "codeberg" then return require("review.providers.codeberg") end
  error("Unsupported review provider: " .. tostring(target.provider), 0)
end

-- Complete snapshot for callers that do not need progressive UI updates.
function M.load(target)
  local provider = M.for_target(target)
  local mr = provider.info(target)
  local context
  if provider.references then mr, context = provider.references(target, mr) end
  local data = async.all({
    project = function() return provider.project(target) end,
    commits = function() return provider.commits(target, mr, context) end,
    diffs = function() return provider.diffs(target, mr) end,
  })
  data.mr = mr
  data.discussions = provider.discussions(target, mr.diff_refs, data.diffs)
  return data
end
return M
