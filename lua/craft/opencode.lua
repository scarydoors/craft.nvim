local M = {}

local server_handle = nil

local function extend(dst, src)
  for _, value in ipairs(src or {}) do
    table.insert(dst, value)
  end
end

local function opencode_config(config)
  return (config and config.opencode) or {}
end

local function notify(message, level)
  vim.schedule(function()
    vim.notify(message, level or vim.log.levels.INFO, { title = "craft.nvim" })
  end)
end

local function percent_encode(value)
  return tostring(value or ""):gsub("([^%w%-%._~])", function(char)
    return ("%%%02X"):format(string.byte(char))
  end)
end

local function base_url(oc)
  if oc.server_url then
    return oc.server_url:gsub("/$", "")
  end

  local hostname = oc.hostname or "127.0.0.1"
  local port = oc.port or 4096
  return ("http://%s:%d"):format(hostname, port)
end

local function build_cli_command(config, message, cwd)
  local oc = opencode_config(config)
  local command = oc.command or "opencode"
  local cmd = { command }

  extend(cmd, oc.args or { "run", "--format", "default" })

  if oc.model then
    extend(cmd, { "--model", oc.model })
  end

  if oc.agent then
    extend(cmd, { "--agent", oc.agent })
  end

  local dir = oc.dir or cwd
  if dir then
    extend(cmd, { "--dir", dir })
  end

  table.insert(cmd, message)
  return cmd
end

local function parse_model(model)
  if type(model) == "table" then
    if model.providerID and model.modelID then
      return model
    end
    if model.providerID and model.id then
      return {
        providerID = model.providerID,
        modelID = model.id,
      }
    end
    return nil
  end

  if type(model) ~= "string" then
    return nil
  end

  local provider, model_id = model:match("^([^/]+)/(.+)$")
  if not provider or not model_id then
    return nil
  end

  return {
    providerID = provider,
    modelID = model_id,
  }
end

local function curl_exists()
  return vim.fn.executable("curl") == 1
end

local function http_json(method, url, body, callback)
  local cmd = { "curl", "-fsS", "-X", method, "-H", "Content-Type: application/json" }
  if body then
    extend(cmd, { "--data-binary", vim.json.encode(body) })
  end
  table.insert(cmd, url)

  local stderr = {}
  vim.system(cmd, {
    text = true,
    stderr = function(_, data)
      if data and data ~= "" then
        table.insert(stderr, data)
      end
    end,
  }, function(result)
    if result.code ~= 0 then
      callback(nil, table.concat(stderr) ~= "" and table.concat(stderr) or ("HTTP request failed: " .. url))
      return
    end

    if not result.stdout or result.stdout == "" then
      callback(true, nil)
      return
    end

    local ok, decoded = pcall(vim.json.decode, result.stdout)
    if not ok then
      callback(nil, "Invalid JSON response from opencode server")
      return
    end

    callback(decoded, nil)
  end)
end

local function healthcheck(url, callback)
  vim.system({ "curl", "-fsS", url .. "/global/health" }, { text = true }, function(result)
    callback(result.code == 0)
  end)
end

local function start_server(config, cwd, callback)
  local oc = opencode_config(config)
  local url = base_url(oc)

  healthcheck(url, function(healthy)
    if healthy then
      callback(true, nil, url)
      return
    end

    if oc.auto_start == false then
      callback(false, "opencode server is not running at " .. url, url)
      return
    end

    local command = oc.command or "opencode"
    local port = oc.port or 4096
    local hostname = oc.hostname or "127.0.0.1"
    local stderr = {}

    server_handle = vim.system({ command, "serve", "--port", tostring(port), "--hostname", hostname }, {
      cwd = cwd,
      text = true,
      stderr = function(_, data)
        if data and data ~= "" then
          table.insert(stderr, data)
        end
      end,
    }, function(result)
      if result.code ~= 0 then
        notify(table.concat(stderr) ~= "" and table.concat(stderr) or "opencode server exited", vim.log.levels.WARN)
      end
    end)

    local attempts = 0
    local function poll()
      attempts = attempts + 1
      healthcheck(url, function(now_healthy)
        if now_healthy then
          callback(true, nil, url)
          return
        end
        if attempts >= 50 then
          callback(false, table.concat(stderr) ~= "" and table.concat(stderr) or "Timed out starting opencode server", url)
          return
        end
        vim.defer_fn(poll, 100)
      end)
    end

    vim.defer_fn(poll, 100)
  end)
end

function M.compose_message(request)
  local lines = {
    "You are responding for craft.nvim, a Neovim editing plugin.",
    "Return only the exact text that should appear in the reserved editor region.",
    "Do not include markdown fences, explanations, summaries, or surrounding commentary.",
    "Read the target file from the project using the file path and line numbers below.",
    "",
    "Target file: " .. request.file,
  }

  if request.mode == "replace" then
    vim.list_extend(lines, {
      ("Target range: lines %d-%d"):format(request.start_line, request.end_line),
      "Allowed operation: replace only that target range.",
      "Do not modify, rewrite, or comment on any other part of the file.",
    })
  else
    vim.list_extend(lines, {
      ("Insertion point: after line %d"):format(request.cursor_line),
      "Allowed operation: insert text only at that insertion point.",
      "Do not modify, rewrite, or comment on any existing file text.",
    })
  end

  vim.list_extend(lines, {
    "",
    "User request:",
    request.prompt,
  })

  return table.concat(lines, "\n")
end

local function run_cli(opts)
  local config = opts.config or {}
  local command = opencode_config(config).command or "opencode"

  if vim.fn.executable(command) ~= 1 then
    return nil, ("Executable not found: %s"):format(command)
  end

  local stderr = {}
  local cmd = build_cli_command(config, opts.message, opts.cwd)
  local handle = vim.system(cmd, {
    cwd = opts.cwd,
    text = true,
    stdout = function(err, data)
      if err and opts.on_stderr then
        opts.on_stderr(tostring(err))
      end
      if data and data ~= "" and opts.on_stdout then
        opts.on_stdout(data)
      end
    end,
    stderr = function(err, data)
      if err then
        table.insert(stderr, tostring(err))
        if opts.on_stderr then
          opts.on_stderr(tostring(err))
        end
      end
      if data and data ~= "" then
        table.insert(stderr, data)
        if opts.on_stderr then
          opts.on_stderr(data)
        end
      end
    end,
  }, function(result)
    if opts.on_exit then
      opts.on_exit({
        code = result.code,
        signal = result.signal,
        stderr = table.concat(stderr),
      })
    end
  end)

  return {
    kill = function()
      pcall(function()
        handle:kill(15)
      end)
    end,
    wait = function(timeout)
      return handle:wait(timeout)
    end,
  }
end

local function run_server(opts)
  local config = opts.config or {}
  local oc = opencode_config(config)
  local command = oc.command or "opencode"

  if vim.fn.executable(command) ~= 1 then
    return nil, ("Executable not found: %s"):format(command)
  end
  if not curl_exists() then
    return nil, "Executable not found: curl"
  end

  local controller = {
    killed = false,
    finished = false,
    session_id = nil,
    sse = nil,
  }

  local function finish(result)
    if controller.finished then
      return
    end
    controller.finished = true
    if controller.sse then
      pcall(function()
        controller.sse:kill(15)
      end)
      controller.sse = nil
    end
    if opts.on_exit then
      opts.on_exit(result)
    end
  end

  local function fail(message)
    if opts.on_stderr then
      opts.on_stderr(message)
    end
    finish({ code = 1, stderr = message })
  end

  local directory = oc.dir or opts.cwd or vim.fn.getcwd()
  local encoded_directory = percent_encode(directory)

  start_server(config, directory, function(ok, err, url)
    if controller.killed then
      return
    end
    if not ok then
      fail(err or "Failed to start opencode server")
      return
    end

    local session_url = url .. "/session?directory=" .. encoded_directory
    http_json("POST", session_url, { title = "craft.nvim" }, function(session, session_err)
      if controller.killed then
        return
      end
      if not session then
        fail(session_err or "Failed to create opencode session")
        return
      end

      controller.session_id = session.id

      local sse_buffer = ""
      local sse_data = {}
      local delta_source = nil
      local function dispatch_sse(data)
        if data == "" then
          return
        end

        local ok_decode, event = pcall(vim.json.decode, data)
        if not ok_decode or type(event) ~= "table" then
          return
        end

        local properties = event.properties or {}
        if properties.sessionID ~= controller.session_id then
          return
        end

        if event.type == "message.part.delta" and properties.field == "text" then
          if not delta_source or delta_source == "message.part.delta" then
            delta_source = "message.part.delta"
          end
          if delta_source == "message.part.delta" and opts.on_stdout then
            opts.on_stdout(properties.delta or "")
          end
        elseif event.type == "session.next.text.delta" then
          if not delta_source or delta_source == "session.next.text.delta" then
            delta_source = "session.next.text.delta"
          end
          if delta_source == "session.next.text.delta" and opts.on_stdout then
            opts.on_stdout(properties.delta or "")
          end
        elseif event.type == "session.error" then
          fail(properties.error or properties.message or "opencode session error")
        elseif event.type == "session.idle" then
          finish({ code = 0, stderr = "" })
        end
      end

      local function handle_sse_chunk(chunk)
        sse_buffer = sse_buffer .. chunk
        while true do
          local newline = sse_buffer:find("\n", 1, true)
          if not newline then
            break
          end

          local line = sse_buffer:sub(1, newline - 1):gsub("\r$", "")
          sse_buffer = sse_buffer:sub(newline + 1)

          if line == "" then
            if #sse_data > 0 then
              dispatch_sse(table.concat(sse_data, "\n"))
              sse_data = {}
            end
          elseif line:sub(1, 5) == "data:" then
            local payload = line:sub(6)
            if payload:sub(1, 1) == " " then
              payload = payload:sub(2)
            end
            table.insert(sse_data, payload)
          end
        end
      end

      local event_url = url .. "/event?directory=" .. encoded_directory
      local sse_stderr = {}
      controller.sse = vim.system({ "curl", "-fsS", "-N", "-H", "Accept: text/event-stream", event_url }, {
        text = true,
        stdout = function(_, data)
          if data and data ~= "" then
            handle_sse_chunk(data)
          end
        end,
        stderr = function(_, data)
          if data and data ~= "" then
            table.insert(sse_stderr, data)
          end
        end,
      }, function(result)
        if result.code ~= 0 and not controller.finished and not controller.killed then
          fail(table.concat(sse_stderr) ~= "" and table.concat(sse_stderr) or "opencode event stream closed")
        end
      end)

      vim.defer_fn(function()
        if controller.killed then
          return
        end

        local prompt_body = {
          parts = {
            {
              type = "text",
              text = opts.message,
            },
          },
        }

        local model = parse_model(oc.model)
        if model then
          prompt_body.model = model
        end
        if oc.agent then
          prompt_body.agent = oc.agent
        end
        if oc.variant then
          prompt_body.variant = oc.variant
        end
        if oc.tools then
          prompt_body.tools = oc.tools
        end

        local prompt_url = url .. "/session/" .. controller.session_id .. "/prompt_async?directory=" .. encoded_directory
        http_json("POST", prompt_url, prompt_body, function(_, prompt_err)
          if controller.killed then
            return
          end
          if prompt_err then
            fail(prompt_err)
          end
        end)
      end, 100)
    end)
  end)

  function controller.kill()
    controller.killed = true
    if controller.sse then
      pcall(function()
        controller.sse:kill(15)
      end)
      controller.sse = nil
    end

    if controller.session_id then
      local url = base_url(oc)
      vim.system({ "curl", "-fsS", "-X", "POST", url .. "/session/" .. controller.session_id .. "/abort?directory=" .. encoded_directory }, {
        text = true,
      })
    end
  end

  function controller.wait()
    return nil
  end

  return controller
end

function M.run(opts)
  local oc = opencode_config(opts.config or {})
  local transport = oc.transport
  if not transport then
    transport = (oc.command and oc.command ~= "opencode") and "cli" or "server"
  end

  if transport == "cli" then
    return run_cli(opts)
  end

  return run_server(opts)
end

return M
