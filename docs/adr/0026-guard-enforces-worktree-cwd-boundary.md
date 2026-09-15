# Guard enforces worktree CWD boundary

When multiple agents work in parallel, each in its own linked worktree, nothing
in `guard.ps1` prevents a worker from editing files in the main checkout or
another worktree. The cross-contamination is invisible: the edit succeeds, the
other worktree's state silently changes, and the owning agent discovers an
unexplained diff it never made. This repo's own layout — `dotnet-agent-harness`
beside `dotnet-agent-harness.worktrees/<branch>` — makes the failure concrete.

## Decision

`guard.ps1` gains a CWD boundary check for file-write tool calls (Edit, Write,
MultiEdit, create_file, edit_file, search_replace, apply_patch). When the
PreToolUse payload carries a `cwd` field, the guard:

1. Resolves the git toplevel from the payload CWD
   (`git -C $cwd rev-parse --show-toplevel`).
2. Resolves the target file path to absolute using `[IO.Path]::GetFullPath`
   (always — even on already-rooted paths, to collapse `..` traversals).
3. Normalises both boundary and resolved path to forward slashes, strips
   trailing separators from the boundary.
4. Blocks (exit 2) if the resolved path is neither equal to the boundary nor
   prefixed by `$boundary + "/"`. The trailing-separator rule prevents a
   sibling directory whose name shares the prefix (e.g.
   `dotnet-agent-harness.worktrees/…` starting with `dotnet-agent-harness`)
   from passing the check.

### String comparison

On Windows, file paths are case-insensitive: `git rev-parse` returns canonical
casing while Edit payloads may carry lowercased drives or differently-cased
segments. The boundary comparison uses
`[StringComparison]::OrdinalIgnoreCase` when `$IsWindows` is true, and
`[StringComparison]::Ordinal` on Linux, where path casing is significant.

### Denial contract

A blocked write exits 2 with the message:

    guard: BLOCKED - writing outside the session worktree boundary (<boundary>).
    Edit files inside your working copy.

Under `-OutputContract Cursor`, the same message appears in the JSON
`agent_message` and `user_message` fields.

### Fail-open triggers

The boundary check is skipped (existing rules still apply) when:

- The payload has no `cwd` field.
- The `cwd` is not inside a git repository (`git rev-parse` fails).
- `[IO.Path]::GetFullPath` throws (non-existent CWD, invalid characters).
- Any unexpected exception occurs in the new functions.

Every new function (`Resolve-HookPath`, `Get-WorktreeBoundary`,
`Deny-OutsideBoundary`) wraps its body in a try/catch that returns `$null` or
skips on failure. Under `$ErrorActionPreference = 'Stop'`, an unguarded throw
exits 1 — which hosts read as "hook crashed", not "action blocked" — so the
catch is load-bearing for the never-wedge contract.

### Bash is out of scope

Shell commands can target any path through indirection (`cd`, variables,
pipes, subshells). Parsing them for boundary violations is unreliable and
would create a bypassable check — worse than none, because it is trusted. The
existing Bash checks (rm -rf, force-push, reset --hard, checkout -- .) remain
unchanged.

### Accepted cost

The boundary check spawns one `git rev-parse --show-toplevel` subprocess per
guarded file-write call. The boundary is computed lazily — only inside the
Edit/Write and apply_patch switch branches, never for Bash — and cached in a
script-scoped variable so a second branch in the same invocation reuses it.
Latency varies by platform: typically 5 ms on Linux, 50–70 ms on Windows,
where process creation is inherently slower. For a PreToolUse hook that runs
before the edit happens, this cost is acceptable.

### Trust model

The boundary is derived from the payload's `cwd` field, which is set by the
host (Claude Code, Codex, Cursor), not by the agent's tool input. The hook's
threat model is accidental cross-contamination between parallel worktrees, not
adversarial agents constructing their own payloads. A process-CWD cross-check
was considered and rejected: the hook process's CWD is the host's install
directory (e.g. `$CLAUDE_PROJECT_DIR/scripts/hooks/`), not the session's
working directory. They differ by design, and comparing them produces false
blocks on every invocation.

## Rejected alternatives

**Bash path parsing.** Searching shell commands for file paths outside the
boundary is unreliable (indirection, variables, pipes) and creates a
bypassable check that is worse than none because it is trusted.

**Environment variable for the boundary.** Requiring `HARNESS_WORKTREE_ROOT`
in the session environment adds a configuration step that `new-task-branch.ps1`
would need to manage, and a missing variable silently disables the check.
Deriving the boundary from the payload CWD via git is self-contained and
needs no session-level setup.

**Always-on without CWD.** Using the hook process's own CWD or a hard-coded
root when the payload has no `cwd` field would produce false blocks on hosts
that do not send CWD, and on tool calls where it is legitimately absent. The
fail-open design means the boundary check activates only when the host
provides the information needed to enforce it.

**Process-CWD cross-check.** See trust model above.

## What this does not protect

These are known gaps, accepted as the cost of keeping the check narrow and
reliable:

- **Symlink, junction, and reparse-point aliasing (DEF-1).** The boundary
  comparison is lexical: `[IO.Path]::GetFullPath` does not resolve reparse
  points. A symlink inside the worktree pointing outside it passes the
  boundary check. Resolving link targets requires platform-specific logic
  (`GetFinalPathNameByHandle` on Windows, `readlink -f` on Linux) that is
  fragile and slow. Deferred to a follow-up task.

- **Drive-root boundary (DEF-2).** A repo checked out at a filesystem root
  (`F:/` or `/`) makes the boundary match everything on that filesystem.
  This layout is extremely unusual. Deferred; fix if encountered.

- **NotebookEdit and unlisted write tools.** The guard's switch statement
  matches a fixed set of tool names. `NotebookEdit` and any future write
  tool not added to the switch bypass both the existing protected-path
  check and the new boundary check. This is a pre-existing gap not
  introduced by this change.

- **Codex `apply_patch` via the adapter matcher.** The Codex adapter's
  PreToolUse matcher is `Bash|Edit|Write` and does not include `apply_patch`.
  A patch carrying an outside-worktree path therefore reaches the tool
  without the boundary check on Codex. This is a pre-existing gap:
  ADR 0002 documents hooks as advisory on Codex. Widening the Codex matcher
  is a design change to ADR 0002's semantics and belongs in a separate task.

## Consequences

Existing tests carry no `cwd` field in their payloads and are therefore
unaffected by the new check (fail-open). New test assertions supply a real
`cwd` pointing at the test's git toplevel and verify both blocked (outside
boundary) and allowed (inside boundary) paths, with platform-branched path
fixtures so the assertions are valid on both Windows and Linux CI runners.

`SECURITY.md`, `hooks/guard.ps1`'s header comment, and
`adapters/codex/AGENTS.md`'s guard description are updated to list the new
protection, preserving the "safety net, not a sandbox" framing.
