---
name: task
description: The entry point for any new task. Takes a tracker-neutral task id and (optionally) a branch type, reads the task via the configured tracker (github, youtrack, or none), creates a correctly-named branch off the latest default branch (feature/bug/hotfix) in its own git worktree so tasks and agents can run in parallel, then hands off to the mandatory /grill-with-docs alignment step. Also handles the rebase step before a PR. Use when the user gives a task id, says "start task", "create a branch for", "new feature/bug/hotfix", or "rebase before PR".
---

# Task

The **first step of every task.** Turns a tracker task (or a description) into a ready-to-work branch in its own git worktree, kicks off the mandatory alignment grill, and later keeps the branch current before a PR. Invoke this skill instead of calling the scripts by hand — it orchestrates them. Intake runs from the repo root; everything after it runs from the task worktree. The scripts need PowerShell 7 (`pwsh`).

Retrieval is **tracker-neutral**. `harness.yml` `tracker` is the repository-wide source of truth — `github` (default), `youtrack`, or `none`. There is no CLI tracker override and no `task.tracker` setting.

## Parameters

```text
$ARGUMENTS
```

- **id** — the tracker task id. GitHub: a numeric issue number, e.g. `142`. YouTrack: a readable id, e.g. `DAH-123` (preserve case). Optional if a description is given directly. Do not pass an id when `tracker: none`.
- **type** (optional) — `feature` | `bug` | `hotfix`. If omitted, inferred by the provider: GitHub `bug`/`defect` labels → `bug`; YouTrack `Type = Bug` → `bug`; anything else → `feature`. Hotfix is always an explicit human call and is never inferred.

Typical invocation: `/task 142 feature`, `/task DAH-123`, or just `/task 142`.

## Prerequisites

Depends on `harness.yml` `tracker`:

- **`github`** (default) — the [`gh` CLI](https://cli.github.com), authenticated (`gh auth login`). No tokens, config files, or environment variables of your own — `gh` owns the credential.
- **`youtrack`** — `YOUTRACK_URL` and `YOUTRACK_TOKEN` in the environment. Prefer process variables; on Windows, User-scope variables are the fallback so a newly persisted token works without restarting the host. The token must be a permanent token beginning with `perm:`. It is sent only as `Authorization: Bearer` — never in a URL, query string, error, log, or generated file. **Never print a live token.**
- **`none`** — no tracker contact. Description-only intake. Supplying a task id fails before any git mutation.

The tracker is **optional**. With no id to work from, pass a description straight through and everything below still applies:

```powershell
./scripts/new-task-branch.ps1 -Description "Add upload retry" -Type feature
```

## 1. Intake — read the task

```powershell
./scripts/get-task.ps1 -TaskId 142
# YouTrack:
./scripts/get-task.ps1 -TaskId DAH-123
# -TaskId is canonical:
./scripts/get-task.ps1 -TaskId 142
```

`get-task.ps1` returns `Id`, `Summary`, `Description`, and `Type`. Use the summary and description as the source of truth. If the user also supplied a description, prefer theirs only when they say so; otherwise use the tracker summary. This text seeds `specs/<feature>/brief.md` when the change goes through the Spec Kit pipeline.

Do not call `gh` or YouTrack REST yourself — the script owns provider dispatch. Do not echo `YOUTRACK_TOKEN`.

## 2. Resolve the branch type

Use the `type` parameter when given; otherwise infer from the object `get-task.ps1` returned:

- **feature/** — new feature or enhancement
- **bug/** — bug fix
- **hotfix/** — urgent production fix

Hotfix is always an explicit human call.

## 3. Create the worktree (off the latest default branch)

```powershell
./scripts/new-task-branch.ps1 -TaskId 142
# -TaskId is canonical:
./scripts/new-task-branch.ps1 -TaskId 142
# force the type:
./scripts/new-task-branch.ps1 -TaskId 142 -Type bug
# YouTrack readable id (case preserved in the branch name):
./scripts/new-task-branch.ps1 -TaskId DAH-123
# override the description slug:
./scripts/new-task-branch.ps1 -TaskId 142 -Description "Fix null ref on upload"
# create and push:
./scripts/new-task-branch.ps1 -TaskId 142 -Push
# switch this checkout instead of creating a worktree:
./scripts/new-task-branch.ps1 -TaskId 142 -NoWorktree
```

The script fetches `origin`, resolves the remote's default branch, branches from it, and names the branch `{type}/{id}-{slug}` (GitHub `feature/142-…`, YouTrack `feature/DAH-123-…`). Description-only intake omits the id. It refuses to run over an existing branch. Id/fetch/config failures happen before any branch, worktree, git fetch, git push, or file mutation.

By default the branch is created in **its own git worktree** at `<repo>.worktrees/{type}-{id}-{slug}`, a sibling of the repo. **Everything after this step happens in that worktree** — `cd` into the path the script prints before writing any code, and run `dotnet tool restore` there, because each worktree restores its own tools.

Why a worktree: one checkout serialises tasks. A branch held by one agent blocks every other agent, and a dirty tree blocks intake entirely. Separate worktrees remove both limits, so a dirty main checkout is *not* an error in this mode — only under `-NoWorktree`, which switches the current checkout and keeps the old refusal.

Two things a fresh worktree does not inherit, because git does not carry gitignored files:

- **`harness.yml`** — the script copies it, and says so. Without it every configured threshold would silently revert to a harness default. If the main checkout has no `harness.yml`, the script warns that the worktree runs on defaults; that warning is not noise.
- **`.specify/`** — Spec Kit is a runtime dependency, so run `specify init` in the worktree before any `/speckit-*` step. The script warns when the main checkout has it and the worktree does not.

When the PR merges, clean up: `git worktree remove <path>`.

## 4. MANDATORY: grill the development

Once the worktree exists — working inside it from here on — **immediately run `/grill-with-docs`** — do not jump to a spec or code first. This is the essential "question the development" step: it interrogates the task (using the fetched title and body as raw input), settles vocabulary in `CONTEXT.md`, records any ADRs, and produces `specs/<feature>/brief.md`. The spec (`/speckit-specify`) is written from that settled output.

Do not proceed past this step until the grill concludes with shared understanding. For a tiny bug fix the grill is short — but it still happens.

## 5. Commit convention

Reference the task in every commit **subject** so the tracker links the work:

```
Add dark mode toggle (#142)
Add retry handling (DAH-123)
```

The reference is a **suffix, not a prefix**: a subject beginning with `#` is treated as a comment by git's editor-based commit path and gets silently stripped. GitHub auto-links `#142`; YouTrack links the readable id in parentheses. Description-only intake has no tracker suffix.

(Only commit when the user asks — the standard git safety rules still apply.)

## 6. Before a PR — rebase

Always bring the branch up to date so anything merged in the meantime is included:

```powershell
./scripts/rebase-task-branch.ps1 -Push
```

This fetches and rebases onto the remote default branch, then pushes. On conflicts it stops with next steps (`git rebase --continue` / `--abort`) — resolve, then re-run. The push forces with `--force-with-lease` only when the rebase rewrote history the remote branch already holds; a first push (no remote branch yet) is a plain `--set-upstream` push, so it does not trip a force-push guard. Only open the PR after a clean rebase and push.

GitHub remains the code host for remotes, branches, commits, pushes, and pull requests regardless of the issue tracker.

## YouTrack environment (Windows)

One-time setup. It prompts without echoing the token, rejects non-permanent tokens, stores both variables for the Windows user, and makes them available to the current shell. Environment variables are plaintext process/user configuration, not a secret vault.

```powershell
$youTrackUrl = 'https://lamuniercosta.youtrack.cloud'
$secureToken = Read-Host 'Paste the YouTrack permanent token' -AsSecureString
$tokenHandle = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureToken)

try {
    $plainToken = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($tokenHandle)

    if ([string]::IsNullOrWhiteSpace($plainToken) -or
        -not $plainToken.StartsWith('perm:', [StringComparison]::Ordinal)) {
        throw "Expected a YouTrack permanent token beginning with 'perm:'."
    }

    [Environment]::SetEnvironmentVariable('YOUTRACK_URL', $youTrackUrl, 'User')
    [Environment]::SetEnvironmentVariable('YOUTRACK_TOKEN', $plainToken, 'User')

    $env:YOUTRACK_URL = $youTrackUrl
    $env:YOUTRACK_TOKEN = $plainToken

    Write-Host 'YouTrack environment variables were set for this shell and the current Windows user.'
}
finally {
    if ($tokenHandle -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($tokenHandle)
    }

    Remove-Variable plainToken, secureToken, tokenHandle -ErrorAction SilentlyContinue
}
```

Never print `$env:YOUTRACK_TOKEN` or `$plainToken` to confirm the setup.

## Rules

- After the branch is created, `/grill-with-docs` is **mandatory** before any spec or code — never skip straight to `/speckit-specify` or implementation.
- Work in the worktree the script created, not the main checkout. Editing the main checkout puts the change on whatever branch that checkout happens to hold.
- Never create worktrees inside the repo. Git keeps them out of `git status`, but `dotnet build`, InspectCode, and every recursive glob still walk them, so one task's checkout lands in another task's gate results.
- Never branch from a stale local default branch — always from `origin/<default>` (the script fetches first).
- Never open a PR without rebasing first.
- Preserve the task reference in both the branch name and every commit subject.
- Never open or push a PR automatically — that is a human decision at gate 3.
- Never echo, log, or commit `YOUTRACK_TOKEN`.

## Related

- `/grill-with-docs` — the mandatory next step
- `/pipeline` — where this sits in the stage order (stage 0)
- The `github-workflow` rule — read `.cursor/rules/github-workflow.mdc` for the full conventions (filename kept; contents are tracker-neutral)
