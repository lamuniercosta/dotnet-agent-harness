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
