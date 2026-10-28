local M = {}
function M.for_target(target)
  if target.provider == "gitlab" then return require("review.providers.gitlab") end
  error("Unsupported review provider: " .. tostring(target.provider), 0)
end
return M
