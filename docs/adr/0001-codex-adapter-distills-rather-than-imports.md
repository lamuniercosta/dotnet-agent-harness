# Codex adapter distils the rules, and initially shipped no hook wiring

The hook portion of this decision is superseded by
[ADR 0002](./0002-codex-hooks-preserve-advisory-semantics.md). The `AGENTS.md`
and project-local configuration decisions remain current.

Codex reads `AGENTS.md` from the repo root but has no `@import`, so the ten
always-on rules cannot be referenced the way `CLAUDE.md` references
`.cursor/rules/*.mdc`. `adapters/codex/AGENTS.md` therefore restates them in
full. This knowingly creates a second hand-maintained copy of rules that live
elsewhere — the drift the harness otherwise exists to prevent — because the
alternative is a Codex session that loads no conventions at all. The copy is
guarded by assertions in `Test-InstallArtifacts.ps1`; `.cursor/rules/*.mdc`
remains the source, and `AGENTS.md` is the stale one when they disagree.

## Consequences

`AGENTS.md` is installed **skip-if-exists**, unlike `CLAUDE.md`, which appends
its import block to a file the repo already owns. Appending ten `@import` lines
under someone's own instructions is small and reversible; appending an entire
ruleset is neither, and would sit in silent contradiction with whatever that
file already said. An existing `AGENTS.md` is reported for a hand merge instead.

## Considered options

**Wiring Codex hooks now — rejected for this slice.** Issue #48 assumed Codex had
no pre-prompt hook. It does: hooks are enabled by default, work on Windows, and
`PreToolUse` covers `Bash`, `Edit`, `Write`, `apply_patch`, and MCP calls. Both
`hooks/secret-scan.ps1` and `hooks/guard.ps1` already read Codex's field names
(`prompt`, `tool_name`, `tool_input`) and already signal through its exit-2
contract, so wiring is close to authoring one JSON file.

It was rejected because the semantics do not survive the move. `secret-scan` is
deliberately warn-only — "a hook that blocks work on a guess gets switched off
within a day, and a disabled hook protects nothing". On Codex, exit 2 from
`UserPromptSubmit` **blocks the prompt**. Naive wiring would silently convert a
warning into a block and reproduce exactly the failure its author designed
against. Preserving warn-only requires a successful JSON warning/context response
with no block decision, which is a design change to the shared scripts and
deserved its own slice. ADR 0002 records the implemented contract.

**A project-local `.codex/config.toml` over the global `~/.codex/config.toml`.**
The global file holds the user's own auth, plugins, and marketplaces; an
installer has no business writing there. The cost is that project config loads
only for a *trusted* project, so an untrusted repo registers no MCP servers and
says nothing about it — which is why `AGENTS.md` calls the trust step out.
