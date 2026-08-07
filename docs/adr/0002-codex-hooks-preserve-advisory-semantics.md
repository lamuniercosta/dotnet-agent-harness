# Codex hooks preserve blocking and advisory intent explicitly

The harness now installs project-local Codex lifecycle wiring in
`.codex/hooks.json`. `PreToolUse` runs the destructive-action guard, while
`UserPromptSubmit` runs the credential-shape scanner and `PostToolUse` runs the
formatter and gate nudge. Codex reports `apply_patch` as its canonical tool name;
the shared scripts therefore understand both ordinary edit payloads and patch
payloads.

## Decision

Hook exit codes are not portable intent. The shared scripts retain their existing
default contracts for Cursor and Claude Code, but advisory hooks accept an
explicit Codex output contract when invoked by the Codex adapter.

- `guard.ps1` continues to write a reason to stderr and exit 2. Under Codex
  `PreToolUse`, that denies the tool call, which is the guard's intended behavior.
- `secret-scan.ps1` exits 0 and returns `UserPromptSubmit` `additionalContext`
  plus a `systemMessage`. It deliberately returns no `decision: block`, because
  both that decision and exit 2 reject the user's prompt.
- `gate-nudge.ps1` exits 0 and returns `PostToolUse` `additionalContext` plus a
  `systemMessage`. Exit 2 at that event would replace the completed tool result
  and can make a successful edit appear to have failed.
- `format-on-edit.ps1` remains silent and always exits 0.

The output-contract switch is explicit rather than inferred from a generic
`prompt`, `tool_name`, or `tool_input` field. Other hosts use the same field names,
so inference could silently change their behavior.

## Consequences

Codex requires the project and each non-managed hook definition to be reviewed
and trusted. The installer owns and refreshes `.codex/hooks.json`; after an
update, Codex skips changed definitions until they are reviewed again with
`/hooks`.

Codex has no file-read lifecycle event. Prompt scanning therefore covers text the
user submits, but not credentials read from files. This residual gap is documented
in the installed `AGENTS.md`; CI secret scanning addresses commits, not content
that has already reached a model provider.
