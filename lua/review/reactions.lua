local emoji = require("review.emoji")
local M = {}

local function sorted(groups)
  local list = {}
  for _, group in pairs(groups) do
    table.sort(group.users)
    list[#list + 1] = group
  end
  table.sort(list, function(a, b) return a.name < b.name end)
  return list
end

function M.aggregate(awards)
  local groups = {}
  for _, award in ipairs(awards) do
    local name = award.name or award.content
    if type(name) == "string" and name ~= "" and not name:find("%c") then
      local group = groups[name]
      if not group then
        group = { name = name, count = 0, users = {} }
        groups[name] = group
      end
      group.count = group.count + 1
      local user = type(award.user) == "table" and (award.user.username or award.user.login)
      if type(user) == "string" and user ~= "" then group.users[#group.users + 1] = user end
    end
  end
  return sorted(groups)
end

function M.summary(counts)
  local groups = {}
  if type(counts) ~= "table" then return {} end
  for _, name in ipairs({ "+1", "-1", "laugh", "hooray", "confused", "heart", "rocket", "eyes" }) do
    local count = counts[name]
    if type(count) == "number" and count > 0 and count % 1 == 0 then
      groups[name] = { name = name, count = count, users = {} }
    end
  end
  return sorted(groups)
end

function M.text(note, with_users)
  if note.reactions_error then return "Reactions unavailable" end
  local parts = {}
  for _, reaction in ipairs(note.reactions or {}) do
    local name = reaction.name
    local label = name:match("^[%w_+%-]+$") and emoji.render(":" .. name .. ":") or name
    local text = label .. " " .. reaction.count
    if with_users and #(reaction.users or {}) > 0 then
      local users = {}
      for _, user in ipairs(reaction.users) do users[#users + 1] = "@" .. user:gsub("[%c]", " ") end
      text = text .. " (" .. table.concat(users, ", ") .. ")"
    end
    parts[#parts + 1] = text
  end
  return #parts > 0 and ("Reactions: " .. table.concat(parts, " · ")) or nil
end

return M
