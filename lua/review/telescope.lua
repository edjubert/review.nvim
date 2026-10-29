local async = require("review.async")
local status = require("review.status")
local viewed = require("review.viewed")
local M = {}
local telescope

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "review" })
end

function M.available(command)
  if telescope then return true end
  local ok, modules = pcall(function()
    return {
      pickers = require("telescope.pickers"),
      finders = require("telescope.finders"),
      previewers = require("telescope.previewers"),
      config = require("telescope.config").values,
      actions = require("telescope.actions"),
      action_state = require("telescope.actions.state"),
      display = require("telescope.pickers.entry_display"),
    }
  end)
  if ok then telescope = modules; return true end
  notify(":" .. (command or "ReviewPipelines") .. " requires telescope.nvim and plenary.nvim.", vim.log.levels.WARN)
  return false
end

local function text(value)
  if type(value) ~= "string" and type(value) ~= "number" then return "" end
  return (tostring(value):gsub("%c", " "))
end

local function duration(value)
  if type(value) ~= "number" or value < 0 then return "—" end
  local seconds = math.floor(value)
  if seconds < 60 then return seconds .. "s" end
  if seconds < 3600 then return ("%dm %02ds"):format(math.floor(seconds / 60), seconds % 60) end
  return ("%dh %02dm %02ds"):format(math.floor(seconds / 3600), math.floor(seconds / 60) % 60, seconds % 60)
end

local function field(lines, name, value)
  local label = text(value)
  if label ~= "" then lines[#lines + 1] = name .. ": " .. label end
end

local function metadata(value, kind)
  local lines = { "# " .. kind .. " #" .. value.id, "" }
  field(lines, "Name", value.name)
  field(lines, "Status", status.label(value.state))
  field(lines, "Stage", value.stage)
  field(lines, "Ref", value.ref)
  field(lines, "Commit", value.sha)
  field(lines, "Source", value.source)
  field(lines, "Project ID", value.project_id)
  field(lines, "Created", value.created_at)
  field(lines, "Updated", value.updated_at)
  field(lines, "Started", value.started_at)
  field(lines, "Finished", value.finished_at)
  field(lines, "Duration", duration(value.duration))
  if type(value.queued_duration) == "number" then field(lines, "Queued", duration(value.queued_duration)) end
  field(lines, "Failure reason", value.failure_reason)
  field(lines, "Runner", value.runner)
  if value.allow_failure ~= nil then field(lines, "Failure allowed", value.allow_failure and "yes" or "no") end
  if value.trigger then field(lines, "Type", "downstream pipeline trigger") end
  field(lines, "URL", value.web_url)
  if value.downstream then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "## Downstream pipeline #" .. value.downstream.id
    field(lines, "Status", value.downstream.state)
    field(lines, "Ref", value.downstream.ref)
    field(lines, "URL", value.downstream.web_url)
  end
  return lines
end

local function pipeline_preview(pipeline, head)
  local lines = metadata(pipeline, "Pipeline")
  field(lines, "Matches review head", pipeline.sha == head and "yes" or "no")
  if not pipeline.jobs then return lines end
  lines[#lines + 1], lines[#lines + 2] = "", "## Jobs"
  if pipeline.jobs_error then field(lines, "Jobs unavailable", pipeline.jobs_error) end
  if pipeline.bridges_error then field(lines, "Triggers unavailable", pipeline.bridges_error) end
  if #pipeline.jobs == 0 and not pipeline.jobs_error and not pipeline.bridges_error then
    lines[#lines + 1] = "No jobs in this pipeline."
  end
  for _, job in ipairs(pipeline.jobs) do
    lines[#lines + 1] = ("- %s · %s · %s · %s%s"):format(
      text(job.stage), text(job.name), text(status.label(job.state)), duration(job.duration),
      job.allow_failure and " (failure allowed)" or "")
    if job.failure_reason then lines[#lines + 1] = "  Failure: " .. text(job.failure_reason) end
    if job.downstream then
      lines[#lines + 1] = ("  Downstream #%d: %s"):format(job.downstream.id, text(status.label(job.downstream.state)))
    end
  end
  return lines
end

local function preview_buffer(buf, lines)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].modifiable = false
end

local function open_browser(value)
  local web_url = type(value.web_url) == "string" and value.web_url
    or (value.downstream and value.downstream.web_url)
  if type(web_url) ~= "string" or not web_url:match("^https?://%S+$") or web_url:find("%c") then
    notify("No browser URL is available for this selection.", vim.log.levels.WARN)
    return
  end
  local ok, job, err = pcall(vim.ui.open, web_url)
  if not ok or not job then notify(tostring(ok and err or job), vim.log.levels.ERROR) end
end

local function columns(value, job)
  local displayer = telescope.display.create({
    separator = "  ",
    items = { { width = 10 }, { width = 12 }, { remaining = true } },
  })
  return function()
    local state = status.pipeline({ value.state })
    return displayer({
      "#" .. value.id, { text(status.label(value.state)), status.highlight(state) },
      job and (text(value.name) .. " · " .. text(value.stage) .. " · " .. duration(value.duration))
        or (text(value.source) .. " · " .. text(value.sha):sub(1, 8) .. " · "
          .. text(value.ref) .. " · " .. text(value.created_at)),
    })
  end
end

function M.pipelines(session, pipelines)
  if not M.available() then return end
  local cache = {}
  local head = session.data.mr.diff_refs.head_sha
  local function session_open()
    return not session.closed and require("review.ui").valid(session)
  end
  -- A pipeline's preview and Enter action share the same pending request.
  local function details(pipeline, done)
    local key = tostring(pipeline.project_id or session.target.project) .. "/" .. pipeline.id
    local entry = cache[key]
    if entry then
      if entry.pending then entry.callbacks[#entry.callbacks + 1] = done
      else done(entry.value, entry.error) end
      return
    end
    entry = { pending = true, callbacks = { done } }
    cache[key] = entry
    local function finish(value, err)
      entry.pending, entry.value, entry.error = false, value, err
      local callbacks = entry.callbacks
      entry.callbacks = nil
      for _, callback in ipairs(callbacks) do callback(value, err) end
    end
    async.run(function()
      finish(session.provider.pipeline_details(session.target, pipeline))
    end, function(err)
      if entry.pending then finish(nil, err) else notify(err, vim.log.levels.ERROR) end
    end)
  end
  local options = {
    sorting_strategy = "ascending",
    layout_strategy = "horizontal",
    layout_config = { width = 0.95, height = 0.85, preview_width = 0.60 },
  }
  local show_pipelines, show_jobs
  show_jobs = function(pipeline)
    if not session_open() then return end
    if #pipeline.jobs == 0 then
      notify(pipeline.jobs_error or pipeline.bridges_error or "No jobs in this pipeline.", vim.log.levels.WARN)
      return
    end
    telescope.pickers.new(options, {
      prompt_title = "Pipeline #" .. pipeline.id .. " jobs",
      results_title = "Enter / Ctrl-o: browser · Ctrl-b: pipelines",
      finder = telescope.finders.new_table({
        results = pipeline.jobs,
        entry_maker = function(job)
          return {
            value = job, display = columns(job, true),
            ordinal = table.concat({ text(job.id), text(job.stage), text(job.name), text(job.state),
              text(job.failure_reason) }, " "),
          }
        end,
      }),
      sorter = telescope.config.generic_sorter({}),
      previewer = telescope.previewers.new_buffer_previewer({
        title = "Job details",
        define_preview = function(self, entry)
          preview_buffer(self.state.bufnr, metadata(entry.value, "Job"))
        end,
      }),
      attach_mappings = function(prompt_bufnr, map)
        local function open()
          local entry = telescope.action_state.get_selected_entry()
          if entry and session_open() then open_browser(entry.value) end
        end
        telescope.actions.select_default:replace(open)
        for _, mode in ipairs({ "i", "n" }) do
          map(mode, "<C-o>", open)
          map(mode, "<C-b>", function()
            telescope.actions.close(prompt_bufnr)
            vim.schedule(show_pipelines)
          end)
        end
        return true
      end,
    }):find()
  end
  show_pipelines = function()
    if not session_open() then return end
    local prompt, selected, opening = nil, nil, false
    local function picker_open()
      return prompt and vim.api.nvim_buf_is_valid(prompt) and session_open()
    end
    telescope.pickers.new(options, {
      prompt_title = session.target.project .. " " .. session.provider.prefix .. session.target.iid .. " pipelines",
      results_title = "Enter: jobs · Ctrl-o: browser",
      finder = telescope.finders.new_table({
        results = pipelines,
        entry_maker = function(pipeline)
          return {
            value = pipeline, display = columns(pipeline, false),
            ordinal = table.concat({ text(pipeline.id), text(pipeline.name), text(pipeline.state),
              text(pipeline.ref), text(pipeline.sha), text(pipeline.source), text(pipeline.created_at) }, " "),
          }
        end,
      }),
      sorter = telescope.config.generic_sorter({}),
      previewer = telescope.previewers.new_buffer_previewer({
        title = "Pipeline details",
        define_preview = function(self, entry)
          local buf, pipeline = self.state.bufnr, entry.value
          selected = pipeline
          local lines = pipeline_preview(pipeline, head)
          lines[#lines + 1], lines[#lines + 2] = "", "Loading jobs…"
          preview_buffer(buf, lines)
          details(pipeline, function(result, err)
            if not picker_open() or selected ~= pipeline or not self.state or self.state.bufnr ~= buf then return end
            if result then preview_buffer(buf, pipeline_preview(result, head))
            else
              local error_lines = pipeline_preview(pipeline, head)
              field(error_lines, "Details unavailable", err)
              preview_buffer(buf, error_lines)
            end
          end)
        end,
      }),
      attach_mappings = function(prompt_bufnr, map)
        prompt = prompt_bufnr
        telescope.actions.select_default:replace(function()
          local entry = telescope.action_state.get_selected_entry()
          if not entry or opening or not session_open() then return end
          opening = true
          details(entry.value, function(result, err)
            opening = false
            if not picker_open() then return end
            if not result then notify(err, vim.log.levels.ERROR); return end
            if #result.jobs == 0 then
              notify(result.jobs_error or result.bridges_error or "No jobs in this pipeline.", vim.log.levels.WARN)
              return
            end
            telescope.actions.close(prompt_bufnr)
            vim.schedule(function() show_jobs(result) end)
          end)
        end)
        for _, mode in ipairs({ "i", "n" }) do
          map(mode, "<C-o>", function()
            local entry = telescope.action_state.get_selected_entry()
            if entry and session_open() then open_browser(entry.value) end
          end)
        end
        return true
      end,
    }):find()
  end
  show_pipelines()
end

function M.files(session)
  if not M.available("ReviewFiles") then return end
  local files, base, head = session.files, session.base, session.head
  local function valid_selection()
    return not session.closed and require("review.ui").valid(session) and not session.refreshing
      and session.files == files and session.base == base and session.head == head
  end
  telescope.pickers.new({
    sorting_strategy = "ascending",
    layout_config = { width = 0.85, height = 0.75 },
  }, {
    prompt_title = "Review files · " .. text(head):sub(1, 8),
    results_title = "Enter: open diff",
    finder = telescope.finders.new_table({
      results = files,
      entry_maker = function(file)
        local state = text(file.status)
        if state == "" then state = file.new_file and "A" or file.deleted_file and "D" or "M" end
        local label = text(file.new_path)
        if state == "R" or state == "C" then label = text(file.old_path) .. " → " .. label end
        local marked = viewed.is(session.viewed, base, head, file)
        local marker = session.viewed_error and "[?]" or marked and "[x]" or "[ ]"
        return {
          value = file, display = marker .. " " .. state .. "  " .. label,
          ordinal = (session.viewed_error and "unknown" or marked and "viewed" or "unviewed")
            .. " " .. text(file.new_path) .. " " .. text(file.old_path),
        }
      end,
    }),
    sorter = telescope.config.generic_sorter({}),
    previewer = false,
    attach_mappings = function(prompt_bufnr)
      telescope.actions.select_default:replace(function()
        local entry = telescope.action_state.get_selected_entry()
        if not entry then return end
        if not valid_selection() then
          notify("The file list changed. Reopen :ReviewFiles.", vim.log.levels.WARN)
          return
        end
        local index
        for i, file in ipairs(files) do if file == entry.value then index = i; break end end
        if not index then return end
        telescope.actions.close(prompt_bufnr)
        vim.schedule(function() if valid_selection() then session:select_file(index) end end)
      end)
      return true
    end,
  }):find()
end

return M
