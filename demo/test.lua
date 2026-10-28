local inbox = dofile("demo/inbox.lua")

local messages = {
  { subject = "Release checklist", read = true, received_at = 10 },
  { subject = "Weekly digest", read = false, received_at = 30 },
  { subject = "RELEASE notes", read = false, received_at = 20 },
}

local tests = {
  {
    name = "defaults to all messages, newest first",
    options = nil,
    expected = { "Weekly digest", "RELEASE notes", "Release checklist" },
  },
  {
    name = "accepts an empty options table",
    options = {},
    expected = { "Weekly digest", "RELEASE notes", "Release checklist" },
  },
  {
    name = "matches part of a subject regardless of case",
    options = { query = "ReLeAsE" },
    expected = { "RELEASE notes", "Release checklist" },
  },
  {
    name = "shows unread messages only",
    options = { unread_only = true },
    expected = { "Weekly digest", "RELEASE notes" },
  },
  {
    name = "combines search with the unread filter",
    options = { query = "release", unread_only = true },
    expected = { "RELEASE notes" },
  },
  {
    name = "returns an empty collection when nothing matches",
    options = { query = "missing" },
    expected = {},
  },
}

for _, test in ipairs(tests) do
  local result = inbox.filter(messages, test.options)
  assert(#result == #test.expected, test.name)
  for index, subject in ipairs(test.expected) do
    assert(result[index].subject == subject, test.name)
  end
end

assert(messages[1].subject == "Release checklist", "preserves input order")
assert(inbox.summary(messages) == "3 messages · 2 unread", "preserves read flags")
print(("Inbox demo: %d cases passed."):format(#tests))
