local M = {}
function M.check()
  vim.health.start("review.nvim")
  if vim.fn.has("nvim-0.11") == 1 then vim.health.ok("Neovim >= 0.11")
  else vim.health.error("Neovim >= 0.11 is required") end
  if vim.fn.executable("git") == 1 then vim.health.ok("git found")
  else vim.health.error("git is not in PATH") end
  for _, tool in ipairs({ "glab", "gh" }) do
    if vim.fn.executable(tool) == 1 then vim.health.ok(tool .. " found")
    else vim.health.info(tool .. " is optional; install it to use " .. (tool == "gh" and "GitHub" or "GitLab") .. ".") end
  end
  if vim.fn.executable("curl") == 1 then vim.health.ok("curl found (Codeberg)")
  else vim.health.info("curl is optional; install it to use Codeberg.") end
  vim.health.info("Authenticate with glab auth login --hostname <your-gitlab-host>.")
  vim.health.info("Authenticate with gh auth login --hostname <your-github-host>.")
  vim.health.info("Codeberg uses curl; set CODEBERG_TOKEN in the environment for private repositories or publication.")
  vim.health.info("SSH cloning uses your existing Git credentials; no tokens are read from local files.")
end
return M
