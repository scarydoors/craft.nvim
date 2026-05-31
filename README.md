# craft.nvim

Neovim plugin for sending file/line-scoped editing requests to `opencode` and
previewing the response in-place before accepting it.

Initial scope is intentionally small: `:Craft` uses the opencode server API,
streams token deltas into a protected buffer region, and keeps or restores that
region when you accept or reject the response.

## Usage

```vim
:Craft rewrite this to be clearer
```

With a visual/range selection, `Craft` sends `opencode` only the file path, line
range, and prompt. The selected range is highlighted and reserved while the
response streams directly inside that highlighted range. Rejecting the response
restores the original selected text.

Without a selection, `Craft` sends the file path, cursor line, and prompt. The
reserved region is inserted below the cursor line and grows as output streams.

## Commands

- `:Craft <prompt>` starts an opencode request for the selected range or cursor.
- `:CraftAccept` finalizes the finished response under the cursor.
- `:CraftReject` discards the response under the cursor and restores the original text.
- `:CraftCancel` cancels the streaming request under the cursor.
- `:CraftCancel!` cancels all streaming requests in the current buffer.
- `:CraftStatus` shows active requests, buffer state, and whether `opencode` is executable.

For insertion requests, move the cursor into the generated region or back to the
original anchor line to accept, reject, or cancel the response.

## Behavior

- Multiple requests can run concurrently in one buffer.
- Selected ranges are protected while a request is active or waiting for review.
- Streamed output is real buffer text inside the highlighted Craft region.
- `:CraftAccept` keeps the generated text and releases the protected region.
- `:CraftReject` restores the original selected text or removes the inserted region.
- `opencode` receives file path and line numbers only, not selected text.
- Buffers must be saved by default so `opencode` reads the same file contents from disk.

If `:Craft` appears to do nothing, run `:CraftStatus` and `:messages`. The most
common causes are an unsaved buffer, an unnamed scratch buffer, or `opencode` not
being available on Neovim's `$PATH`.

## Setup

The plugin auto-registers commands when loaded. To override defaults:

```lua
require("craft").setup({
  require_clean_buffer = true,
  opencode = {
    command = "opencode",
    transport = "server",
    hostname = "127.0.0.1",
    port = 4096,
    auto_start = true,
    model = nil,
    agent = nil,
  },
  prompt = {
    preview_chars = 80,
  },
})
```

```lua
require("craft").setup({
  require_clean_buffer = true,
  opencode = {
    command = "opencode",
    transport = "server",
    hostname = "127.0.0.1",
    port = 4096,
    auto_start = true,
    model = nil,
    agent = nil,
  },
  prompt = {
    preview_chars = 80,
  },
})
```
The default `server` transport starts or reuses `opencode serve` and listens to
server-sent token delta events. Set `transport = "cli"` to use `opencode run`,
but that mode only updates when the CLI flushes output.



