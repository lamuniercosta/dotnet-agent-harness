# PR-review helper splits around the workspace seam

`pr-review.ps1` is ~3 750 lines and 65 functions mixing offline logic
(schema validation, fingerprint, dedupe, payload render) with workspace
management, pinned-identity threading, gh transport, and verb dispatch.
The six-parameter data clump owner/repo/number/baseSha/headSha/runId
passes through every workspace and publication function. Both problems
were deferred from the #86 round-8 review as DEV-112 (GitHub #89).

## Decision

Split into **two library files** and a **slimmed entrypoint**, all
under `skills/pr-review/scripts/`:

| File | Contains |
|---|---|
| `_pr-review-common.ps1` | Offline/pure functions: utilities, schema validation, fingerprint/dedupe, diff/line mapping, payload build/render, ledger. Script-scope constants (`$SeverityEnum`, `$CategoryEnum`, etc.). |
| `_pr-review-workspace.ps1` | Workspace creation/validation/safety (`Get-WorkspaceRoot` through `Assert-WorkspaceContainedPath`). Pinned-identity factory `New-PrReviewIdentity`. |
| `pr-review.ps1` | Param block, dot-sources both libraries, gh transport, resolve/preflight/post verbs, dispatch block. |

**Dot-source order is mandatory**: common, then workspace, then
entrypoint body. Workspace functions depend on constants and helpers
defined in common. Reversing the order produces undefined-variable
bindings at runtime while AST-replayed tests still pass — a silent
divergence no gate catches.

**Libraries have no `exit` statements and no top-level executable code**
beyond function and constant definitions. `exit` lives only in the
dispatch block of the entrypoint. `Invoke-Validate`'s current exit
calls move there.

**Pinned-identity factory** (`New-PrReviewIdentity`) returns a
`[PSCustomObject]` with PascalCase properties: Owner, Repo, Number,
HeadSha, BaseSha, RunId. Every property is validated at construction
(non-empty strings, Number > 0, SHA format). Null or empty throws
immediately — not at use.

**Test loader** AST-loads all three files via `Parser::ParseFile` in
the same common → workspace → entrypoint order. It never dot-sources
library files; that would execute top-level code and break the property
that no test-time code path reaches `exit` or triggers side effects.
The `constantsLoaded` threshold re-baselines in the same commit that
moves constants across files.

**AST security gate** runs over the **union of all three ASTs**:
"spawns only gh" (no git, no `Start-Process`/`Invoke-Expression`, no
call-operator over a variable outside `Invoke-Gh`), and "exactly one
`System.Diagnostics.Process` start site" as a global count across all
three files. Without union scope, a later change could add a
`Start-Process` in a moved function and the gate would stay green
because the offending code would no longer be inside the parsed file.

**Distribution** requires no manifest change. `install.ps1` copies the
entire `skills/` tree via `Copy-Tree`; both new files land
automatically in `.claude/skills` and `.agents/skills`. Verification:
`Test-InstallArtifacts.ps1` confirms both files appear on both paths.

## Rejected alternatives

**Three library files** (separate `_pr-review-transport.ps1` for gh
functions). The transport is ~200 lines used only by resolve/post,
which remain in the entrypoint. A third file adds ripple for no
functional gain; the transport stays in the entrypoint alongside its
callers.

**PowerShell class for pinned identity.** A `[PrReviewIdentity]` class
enforces shape at construction, but this codebase uses `PSCustomObject`
everywhere. Class syntax requires PowerShell 5+ and some linters flag
it. A factory function returning `PSCustomObject` with construction-time
validation achieves the same invariant without the friction.

**Dot-sourcing libraries in tests.** Would execute top-level code. The
existing loader deliberately avoids this — constants are AST-replayed,
`$PSScriptRoot` assignments skipped. Dot-sourcing `_pr-review-workspace.ps1`
would run `Set-PrivateDirectoryMode` or `New-PrivateDirectory` side
effects in the test process. The AST-load approach extends cleanly to
multiple files.

**Moving offline functions to `scripts/local/`.** They ship to
consumers via `install.ps1`, so they belong in `skills/pr-review/scripts/`.

## Accepted cost

The test loader becomes more complex: it parses three files instead of
one, replays constants from all three, and runs the security gate over
a union AST. The smoke assertion (function-count check) and the
`constantsLoaded` threshold must stay in sync with any future function
or constant moves.

The mandatory dot-source order is a contract with no static
enforcement beyond the test suite. A future contributor who reorders
the dot-source lines will get runtime failures but not a compile-time
error. The ADR and inline comments in the entrypoint are the only
documentation of this constraint.

## Consequences

The ten-verb public contract, workspace path normalization, traversal
and symlink/junction rejection, and exception contracts are unchanged.
This is a pure structural refactor with no behavior change.

The split makes the concern boundary visible in the file system:
offline logic in common, workspace and identity in workspace, I/O and
dispatch in the entrypoint. Future changes to fingerprinting or schema
validation no longer require reading through workspace safety code to
find the function.

The pinned-identity factory replaces the six-parameter data clump with
a single validated object. Call sites that previously threaded six
arguments now pass one identity. Construction-time validation catches
missing or malformed fields before they flow silently to publication.
