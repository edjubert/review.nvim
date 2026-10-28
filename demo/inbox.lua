local M = {}

local function matches_query(message, query)
  local subject = message.subject:lower()
  return subject:find(query, 1, true) ~= nil
end

local function newest_first(left, right)
  return left.received_at > right.received_at
end

function M.filter(messages, options)
  local query = options.query:lower()
  local matches = {}

  for _, message in ipairs(messages) do
    if matches_query(message, query) then
      matches[#matches + 1] = message
    end
  end

  table.sort(matches, newest_first)
  return matches
end

function M.summary(messages)
  local unread = 0
  for _, message in ipairs(messages) do
    if not message.read then
      unread = unread + 1
    end
  end
  return ("%d messages · %d unread"):format(#messages, unread)
end

return M
