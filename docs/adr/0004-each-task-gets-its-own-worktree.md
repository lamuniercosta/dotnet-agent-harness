# Each task gets its own git worktree

A single checkout serialises tasks. Git allows one branch per worktree, so an
agent holding `feature/142-…` blocks every other agent, and `new-task-branch.ps1`
refused to run at all on a dirty tree — an agent mid-edit could not start the
next task. Multi-agent work made both limits load-bearing rather than annoying.

## Decision

`new-task-branch.ps1` creates the branch in a new worktree by default, at
`<repo>.worktrees/{type}-{issue}-{slug}`. `-NoWorktree` (or `task.worktree: false`
in `harness.yml`) keeps the previous switch-in-place behaviour, dirty-tree
refusal included. `-Worktree` forces the mode on regardless of config.

The dirty-tree check now applies **only** in switch-in-place mode. A dirty tree
conflicts with switching *this* checkout; it has no bearing on creating a
separate one, and refusing anyway would reintroduce exactly the serialisation
worktrees remove.

## Worktrees are siblings, never children

The worktree root defaults to a sibling of the repo, not a directory inside it.
Git excludes linked worktrees from `git status`, which makes in-repo worktrees
look free, but nothing else does: `dotnet build`, InspectCode, and every
recursive glob walk them, so one task's checkout lands in another task's gate
results. This repo already demonstrates the failure — a plain `find` from the
root returns files from the `.claude/worktrees/` checkouts Claude Code creates.

`task.worktreeRoot` overrides the location for a consumer whose layout needs it.

## Gitignored files do not come along

`git worktree add` populates tracked files only, and the harness keeps two
things it needs deliberately untracked:

- **`harness.yml`** is gitignored because it is resolved per consumer. A worktree
  without it silently falls back to harness defaults, so every configured
  threshold reverts and a gate reports a pass the repo never earned — the exact
  failure `_harness-config.ps1` rejects unknown keys to prevent. The script
  copies it in and says so; when the main checkout has none, it warns that the
  worktree runs on defaults.
- **`.specify/`** is a Spec Kit runtime dependency, not vendored (see `NOTICE`).
  The script warns rather than copying: re-initialising someone's Spec Kit
  install behind their back is not the installer's call. `specify init` in the
  worktree is the fix.

`.config/dotnet-tools.json` *is* tracked, so it arrives — but the tools it pins
are restored per worktree, which is why the script prints `dotnet tool restore`
as a next step. That per-worktree restore is the real cost of this decision, and
the reason `-NoWorktree` exists.

## Consequences

Cleanup becomes a step someone has to take: `git worktree remove <path>` after a
merge. Nothing prunes automatically, because a worktree can hold uncommitted
work and deleting that on a schedule would be worse than leaving stale
directories.

`rebase-task-branch.ps1` needed no change. It resolves the repo from the current
directory rather than the script's location, so inside a worktree its
protected-branch and dirty-tree checks already apply to that worktree.

Regression tests copy the pack scripts into a fixture repo rather than invoking
them in place: `Get-RepoRoot` resolves the git toplevel of the *script's* own
location, so running the pack copy from another directory targets this harness
repo. Copying into the fixture is also the honest simulation, since a consumer
runs an installed copy under `<repo>/scripts/`.
