local M = {}

local defaults = {
  require_clean_buffer = true,
  opencode = {
    command = "opencode",
    transport = nil,
    server_url = nil,
    hostname = "127.0.0.1",
    port = 4096,
    auto_start = true,
    args = { "run", "--format", "default" },
    dir = nil,
    model = nil,
    agent = nil,
  },
  prompt = {
    preview_chars = 80,
  },
}

local config = vim.deepcopy(defaults)

local function merge_config(opts)
  return vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
end

function M.setup(opts)
  config = merge_config(opts)
  require("craft.streaming_prompt").setup(config)
  require("craft.commands").setup(config)
end

function M.config()
  return config
end

function M.defaults()
  return vim.deepcopy(defaults)
end

return M
