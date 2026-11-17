local M = {}

-- A stack is a chain of open reviews where each review targets the source
-- branch of the review below it. Providers normalize their list to
-- { iid, title, state, draft, source_branch, target_branch, url }.
-- Entries are ordered from the review closest to the base branch to the tip.
function M.build(current, reviews)
  if type(current) ~= "table" or type(current.iid) ~= "number" then return nil end
  local by_iid, by_source, children = {}, {}, {}
  local function add(review)
    if type(review) ~= "table" or type(review.iid) ~= "number" or by_iid[review.iid] then return end
    by_iid[review.iid] = review
    local source, target = review.source_branch, review.target_branch
    if type(source) == "string" and source ~= "" then
      -- Two reviews sharing a source branch make the chain ambiguous.
      if by_source[source] == nil then by_source[source] = review
      elseif by_source[source] ~= false then by_source[source] = false end
    end
    if type(target) == "string" and target ~= "" then
      children[target] = children[target] or {}
      children[target][#children[target] + 1] = review
    end
  end
  add(current)
  for _, review in ipairs(reviews or {}) do add(review) end
  local function parent(review)
    local candidate = by_source[review.target_branch]
    if candidate and candidate.iid ~= review.iid then return candidate end
  end
  local function child(review)
    local list = children[review.source_branch]
    -- A branch targeted by several reviews is parallel work, not a stack.
    if not list or #list ~= 1 or list[1].iid == review.iid then return nil end
    return list[1]
  end
  local seen = { [current.iid] = true }
  local below, above = {}, {}
  local node = current
  while true do
    local candidate = parent(node)
    if not candidate or seen[candidate.iid] then break end
    seen[candidate.iid] = true
    table.insert(below, 1, candidate)
    node = candidate
  end
  node = current
  while true do
    local candidate = child(node)
    if not candidate or seen[candidate.iid] then break end
    seen[candidate.iid] = true
    above[#above + 1] = candidate
    node = candidate
  end
  local entries = {}
  vim.list_extend(entries, below)
  entries[#entries + 1] = current
  vim.list_extend(entries, above)
  if #entries < 2 then return nil end
  return { entries = entries, index = #below + 1 }
end

return M
