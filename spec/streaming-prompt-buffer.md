# Streaming Prompt Buffer

## Summary

Provide a reusable Lua module that opens or uses a Neovim buffer as an interactive prompt/output surface. Users can enter text, continue editing while output streams, select or modify generated text, and trigger actions on the prompt or streamed response without blocking the Neovim UI.

This is the baseline feature that higher-level agent integrations should build on.

## Goals

- Open a prompt area inside a normal Neovim buffer.
- Accept user-entered prompt text from the buffer.
- Stream output into the buffer incrementally.
- Keep Neovim responsive while output is streaming.
- Allow users to edit, select, delete, or move around streamed text while streaming continues.
- Expose a reusable module API for agent-specific features.
- Support caller-provided callbacks for submit, cancel, stream chunks, completion, and errors.

## Non-Goals

- Implement direct LLM or agent communication.
- Depend on `opencode` directly.
- Define final UI styling, window layout, or keymaps beyond the minimum needed for the module API.
- Guarantee conflict-free writes when the user edits exactly where a stream chunk is inserted. The first implementation should define clear behavior and improve later if needed.

## User Experience

A caller can create a prompt/output session in a buffer. The user writes a prompt and submits it. Output starts appearing at a configured insertion point. The user can keep editing elsewhere in the buffer while chunks are appended or inserted.

The streamed output should feel like normal buffer text, not a modal terminal that blocks interaction.

## Functional Requirements

- Create a prompt session from Lua with an existing buffer or a new scratch buffer.
- Track prompt text and output region boundaries with extmarks where possible.
- Submit prompt text without blocking Neovim.
- Insert streamed chunks using scheduled Neovim API calls.
- Provide cancellation for an active stream.
- Mark stream completion and error states in a way callers can inspect.
- Allow generated text to be selected and edited as regular buffer content.
- Provide a minimal command or function for manual testing during development.

## Suggested Lua API

The module should expose a small session-oriented API for starting a prompt session, submitting prompt text, appending streamed output, cancelling active streams, and reporting completion or errors.

The exact API can change during implementation, but agent integrations should not need to know about low-level buffer write details.

## Open Questions

- Should the initial prompt open in the current buffer, a split, a floating window, or be caller-controlled only?
- Should streamed output append after the selected region by default, replace the selected region, or be inserted at the cursor?
- How should the module behave if the user edits inside the active output insertion point during streaming?
- What keymaps should be provided by default, if any?

## Acceptance Criteria

- A Lua caller can start a prompt session and stream chunks into a buffer asynchronously.
- Neovim remains usable while chunks are being streamed.
- The user can edit the buffer during streaming.
- The module can be reused without importing any `opencode`-specific code.
