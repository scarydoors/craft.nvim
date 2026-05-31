local M = {}

local ns = vim.api.nvim_create_namespace("craft.nvim")
local uv = vim.uv or vim.loop

local config = {}
local next_id = 0
local sessions = {}
local sessions_by_buf = {}
local attached = {}
local internal_changes = {}
local spinner_frames = { "-", "\\", "|", "/" }

local function is_valid_buf(bufnr)
  return bufnr and vim.api.nvim_buf_is_valid(bufnr)
end

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "craft.nvim" })
end

local function set_default_hl(name, value)
  vim.api.nvim_set_hl(0, name, vim.tbl_extend("force", value, { default = true }))
end

local function setup_highlights()
  set_default_hl("CraftRegion", { link = "Visual" })
  set_default_hl("CraftHeader", { link = "Title" })
  set_default_hl("CraftPreview", { link = "Normal" })
  set_default_hl("CraftMuted", { link = "Comment" })
  set_default_hl("CraftReady", { link = "MoreMsg" })
  set_default_hl("CraftError", { link = "ErrorMsg" })
end

local function with_internal_change(bufnr, fn)
  internal_changes[bufnr] = (internal_changes[bufnr] or 0) + 1
  local ok, err = pcall(fn)
  internal_changes[bufnr] = internal_changes[bufnr] - 1
  if internal_changes[bufnr] == 0 then
    internal_changes[bufnr] = nil
  end
  if not ok then
    error(err)
  end
end

local function sanitize_output(text)
  if not text or text == "" then
    return ""
  end

  return text
    :gsub("\27%[[0-?]*[ -/]*[@-~]", "")
    :gsub("\27%][^\7]*\7", "")
    :gsub("%z", "")
end

local function split_text(text)
  text = sanitize_output(text)
  if text == "" then
    return {}
  end
  text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
  return vim.split(text, "\n", { plain = true })
end

local function one_line(text)
  return (text or ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
end

local function truncate(text, max_len)
  text = one_line(text)
  max_len = max_len or 80
  if #text <= max_len then
    return text
  end
  return text:sub(1, math.max(1, max_len - 3)) .. "..."
end

local function delete_extmark(bufnr, mark)
  if mark and is_valid_buf(bufnr) then
    pcall(vim.api.nvim_buf_del_extmark, bufnr, ns, mark)
  end
end

local function clear_render_marks(session)
  if not session.render_marks then
    return
  end

  for _, mark in ipairs(session.render_marks) do
    delete_extmark(session.bufnr, mark)
  end
  session.render_marks = {}
end

local function add_render_mark(session, row, col, opts)
  session.render_marks = session.render_marks or {}
  table.insert(session.render_marks, vim.api.nvim_buf_set_extmark(session.bufnr, ns, row, col, opts))
end

local function extmark_pos(bufnr, mark)
  if not mark or not is_valid_buf(bufnr) then
    return nil
  end
  local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, mark, {})
  if not pos or pos[1] == nil then
    return nil
  end
  return pos[1], pos[2]
end

local function clamp_row(bufnr, row)
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  if row < 0 then
    return 0
  end
  if row > line_count then
    return line_count
  end
  return row
end

local function get_region(session)
  local bufnr = session.bufnr
  local start_row = extmark_pos(bufnr, session.start_mark) or session.start_row
  local end_row = extmark_pos(bufnr, session.end_mark) or session.end_row
  start_row = clamp_row(bufnr, start_row or 0)
  end_row = clamp_row(bufnr, end_row or start_row)
  if end_row < start_row then
    end_row = start_row
  end
  return start_row, end_row
end

local function reset_region_marks(session, start_row, line_count)
  local bufnr = session.bufnr
  delete_extmark(bufnr, session.start_mark)
  delete_extmark(bufnr, session.end_mark)
  session.start_row = start_row
  session.end_row = start_row + line_count
  session.start_mark = vim.api.nvim_buf_set_extmark(bufnr, ns, session.start_row, 0, {
    right_gravity = false,
  })
  session.end_mark = vim.api.nvim_buf_set_extmark(bufnr, ns, session.end_row, 0, {
    right_gravity = true,
  })
end

local function protected(session)
  return session.status == "streaming" or session.status == "ready" or session.status == "error"
end

local function status_text(session)
  local prompt = truncate(session.prompt, ((config.prompt or {}).preview_chars or 80))

  if session.status == "streaming" then
    return ("Craft [%s] %s"):format(spinner_frames[session.spinner], prompt), "CraftHeader"
  end
  if session.status == "ready" then
    return ("Craft ready: :CraftAccept / :CraftReject  %s"):format(prompt), "CraftReady"
  end
  return ("Craft error: :CraftReject to clear  %s"):format(prompt), "CraftError"
end

local function display_lines(session)
  if session.status == "error" then
    return split_text(session.error_message or session.stderr or "Craft request failed")
  end

  local output_lines = split_text(session.output)
  if #output_lines > 0 then
    return output_lines
  end

  if session.status == "ready" then
    return { "" }
  end

  local text = status_text(session)
  return { text }
end

local function current_region_lines(session)
  if not is_valid_buf(session.bufnr) then
    return {}
  end
  local start_row, end_row = get_region(session)
  return vim.api.nvim_buf_get_lines(session.bufnr, start_row, end_row, false)
end

local function prepare_undojoin(session)
  if not session.did_write or not is_valid_buf(session.bufnr) then
    return
  end
  if vim.b[session.bufnr].changedtick ~= session.last_write_tick then
    return
  end

  pcall(vim.api.nvim_buf_call, session.bufnr, function()
    pcall(vim.cmd, "silent! undojoin")
  end)
end

local function render_session(session)
  if not session or not is_valid_buf(session.bufnr) or not protected(session) then
    return
  end

  local bufnr = session.bufnr
  clear_render_marks(session)
  delete_extmark(bufnr, session.highlight_mark)
  session.highlight_mark = nil

  local start_row, end_row = get_region(session)
  if end_row > start_row then
    session.highlight_mark = vim.api.nvim_buf_set_extmark(bufnr, ns, start_row, 0, {
      end_row = end_row,
      end_col = 0,
      hl_group = "CraftRegion",
      hl_eol = true,
      priority = 150,
    })
  end

  local line_count = vim.api.nvim_buf_line_count(bufnr)
  if start_row < line_count then
    local marker_text, marker_hl = status_text(session)
    add_render_mark(session, start_row, 0, {
      virt_text = { { marker_text, marker_hl } },
      virt_text_pos = "right_align",
      priority = 170,
    })
  end
end

local function apply_region_lines(session, lines, opts)
  opts = opts or {}
  if not session or not is_valid_buf(session.bufnr) then
    return false
  end

  lines = lines or {}
  local bufnr = session.bufnr
  local start_row, end_row = get_region(session)
  local current = vim.api.nvim_buf_get_lines(bufnr, start_row, end_row, false)
  session.rendered_lines = vim.deepcopy(lines)

  if vim.deep_equal(current, lines) then
    render_session(session)
    return true
  end

  with_internal_change(bufnr, function()
    if opts.undojoin ~= false then
      prepare_undojoin(session)
    end
    vim.api.nvim_buf_set_lines(bufnr, start_row, end_row, false, lines)
    session.did_write = true
    session.last_write_tick = vim.b[bufnr].changedtick
    reset_region_marks(session, start_row, #lines)
  end)

  render_session(session)
  return true
end

local function apply_display_lines(session, opts)
  return apply_region_lines(session, display_lines(session), opts)
end

local function stop_timer(session)
  if session.timer then
    session.timer:stop()
    session.timer:close()
    session.timer = nil
  end
end

local function cleanup_session(session)
  if not session then
    return
  end

  stop_timer(session)

  if is_valid_buf(session.bufnr) then
    clear_render_marks(session)
    delete_extmark(session.bufnr, session.highlight_mark)
    delete_extmark(session.bufnr, session.start_mark)
    delete_extmark(session.bufnr, session.end_mark)
    delete_extmark(session.bufnr, session.anchor_mark)
  end

  sessions[session.id] = nil
  local ids = sessions_by_buf[session.bufnr]
  if ids then
    for index = #ids, 1, -1 do
      if ids[index] == session.id then
        table.remove(ids, index)
      end
    end
    if #ids == 0 then
      sessions_by_buf[session.bufnr] = nil
    end
  end
end

local function restore_protected_region(session)
  if not session or not protected(session) or not is_valid_buf(session.bufnr) then
    return
  end

  local desired = session.rendered_lines or display_lines(session)
  if vim.deep_equal(current_region_lines(session), desired) then
    render_session(session)
    return
  end

  apply_region_lines(session, desired, { undojoin = false })

  local now = uv.now()
  if not session.last_protection_notice or now - session.last_protection_notice > 1200 then
    session.last_protection_notice = now
    notify("Craft region is reserved. Accept or reject it before editing there.", vim.log.levels.WARN)
  end
end

local function change_intersects(firstline, lastline, new_lastline, start_row, end_row)
  local changed_end = math.max(lastline, new_lastline)
  return firstline < end_row and changed_end > start_row
end

local function attach(bufnr)
  if attached[bufnr] or not is_valid_buf(bufnr) then
    return
  end

  attached[bufnr] = true
  vim.api.nvim_buf_attach(bufnr, false, {
    on_detach = function(_, detached_bufnr)
      attached[detached_bufnr] = nil
      local ids = sessions_by_buf[detached_bufnr] or {}
      for _, id in ipairs(ids) do
        local session = sessions[id]
        if session then
          if session.cancel then
            pcall(session.cancel)
          end
          stop_timer(session)
          sessions[id] = nil
        end
      end
      sessions_by_buf[detached_bufnr] = nil
    end,
    on_lines = function(_, changed_bufnr, _, firstline, lastline, new_lastline)
      if internal_changes[changed_bufnr] then
        return
      end

      local ids = sessions_by_buf[changed_bufnr]
      if not ids then
        return
      end

      local offenders = {}
      for _, id in ipairs(ids) do
        local session = sessions[id]
        if session and protected(session) then
          local start_row, end_row = get_region(session)
          if change_intersects(firstline, lastline, new_lastline, start_row, end_row) then
            table.insert(offenders, session)
          end
        end
      end

      if #offenders > 0 then
        vim.schedule(function()
          for _, session in ipairs(offenders) do
            restore_protected_region(session)
          end
        end)
      end
    end,
  })
end

local function start_timer(session)
  local timer = uv.new_timer()
  session.timer = timer
  timer:start(0, 120, vim.schedule_wrap(function()
    if not sessions[session.id] or session.status ~= "streaming" then
      stop_timer(session)
      return
    end
    session.spinner = (session.spinner % #spinner_frames) + 1
    render_session(session)
  end))
end

local function restore_original(session)
  if not session or not is_valid_buf(session.bufnr) then
    cleanup_session(session)
    return false
  end

  session.status = "restoring"
  local lines = session.mode == "replace" and session.original_lines or {}
  apply_region_lines(session, lines, { undojoin = false })
  cleanup_session(session)
  return true
end

function M.setup(opts)
  config = opts or {}
  setup_highlights()
end

function M.start(opts)
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  if not is_valid_buf(bufnr) then
    return nil, "Invalid buffer"
  end

  attach(bufnr)
  next_id = next_id + 1

  local session = {
    id = next_id,
    bufnr = bufnr,
    mode = opts.mode,
    prompt = opts.prompt or "",
    file = opts.file,
    status = "streaming",
    output = "",
    stderr = "",
    error_message = nil,
    spinner = 1,
    created_at = uv.now(),
    render_marks = {},
  }

  if session.mode == "replace" then
    session.start_line = opts.start_line
    session.end_line = opts.end_line
    session.start_row = opts.start_line - 1
    session.end_row = opts.end_line
    session.original_lines = vim.api.nvim_buf_get_lines(bufnr, session.start_row, session.end_row, false)
  else
    session.cursor_line = opts.cursor_line
    local anchor_row = opts.cursor_line - 1
    session.anchor_mark = vim.api.nvim_buf_set_extmark(bufnr, ns, anchor_row, 0, {
      right_gravity = false,
    })
    session.start_row = opts.cursor_line
    session.end_row = opts.cursor_line
    session.original_lines = {}
  end

  session.start_mark = vim.api.nvim_buf_set_extmark(bufnr, ns, session.start_row, 0, {
    right_gravity = false,
  })
  session.end_mark = vim.api.nvim_buf_set_extmark(bufnr, ns, session.end_row, 0, {
    right_gravity = true,
  })

  sessions[session.id] = session
  sessions_by_buf[bufnr] = sessions_by_buf[bufnr] or {}
  table.insert(sessions_by_buf[bufnr], session.id)

  apply_display_lines(session, { undojoin = false })
  start_timer(session)
  render_session(session)
  return session
end

function M.set_cancel(id, cancel)
  local session = sessions[id]
  if session then
    session.cancel = cancel
  end
end

function M.append(id, chunk)
  chunk = sanitize_output(chunk)
  if chunk == "" then
    return
  end

  vim.schedule(function()
    local session = sessions[id]
    if not session or session.status ~= "streaming" then
      return
    end
    session.output = session.output .. chunk
    apply_display_lines(session)
  end)
end

function M.stderr(id, chunk)
  if not chunk or chunk == "" then
    return
  end
  vim.schedule(function()
    local session = sessions[id]
    if not session then
      return
    end
    session.stderr = session.stderr .. chunk
  end)
end

function M.finish(id, result)
  vim.schedule(function()
    local session = sessions[id]
    if not session or session.status ~= "streaming" then
      return
    end

    stop_timer(session)
    if result and result.code == 0 then
      session.status = "ready"
      apply_display_lines(session)
      return
    end

    session.status = "error"
    session.error_message = result and result.stderr and result.stderr ~= "" and result.stderr
      or ("opencode exited with code %s"):format(result and tostring(result.code) or "unknown")
    apply_display_lines(session, { undojoin = false })
    notify(session.error_message, vim.log.levels.ERROR)
  end)
end

function M.fail(id, message)
  vim.schedule(function()
    local session = sessions[id]
    if not session then
      return
    end
    stop_timer(session)
    session.status = "error"
    session.error_message = message
    apply_display_lines(session, { undojoin = false })
    notify(message, vim.log.levels.ERROR)
  end)
end

function M.accept(id)
  local session = sessions[id]
  if not session then
    notify("No Craft request found", vim.log.levels.WARN)
    return false
  end
  if session.status ~= "ready" then
    notify("Craft response is not ready yet", vim.log.levels.WARN)
    return false
  end
  if not is_valid_buf(session.bufnr) then
    cleanup_session(session)
    return false
  end

  session.status = "accepted"
  apply_region_lines(session, split_text(session.output), { undojoin = false })
  cleanup_session(session)
  return true
end

function M.reject(id)
  local session = sessions[id]
  if not session then
    notify("No Craft request found", vim.log.levels.WARN)
    return false
  end
  if session.status == "streaming" and session.cancel then
    pcall(session.cancel)
  end
  return restore_original(session)
end

function M.cancel(id)
  local session = sessions[id]
  if not session then
    notify("No Craft request found", vim.log.levels.WARN)
    return false
  end
  if session.status ~= "streaming" then
    notify("Craft request already finished; use :CraftReject to clear it", vim.log.levels.WARN)
    return false
  end
  if session.cancel then
    pcall(session.cancel)
  end
  return restore_original(session)
end

function M.cancel_all(bufnr)
  local ids = vim.deepcopy(sessions_by_buf[bufnr] or {})
  local count = 0
  for _, id in ipairs(ids) do
    local session = sessions[id]
    if session and session.status == "streaming" then
      if M.cancel(id) then
        count = count + 1
      end
    end
  end
  return count
end

function M.find_at_cursor(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local cursor_row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local ids = sessions_by_buf[bufnr] or {}
  local matches = {}

  for _, id in ipairs(ids) do
    local session = sessions[id]
    if session and protected(session) then
      local start_row, end_row = get_region(session)
      if cursor_row >= start_row and cursor_row < end_row then
        table.insert(matches, {
          session = session,
          size = end_row - start_row,
        })
      elseif session.mode == "insert" then
        local anchor_row = extmark_pos(bufnr, session.anchor_mark)
        if anchor_row and cursor_row == anchor_row then
          table.insert(matches, {
            session = session,
            size = end_row - start_row + 1,
          })
        end
      end
    end
  end

  table.sort(matches, function(left, right)
    if left.size == right.size then
      return left.session.id > right.session.id
    end
    return left.size < right.size
  end)

  return matches[1] and matches[1].session or nil
end

function M.list(bufnr)
  local result = {}
  local ids = sessions_by_buf[bufnr] or {}

  for _, id in ipairs(ids) do
    local session = sessions[id]
    if session then
      local start_row, end_row = get_region(session)
      table.insert(result, ("#%d %s %s lines %d-%d: %s"):format(
        session.id,
        session.status,
        session.mode,
        start_row + 1,
        end_row,
        truncate(session.prompt, 60)
      ))
    end
  end

  return result
end

return M
