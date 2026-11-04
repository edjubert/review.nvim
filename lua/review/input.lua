local M = {}

local function accept(value, callback)
  if not value then return end
  value = vim.trim(value)
  if value == "" then return end
  local target, err = require("review.url").parse(value)
  if not target then
    vim.notify(err, vim.log.levels.ERROR, { title = "review" })
    return false
  end
  callback(value)
  return true
end

local function label(entry)
  return entry.title ~= "" and entry.title .. "  ·  " .. entry.url or entry.url
end

function M.url(callback, config)
  config = config or require("review").config
  local loaded, recent = pcall(require("review.history").list, config)
  if not loaded then
    vim.notify(recent, vim.log.levels.WARN, { title = "review" })
    recent = {}
  end
  local ok, telescope = pcall(function()
    return {
      pickers = require("telescope.pickers"),
      finders = require("telescope.finders"),
      config = require("telescope.config").values,
      actions = require("telescope.actions"),
      action_set = require("telescope.actions.set"),
      action_state = require("telescope.actions.state"),
    }
  end)
  if not ok then
    local function enter_url()
      vim.ui.input({ prompt = "GitLab MR / GitHub PR / Codeberg PR URL: " }, function(value)
        accept(value, callback)
      end)
    end
    if #recent == 0 then enter_url(); return end
    local choices = { { new = true } }
    vim.list_extend(choices, recent)
    vim.ui.select(choices, {
      prompt = "Open a review",
      format_item = function(entry) return entry.new and "Enter another MR/PR URL…" or label(entry) end,
    }, function(entry)
      if not entry then return end
      if entry.new then enter_url() else accept(entry.url, callback) end
    end)
    return
  end
  telescope.pickers.new({}, {
    prompt_title = "Enter a GitLab MR / GitHub PR / Codeberg PR URL",
    results_title = "Recent reviews · Enter: open · Esc: cancel",
    finder = telescope.finders.new_table({
      results = recent,
      entry_maker = function(entry)
        return { value = entry, display = label(entry), ordinal = label(entry) }
      end,
    }),
    sorter = telescope.config.generic_sorter({}),
    previewer = false,
    initial_mode = "insert",
    layout_strategy = "center",
    layout_config = { width = 0.85, height = #recent == 0 and 8 or 0.5 },
    attach_mappings = function(prompt_bufnr, map)
      local function submit()
        local value = telescope.action_state.get_current_line()
        local entry = telescope.action_state.get_selected_entry()
        -- A pasted URL wins over a highlighted history match. Otherwise the
        -- prompt is a search query and Enter opens its selected recent review.
        if entry and not vim.trim(value):match("^https?://") then value = entry.value.url end
        accept(value, function(url)
          telescope.actions.close(prompt_bufnr)
          vim.schedule(function() callback(url) end)
        end)
      end
      -- Never let a selection variant interpret the entered URL as a file.
      telescope.action_set.select:replace(submit)
      telescope.action_set.edit:replace(submit)
      map("i", "<Esc>", telescope.actions.close)
      return true
    end,
  }):find()
end

return M
