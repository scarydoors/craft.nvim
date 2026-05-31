# craft.nvim specs

This directory contains feature specs for `craft.nvim`, a Neovim Lua plugin for integrating editor-native workflows with an agent harness.

Initial scope is limited to `opencode` integration.

## Specs

- [Streaming prompt buffer](./streaming-prompt-buffer.md): baseline reusable module for non-blocking prompt input and streamed model output in a Neovim buffer.
- [Opencode region prompt](./opencode-region-prompt.md): user-facing feature and command that sends selected or contextual buffer text to `opencode` and streams the response back into the buffer.
