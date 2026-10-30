local emoji = require("review.emoji")
local async = require("review.async")
local M = {}
local concurrency = 4

-- Reuse this limiter across refreshes: canceled reads still occupy their slots
-- until their transports return, rather than allowing the next batch to exceed
-- the limit while old requests are in flight.
function M.limiter()
  return { running = 0, waiting = {} }
end

local function acquire(limiter)
  if limiter.running < concurrency then
    limiter.running = limiter.running + 1
  else
    coroutine.yield(function(done) limiter.waiting[#limiter.waiting + 1] = done end)
  end
end

local function release(limiter)
  local done = table.remove(limiter.waiting, 1)
  if done then done()
  else limiter.running = limiter.running - 1 end
end

-- Reaction endpoints are optional reads. Limit simultaneous requests and check
-- the snapshot again after each read before applying anything to its notes.
function M.load(provider, target, discussions, opts)
  opts = opts or {}
  if not provider.note_reactions then return 0 end
  local function active() return not opts.active or opts.active() end
  if not active() then return 0 end
  local notes = {}
  for _, discussion in ipairs(discussions) do
    for _, note in ipairs(discussion.notes or {}) do
      if not note.system and type(note.id) == "number" and note.id > 0 and note.id % 1 == 0 then
        note.reactions_loading = true
        notes[#notes + 1] = note
      end
    end
  end
  if #notes == 0 then return 0 end
  if opts.on_update then opts.on_update() end
  local limiter = opts.limiter or M.limiter()
  local next_note, failures, workers = 1, 0, {}
  for index = 1, math.min(concurrency, #notes) do
    workers[index] = function()
      while active() do
        local note = notes[next_note]
        if not note then return end
        next_note = next_note + 1
        acquire(limiter)
        if not active() then release(limiter); return end
        local ok, result = pcall(provider.note_reactions, target, note)
        release(limiter)
        if not active() then return end
        note.reactions_loading = nil
        if ok then
          note.reactions, note.reactions_error = result, nil
        else
          failures = failures + 1
          note.reactions_error = tostring(result)
        end
        if opts.on_update then opts.on_update() end
      end
    end
  end
  async.all(workers)
  return failures
end

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
  if note.reactions_error and not note.reactions_loading then return "Reactions unavailable" end
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
  if #parts > 0 then
    return "Reactions: " .. table.concat(parts, " · ") .. (note.reactions_loading and " · loading…" or "")
  end
  return note.reactions_loading and "Reactions loading…" or nil
end

return M
