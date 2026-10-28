local M = {}
function M.for_target(target)
  if target.provider == "gitlab" then return require("review.providers.gitlab") end
  if target.provider == "github" then return require("review.providers.github") end
  if target.provider == "codeberg" then return require("review.providers.codeberg") end
  error("Unsupported review provider: " .. tostring(target.provider), 0)
end
return M
