# Opencode Region Prompt

## Summary

Provide a `craft.nvim` feature that sends user prompt text plus selected or contextual buffer content to `opencode`, then streams the response directly into the Neovim buffer at the user-specified location.

This feature builds on the reusable streaming prompt buffer module.

## Goals

- Integrate with `opencode` as the initial supported agent harness.
- Allow users to prompt against a selected region of text.
- Allow users to prompt without a selection, using cursor or buffer context.
- Stream `opencode` output directly into the buffer without blocking Neovim.
- Expose a command such as `:Craft <user text>`.
- Keep opencode-specific process management outside the baseline streaming buffer module.

## Non-Goals

- Support agent harnesses other than `opencode` in the first version.
- Build a complete chat UI.
- Manage long-term conversation storage unless required by `opencode` integration.
- Automatically apply edits without showing streamed output to the user first.

## User Experience

The user selects a region and runs the `:Craft` command with a prompt. `craft.nvim` sends the selected region and prompt to `opencode`. The response streams into the buffer at the configured insertion point. The user can continue editing while output arrives.

If no region is selected, `craft.nvim` uses cursor-local context or the current buffer according to the integration rules defined during implementation.

## Functional Requirements

- Register a user command named `:Craft` that accepts free-form prompt text.
- Detect visual selection when invoked from visual mode or with range information.
- Capture relevant context when no explicit selection exists.
- Start an `opencode` process or session without blocking the UI.
- Send prompt and selected/context text to `opencode`.
- Stream stdout or protocol output into the buffer through the baseline streaming module.
- Surface stderr, non-zero exits, or protocol errors to the user.
- Provide cancellation for an active `opencode` request.

## Command Shape

The command should be named `:Craft` and accept free-form prompt text. It should work from normal mode and visual mode. Visual mode should prefer the selected range as the region of interest.

## Suggested Architecture

- `craft.streaming_prompt`: reusable buffer prompt and stream writer.
- `craft.opencode`: opencode process/session adapter.
- `craft.commands`: Neovim command registration and selection/context capture.

The opencode adapter should translate between Neovim/editor context and the opencode invocation or protocol. It should not directly own buffer insertion behavior beyond calling the streaming prompt module.

## Open Questions

- Which `opencode` interface should be used first: CLI stdin/stdout, JSON/protocol mode, or another integration point?
- Should output replace the selected text, insert below it, or insert at cursor by default?
- How should users choose between insert, replace, append, or preview behavior?
- Should `:Craft` maintain an opencode session per buffer, per tab, per project, or per request?
- What context should be included when no region is selected?

## Acceptance Criteria

- `:Craft <prompt>` sends prompt and selected/context text to `opencode`.
- Output streams into the Neovim buffer through the reusable streaming module.
- Neovim remains responsive during the request.
- The feature handles cancellation and process errors visibly.
- Opencode-specific code remains isolated from the baseline streaming module.
