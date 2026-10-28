local async = require("review.async")
local url = require("review.url")
local position = require("review.position")
local M = { name = "GitLab", cli = "glab", kind = "MR", label = "merge request", prefix = "!" }

function M.head_ref(target)
  return ("refs/merge-requests/%d/head"):format(target.iid)
end

M.build_position = position.build

function M.request(target, endpoint, body)
  local argv = { "glab", "api", "--hostname", target.host, "--method", body and "POST" or "GET", endpoint }
  local opts = {}
  if body then
    vim.list_extend(argv, { "--input", "-" })
    opts.stdin = vim.json.encode(body)
  end
  local output = async.checked(argv, opts)
  local ok, data = pcall(vim.json.decode, output)
  if not ok then error("GitLab returned an invalid JSON response.", 0) end
  return data
end

function M.project_path(target)
  return "projects/" .. url.encode(target.project)
end

function M.mr_path(target)
  return M.project_path(target) .. "/merge_requests/" .. target.iid
end

function M.pages(target, endpoint)
  local all = {}
  for page = 1, 1000 do
    local data = M.request(target, endpoint .. "?per_page=100&page=" .. page)
    if type(data) ~= "table" or not vim.islist(data) then error("Expected a GitLab result list.", 0) end
    vim.list_extend(all, data)
    if #data < 100 then return all end
  end
  error("GitLab pagination exceeded 1000 pages; refusing an incomplete result.", 0)
end

function M.load(target)
  local endpoint = M.mr_path(target)
  local mr = M.request(target, endpoint)
  if type(mr.diff_refs) ~= "table"
      or type(mr.diff_refs.head_sha) ~= "string"
      or type(mr.diff_refs.base_sha) ~= "string"
      or type(mr.diff_refs.start_sha) ~= "string" then
    error("GitLab is still preparing the MR diff. Try again shortly.", 0)
  end
  local commits = M.pages(target, endpoint .. "/commits")
  -- GitLab returns newest first; browsing starts at the oldest commit.
  local ordered = {}
  for i = #commits, 1, -1 do ordered[#ordered + 1] = commits[i] end
  return {
    mr = mr,
    commits = ordered,
    project = M.request(target, M.project_path(target)),
    diffs = M.pages(target, endpoint .. "/diffs"),
    discussions = M.pages(target, endpoint .. "/discussions"),
  }
end

function M.current(target)
  return M.request(target, M.mr_path(target))
end

function M.discussions(target)
  return M.pages(target, M.mr_path(target) .. "/discussions")
end

function M.post(target, draft)
  -- Only the explicit submission flow calls this method.
  return M.request(target, M.mr_path(target) .. "/discussions", {
    body = draft.body,
    position = draft.position,
  })
end

return M
