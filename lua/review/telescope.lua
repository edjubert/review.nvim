local async = require("review.async")
local status = require("review.status")
local viewed = require("review.viewed")
local M = {}
local telescope
local pipeline_namespace = vim.api.nvim_create_namespace("review.pipeline")

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

local function pipeline_style(state)
  if state == "success" or state == "completed_success" then return "ReviewPipelineSuccess", "✓" end
  if state == "failed" or state == "failure" or state == "error" or state == "completed_error"
      or state == "timed_out" or state == "startup_failure" then
    return "ReviewPipelineError", "✗"
  end
  if state == "pending" or state == "queued" or state == "waiting_for_resource" or state == "scheduled" then
    return "ReviewPipelinePending", "◷"
  end
  if state == "running" or state == "in_progress" or state == "preparing" then
    return "ReviewPipelineRunning", "▶"
  end
  -- Created jobs have not been scheduled yet. Manual, skipped and canceled
  -- jobs also stay neutral instead of inheriting the pending pipeline color.
  return "ReviewPipelineInactive", "○"
end

local function field(lines, name, value)
  local label = text(value)
  if label ~= "" then lines[#lines + 1] = name .. ": " .. label end
end

local function metadata(value, kind)
  local lines = { kind .. " #" .. value.id, "" }
  local highlights = { { line = 1, group = "ReviewPipelineHeading" } }
  field(lines, "Name", value.name)
  field(lines, "Status", status.label(value.state))
  highlights[#highlights + 1] = { line = #lines, group = pipeline_style(value.state) }
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
    lines[#lines + 1] = "Downstream pipeline #" .. value.downstream.id
    highlights[#highlights + 1] = { line = #lines, group = "ReviewPipelineHeading" }
    field(lines, "Status", value.downstream.state)
    highlights[#highlights + 1] = { line = #lines, group = pipeline_style(value.downstream.state) }
    field(lines, "Ref", value.downstream.ref)
    field(lines, "URL", value.downstream.web_url)
  end
  return lines, highlights
end

local function pipeline_preview(pipeline, head)
  local lines, highlights = metadata(pipeline, "Pipeline")
  field(lines, "Matches review head", pipeline.sha == head and "yes" or "no")
  if not pipeline.jobs then return lines, highlights end
  lines[#lines + 1], lines[#lines + 2] = "", "Jobs"
  highlights[#highlights + 1] = { line = #lines, group = "ReviewPipelineHeading" }
  for _, failure in ipairs({
    { "Jobs unavailable", pipeline.jobs_error }, { "Triggers unavailable", pipeline.bridges_error },
  }) do
    if failure[2] then
      field(lines, failure[1], failure[2])
      highlights[#highlights + 1] = { line = #lines, group = "ReviewPipelineError" }
    end
  end
  if #pipeline.jobs == 0 and not pipeline.jobs_error and not pipeline.bridges_error then
    lines[#lines + 1] = "No jobs in this pipeline."
  end
  local stages, by_stage = {}, {}
  for _, job in ipairs(pipeline.jobs) do
    local name = text(job.stage)
    if name == "" then name = "Other jobs" end
    local stage = by_stage[name]
    if not stage then
      stage = { name = name, jobs = {} }
      by_stage[name], stages[#stages + 1] = stage, stage
    end
    stage.jobs[#stage.jobs + 1] = job
  end
  -- Preserve the stages' first occurrence in the provider's ordered job list.
  for _, stage in ipairs(stages) do
    lines[#lines + 1] = ""
    lines[#lines + 1] = ("%s (%d)"):format(stage.name, #stage.jobs)
    highlights[#highlights + 1] = { line = #lines, group = "ReviewPipelineStage" }
    for _, job in ipairs(stage.jobs) do
      local group, icon = pipeline_style(job.state)
      lines[#lines + 1] = ("  %s %s · %s · %s%s"):format(
        icon, text(job.name), text(status.label(job.state)), duration(job.duration),
        job.allow_failure and " (failure allowed)" or "")
      highlights[#highlights + 1] = { line = #lines, group = group }
      if job.failure_reason then
        lines[#lines + 1] = "    Failure: " .. text(job.failure_reason)
        highlights[#highlights + 1] = { line = #lines, group = group }
      end
      if job.downstream then
        local downstream_group, downstream_icon = pipeline_style(job.downstream.state)
        lines[#lines + 1] = ("    %s Downstream #%d: %s"):format(
          downstream_icon, job.downstream.id, text(status.label(job.downstream.state)))
        highlights[#highlights + 1] = { line = #lines, group = downstream_group }
      end
    end
  end
  return lines, highlights
end

local function preview_buffer(buf, lines, highlights)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  -- Explicit decorations keep job colors independent of Markdown rendering.
  vim.bo[buf].filetype = "review-pipeline"
  vim.api.nvim_buf_clear_namespace(buf, pipeline_namespace, 0, -1)
  for _, highlight in ipairs(highlights or {}) do
    vim.api.nvim_buf_set_extmark(buf, pipeline_namespace, highlight.line - 1, 0, {
      end_col = #lines[highlight.line], hl_group = highlight.group, priority = 200,
    })
  end
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
    local group = pipeline_style(value.state)
    return displayer({
      { "#" .. value.id, group }, { text(status.label(value.state)), group },
      { job and (text(value.name) .. " · " .. duration(value.duration))
        or (text(value.source) .. " · " .. text(value.sha):sub(1, 8) .. " · "
          .. text(value.ref) .. " · " .. text(value.created_at)), group },
    })
  end
end

function M.pipelines(session, pipelines)
  if not M.available() then return end
  local keymaps = session.config.keymaps or {}
  local cache = {}
  local head = session.data.mr.diff_refs.head_sha
  local function session_open()
    return not session.closed and require("review.ui").valid(session)
  end
  -- A pipeline's preview and selection action share the same pending request.
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
      results_title = "Select: browser"
        .. (keymaps.pipeline_open and " · " .. keymaps.pipeline_open .. ": browser" or "")
        .. (keymaps.pipeline_back and " · " .. keymaps.pipeline_back .. ": pipelines" or ""),
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
          if keymaps.pipeline_open then map(mode, keymaps.pipeline_open, open) end
          if keymaps.pipeline_back then
            map(mode, keymaps.pipeline_back, function()
              telescope.actions.close(prompt_bufnr)
              vim.schedule(show_pipelines)
            end)
          end
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
      results_title = "Select: jobs"
        .. (keymaps.pipeline_open and " · " .. keymaps.pipeline_open .. ": browser" or ""),
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
          local lines, highlights = pipeline_preview(pipeline, head)
          lines[#lines + 1], lines[#lines + 2] = "", "Loading jobs…"
          highlights[#highlights + 1] = { line = #lines, group = "ReviewPipelineInactive" }
          preview_buffer(buf, lines, highlights)
          details(pipeline, function(result, err)
            if not picker_open() or selected ~= pipeline or not self.state or self.state.bufnr ~= buf then return end
            if result then preview_buffer(buf, pipeline_preview(result, head))
            else
              local error_lines, error_highlights = pipeline_preview(pipeline, head)
              field(error_lines, "Details unavailable", err)
              error_highlights[#error_highlights + 1] = { line = #error_lines, group = "ReviewPipelineError" }
              preview_buffer(buf, error_lines, error_highlights)
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
          if keymaps.pipeline_open then
            map(mode, keymaps.pipeline_open, function()
              local entry = telescope.action_state.get_selected_entry()
              if entry and session_open() then open_browser(entry.value) end
            end)
          end
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
