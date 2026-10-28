-- The first inbox implementation only supported exact subject matches.
local M = {}

function M.matches(message, subject)
  return message.subject == subject
end

return M
