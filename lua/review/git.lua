local async = require("review.async")
local url = require("review.url")
local M = {}

function M.run(repo, args)
  return async.checked(vim.list_extend({ "git", "-C", repo }, args))
end

function M.prepare(target, project, config)
  local repo = config.repo
  if not repo then
    local cwd = vim.fn.getcwd()
    local root = async.system({ "git", "-C", cwd, "rev-parse", "--show-toplevel" })
    if root.code == 0 then
      local candidate = vim.trim(root.stdout)
      local remote = async.system({ "git", "-C", candidate, "remote", "get-url", "origin" })
      if remote.code == 0 and url.remote_matches(remote.stdout, target) then repo = candidate end
    end
  end
  if not repo then
    repo = config.cache_dir .. "/repos/" .. vim.fn.sha256(target.host .. "/" .. target.project)
    if not vim.uv.fs_stat(repo .. "/HEAD") then
      vim.fn.mkdir(repo, "p")
      async.checked({ "git", "init", "--bare", repo })
    end
  end
  repo = vim.fn.fnamemodify(repo, ":p"):gsub("/$", "")
  local clone_url = config.clone_protocol == "https" and project.http_url_to_repo or project.ssh_url_to_repo
  if type(clone_url) ~= "string"
      or not (clone_url:match("^https?://") or clone_url:match("^ssh://") or clone_url:match("^[%w._%-]+@[^:]+:")) then
    error("GitLab did not provide a valid clone URL.", 0)
  end
  M.run(repo, {
    "fetch", "--no-tags", "--no-write-fetch-head", "--force", clone_url,
    ("+refs/merge-requests/%d/head:refs/review/%d/head"):format(target.iid, target.iid),
  })
  return repo
end

function M.has(repo, sha)
  local result = async.system({ "git", "-C", repo, "cat-file", "-e", sha .. "^{commit}" })
  return result.code == 0
end

function M.ensure(repo, sha, project, config)
  if not sha or not sha:match("^%x+$") then error("Invalid Git commit SHA.", 0) end
  if not M.has(repo, sha) then
    local clone_url = config.clone_protocol == "https" and project.http_url_to_repo or project.ssh_url_to_repo
    M.run(repo, { "fetch", "--no-tags", "--no-write-fetch-head", clone_url, sha })
  end
end

function M.files(repo, base, head)
  local output = M.run(repo, {
    "diff", "--no-ext-diff", "--no-textconv", "--name-status", "-z", "--find-renames", base, head, "--",
  })
  local fields = vim.split(output, "\0", { plain = true, trimempty = true })
  local files, i = {}, 1
  while i <= #fields do
    local status = fields[i]
    local old_path, new_path = fields[i + 1], fields[i + 1]
    i = i + 2
    if status:match("^[RC]") then new_path = fields[i]; i = i + 1 end
    files[#files + 1] = {
      status = status:sub(1, 1),
      old_path = old_path,
      new_path = new_path,
      new_file = status:sub(1, 1) == "A",
      deleted_file = status:sub(1, 1) == "D",
    }
  end
  return files
end

function M.content(repo, sha, path)
  return M.run(repo, { "show", "--no-ext-diff", "--no-textconv", sha .. ":" .. path })
end

function M.rename_path(repo, from, to, path)
  if from == to then return path end
  for _, file in ipairs(M.files(repo, from, to)) do
    if file.old_path == path then
      if file.deleted_file then return nil end
      return file.new_path
    end
  end
  return path
end

return M
