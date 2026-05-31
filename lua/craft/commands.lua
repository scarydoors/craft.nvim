local M = {}

local stream = require("craft.streaming_prompt")
local opencode = require("craft.opencode")

local config = {}

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "craft.nvim" })
  if level and level >= vim.log.levels.WARN then
    local hl = level >= vim.log.levels.ERROR and "ErrorMsg" or "WarningMsg"
    vim.api.nvim_echo({ { message, hl } }, false, {})
  end
end

local function echo(message)
  vim.api.nvim_echo({ { message, "ModeMsg" } }, false, {})
end

local function relative_path(path)
  if path == "" then
    return path
  end
  local rel = vim.fn.fnamemodify(path, ":.")
  if rel == "" then
    return path
  end
  return rel
end

local function validate_buffer(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then
    return nil, "Craft needs a file-backed buffer so opencode can read it by path"
  end

  if vim.bo[bufnr].buftype ~= "" then
    return nil, "Craft only supports normal file buffers"
  end

  if config.require_clean_buffer ~= false and vim.bo[bufnr].modified then
    return nil, "Save the buffer before using Craft; opencode receives file and line numbers only"
  end

  return relative_path(name), nil
end

local function request_from_command(command_opts)
  local bufnr = vim.api.nvim_get_current_buf()
  local prompt = command_opts.args or ""
  if prompt:gsub("%s+", "") == "" then
    return nil, "Usage: :Craft <prompt>"
  end

  local file, err = validate_buffer(bufnr)
  if not file then
    return nil, err
  end

  if command_opts.range and command_opts.range > 0 then
    local start_line = math.min(command_opts.line1, command_opts.line2)
    local end_line = math.max(command_opts.line1, command_opts.line2)
    return {
      bufnr = bufnr,
      mode = "replace",
      prompt = prompt,
      file = file,
      start_line = start_line,
      end_line = end_line,
    }
  end

  return {
    bufnr = bufnr,
    mode = "insert",
    prompt = prompt,
    file = file,
    cursor_line = vim.api.nvim_win_get_cursor(0)[1],
  }
end

local function start_request(command_opts)
  local request, err = request_from_command(command_opts)
  if not request then
    notify(err, vim.log.levels.ERROR)
    return
  end

  local session, start_err = stream.start(request)
  if not session then
    notify(start_err, vim.log.levels.ERROR)
    return
  end

  local cwd = config.opencode and config.opencode.dir or vim.fn.getcwd()
  local message = opencode.compose_message(request)
  local process, run_err = opencode.run({
    config = config,
    cwd = cwd,
    message = message,
    on_stdout = function(chunk)
      stream.append(session.id, chunk)
    end,
    on_stderr = function(chunk)
      stream.stderr(session.id, chunk)
    end,
    on_exit = function(result)
      stream.finish(session.id, result)
    end,
  })

  if not process then
    stream.fail(session.id, run_err)
    return
  end

  stream.set_cancel(session.id, function()
    process.kill()
  end)

  if request.mode == "replace" then
    echo(("Craft #%d started for %s:%d-%d"):format(session.id, request.file, request.start_line, request.end_line))
  else
    echo(("Craft #%d started for %s after line %d"):format(session.id, request.file, request.cursor_line))
  end
end

local function session_at_cursor()
  local session = stream.find_at_cursor(vim.api.nvim_get_current_buf())
  if not session then
    notify("Move the cursor into a Craft region first", vim.log.levels.WARN)
    return nil
  end
  return session
end

function M.accept()
  local session = session_at_cursor()
  if session then
    stream.accept(session.id)
  end
end

function M.reject()
  local session = session_at_cursor()
  if session then
    stream.reject(session.id)
  end
end

function M.cancel(command_opts)
  if command_opts.bang then
    local count = stream.cancel_all(vim.api.nvim_get_current_buf())
    notify(("Cancelled %d Craft request%s"):format(count, count == 1 and "" or "s"))
    return
  end

  local session = session_at_cursor()
  if session then
    stream.cancel(session.id)
  end
end

function M.status()
  local bufnr = vim.api.nvim_get_current_buf()
  local file = vim.api.nvim_buf_get_name(bufnr)
  local command = (config.opencode and config.opencode.command) or "opencode"
  local executable = vim.fn.executable(command) == 1 and "yes" or "no"
  local modified = vim.bo[bufnr].modified and "yes" or "no"
  local items = stream.list(bufnr)

  local lines = {
    "craft.nvim status",
    ("file: %s"):format(file ~= "" and file or "<none>"),
    ("modified: %s"):format(modified),
    ("opencode executable (%s): %s"):format(command, executable),
  }

  if #items == 0 then
    table.insert(lines, "requests: none")
  else
    table.insert(lines, ("requests: %d"):format(#items))
    for _, item in ipairs(items) do
      table.insert(lines, item)
    end
  end

  notify(table.concat(lines, "\n"))
end

function M.setup(opts)
  config = opts or {}

  vim.api.nvim_create_user_command("Craft", start_request, {
    nargs = "*",
    range = true,
    force = true,
    desc = "Send the current range or cursor insertion point to opencode",
  })

  vim.api.nvim_create_user_command("CraftAccept", M.accept, {
    force = true,
    desc = "Accept the Craft response under the cursor",
  })

  vim.api.nvim_create_user_command("CraftReject", M.reject, {
    force = true,
    desc = "Reject the Craft response under the cursor",
  })

  vim.api.nvim_create_user_command("CraftCancel", M.cancel, {
    bang = true,
    force = true,
    desc = "Cancel the Craft request under the cursor, or all with !",
  })

  vim.api.nvim_create_user_command("CraftStatus", M.status, {
    force = true,
    desc = "Show active Craft requests and environment status",
  })
end

return M
