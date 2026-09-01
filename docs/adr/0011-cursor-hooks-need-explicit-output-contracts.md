# Cursor hooks need explicit output contracts

Cursor runs the harness's shared hook scripts through its own lifecycle events.
Those events do not treat exit codes the same way as every other host: exit 2
blocks the action at every event. That made two advisory hooks behave as
blockers. In particular, `secret-scan.ps1` on `beforeSubmitPrompt` blocked the
user's Send button when it found a credential-shaped value.

Cursor's stdout contract is also per-event rather than uniform.
`beforeSubmitPrompt` uses `continue`, permission events use `permission`, and
`postToolUse` uses `additional_context`. The credential scanner therefore needs
two Cursor contract values instead of one.

## Decision

Extend the explicit `-OutputContract` precedent from ADR 0002 with Cursor-specific
contracts. The adapter passes the correct contract for each Cursor event rather
than inferring behavior from generic payload fields such as `prompt`,
`tool_name`, or `tool_input`.

`guard.ps1` remains the only hook that blocks. It still exits 2 under every
contract, and under Cursor it also writes the required JSON decision to stdout.
The advisory hooks emit Cursor JSON and exit 0 under their Cursor contracts.

## Consequences

Cursor receives valid JSON for every successful hook path, including allow paths
that were previously silent.

The credential scanner and gate nudge remain advisory under Cursor instead of
turning into blockers through exit 2.

`failClosed` stays `false`, so a missing `pwsh` or a hook startup failure still
fails open rather than wedging the session.
