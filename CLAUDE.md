# dotnet-agent-harness (this repository)

This file is for **working on the harness itself**. It is not the consumer
`CLAUDE.md` that `install.ps1` writes into adopting repos (that template lives
under `adapters/claude/CLAUDE.md`).

## Task intake in this repo

When starting work from a GitHub issue **in this repository**, use
**`/start-issue <n> [type]`** instead of `/task`.

`/start-issue` is a repo-local skill (`.claude/skills/start-issue/`) that:

1. Runs the same intake/branch flow as harness `/task`
2. Moves Portfolio (and any other board the issue is on) Status → In Progress
   when the current status is empty, Todo, or Backlog
3. Hands off to mandatory `/grill-with-docs`

It is **not** shipped by `install.ps1`. Consumers keep using `/task`.

Requires `gh` with the project scope: `gh auth refresh -s project`.

## Bootstrap canonical skills for self-development

The tracked discovery trees contain only the repo-local `start-issue` authored
overrides. Generate ignored discovery copies for every canonical harness skill:

```powershell
pwsh ./scripts/local/Sync-SelfSkills.ps1
```

The command uses the same Claude and Codex rendering paths as consumer
installation. It refreshes only manifest-owned copies, preserves `start-issue`
and foreign skills, and fails before mutation on an unowned same-name collision.
Reload Claude Code after syncing before expecting new `/name` commands to
resolve. Continue to prefer `/start-issue` over `/task` for issue intake here.

Remove only generated self-development copies with:

```powershell
pwsh ./scripts/local/Sync-SelfSkills.ps1 -Clean
```

This is not a full self-install; `install.ps1` still refuses the harness root.

## Which host and model to run a command on

`scripts/local/Get-ModelRoute.ps1` recommends a host and tier for a pipeline
command, ordered best first, with a **floor** marking the lowest option that
still does the work without losing quality:

```powershell
pwsh ./scripts/local/Get-ModelRoute.ps1 -List
```

```powershell
pwsh ./scripts/local/Get-ModelRoute.ps1 -Command /implement -RepoRoot ../SomeRepo -Area frontend
```

It only advises — it never launches or configures anything. Read down the chain
to the first option you still have allowance for. **If that lands below the
floor, the work waits**; running below it means knowingly accepting reduced
quality, which is the one thing the map exists to make visible.

Record what you actually ran, especially when it differed:

```powershell
pwsh ./scripts/local/Add-RouteDeviation.ps1 -Command /implement -Ran junie:deep -Note 'Claude weekly limit hit'
```

Those deviations are the point, not an admission of failure — they are the
evidence for whether the authored judgments in `route-map.json` hold up. See
`docs/adr/0008-route-map-records-work-demands.md` for why the map records what
work demands rather than what models provide, and `specs/046-route-map-advisor/`
for the reasoning behind each row. Neither script is shipped by `install.ps1`.
