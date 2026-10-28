local M = {}

function M.encode(value)
  return (value:gsub("[^%w%-_%.~]", function(char)
    return ("%%%02X"):format(char:byte())
  end))
end

function M.parse(url)
  local scheme, host, path = url:match("^(https?)://([^/]+)(/[^?#]*)")
  if not scheme or not host:match("^[%w%.%-]+:?%d*$") or host:find("@", 1, true) then
    return nil, "Expected an HTTP(S) GitLab merge request URL."
  end
  local project, iid, suffix = path:match("^/(.-)/%-/merge_requests/(%d+)(.*)$")
  if not project or (suffix ~= "" and suffix:sub(1, 1) ~= "/") or tonumber(iid) < 1 then
    return nil, "Expected https://gitlab.example/group/project/-/merge_requests/123."
  end
  project = project:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end)
  for part in project:gmatch("[^/]+") do
    if part == "." or part == ".." or part:find("[%c\\]") then
      return nil, "Invalid project path."
    end
  end
  if project == "" or project:find("//", 1, true) or project:find("%%") then
    return nil, "Invalid project path."
  end
  return {
    provider = "gitlab",
    host = host:lower(),
    project = project,
    iid = tonumber(iid),
    url = ("%s://%s/%s/-/merge_requests/%d"):format(scheme, host:lower(), project, tonumber(iid)),
  }
end

function M.remote_matches(remote, target)
  remote = vim.trim(remote):gsub("%.git$", ""):gsub("/$", "")
  local host, path = remote:match("^[%w._%-]+@([^:]+):(.+)$")
  if not host then
    host, path = remote:match("^%w+://([^/]+)/(.+)$")
    if host then host = host:gsub("^.-@", "") end
  end
  return host and host:lower() == target.host and path == target.project
end

return M
