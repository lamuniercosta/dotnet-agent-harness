#!/usr/bin/env pwsh
# Rebases the current task branch onto the latest base branch before opening a PR,
# so the branch includes anything merged in the meantime.
#
# Usage:
#   ./scripts/rebase-task-branch.ps1
#   ./scripts/rebase-task-branch.ps1 -Push        # push after a clean rebase
#   ./scripts/rebase-task-branch.ps1 -BaseBranch main

[CmdletBinding()]
param(
    [string]$BaseBranch,
    [string]$Remote = 'origin',
    [switch]$Push,
    [switch]$Help
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '_gate-common.ps1')

if ($Help) {
    Write-Output @"
Usage: rebase-task-branch.ps1 [-BaseBranch <name>] [-Remote origin] [-Push]

Fetches and rebases the current branch onto {Remote}/{BaseBranch}. On conflict it stops
and prints next steps. With -Push it pushes after a clean rebase, forcing with
--force-with-lease only when the rebase rewrote history the remote branch already holds.
BaseBranch defaults to the remote's default branch.
"@
    exit 0
}

$repoRoot = Get-RepoRoot

if (-not $BaseBranch) {
    $BaseBranch = (Resolve-BaseRef -RepoRoot $repoRoot -Explicit '') -replace "^$([regex]::Escape($Remote))/", ''
    if ($BaseBranch -eq 'HEAD') {
        throw 'Could not determine the base branch. Pass -BaseBranch explicitly.'
    }
}

# Never rebase a shared/integration branch onto itself or another.
$protected = @($BaseBranch, 'main', 'master', 'development', 'develop', 'qa', 'release', 'production', 'HEAD')
$current = (git rev-parse --abbrev-ref HEAD).Trim()
if ($current -in $protected) {
    throw "Refusing to rebase '$current' - it is a protected/integration branch. Switch to your task branch first."
}

$dirty = git status --porcelain
if ($dirty) {
    throw "Working tree is not clean. Commit or stash changes before rebasing."
}

# Record the local tip BEFORE fetching/rebasing. The remote-tracking ref is only a
# fetch cache: a prior IDE auto-fetch or manual `git fetch` can already hold a
# peer's commit, so neither its bare value nor "did it change during our fetch"
# proves we own what it points at. Ancestry of the remote tip against this
# pre-rebase local HEAD is the actual proof. Known limitation: a guidance-only
# (no -Push) run rebases local in place, so a later -Push sees a pre-rebase HEAD
# that no longer contains the originally-pushed commit and will refuse (safe
# false-refuse; the reconcile message applies). Carrying provenance across
# invocations explicitly is out of scope here.
$remoteTaskRef = "refs/remotes/$Remote/$current"
$preFetchHead = (git rev-parse --verify HEAD).Trim()

Write-Host "Fetching $Remote..."
git fetch $Remote --quiet

git rev-parse --verify --quiet "$Remote/$BaseBranch" > $null
if ($LASTEXITCODE -ne 0) { throw "Base branch '$Remote/$BaseBranch' not found." }

Write-Host "Rebasing '$current' onto $Remote/$BaseBranch..."
git rebase "$Remote/$BaseBranch"
if ($LASTEXITCODE -ne 0) {
    Write-Warning "Rebase stopped with conflicts. Resolve them, then:"
    Write-Warning "  git add <files> ; git rebase --continue"
    Write-Warning "Or abort with: git rebase --abort"
    exit 1
}

Write-Host "Rebase clean: '$current' is up to date with $Remote/$BaseBranch."

# Decide plain-vs-force from the freshly fetched remote tip.
$destinationRef = "refs/heads/$current"
$refspec = "HEAD:$destinationRef"
$currentRemoteTip = (git rev-parse --verify --quiet $remoteTaskRef)
$remoteRefExists = ($LASTEXITCODE -eq 0)
if ($currentRemoteTip) { $currentRemoteTip = $currentRemoteTip.Trim() }

$needsLease = $false
if ($remoteRefExists) {
    # The remote tip is safe to force over only if it is already contained in this
    # checkout's pre-rebase history. The remote-tracking ref is a fetch cache, so
    # neither its bare value nor "did it change during our fetch" proves provenance:
    # any prior fetch (IDE auto-fetch, manual `git fetch`) can have pulled a peer's
    # commit into it. Ancestry against the pre-rebase local tip is the actual proof.
    git merge-base --is-ancestor $currentRemoteTip $preFetchHead 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw @"
Refusing to push '$current': $Remote/$current holds a commit not in this checkout's local history, so a peer advanced it (possibly seen via an earlier fetch). Forcing would delete it.
Reconcile first, then re-run:
  git fetch $Remote
  git rebase $Remote/$current      # replay your work on top of theirs
Inspect what is there with: git log --oneline HEAD..$Remote/$current
"@
    }
    git merge-base --is-ancestor $currentRemoteTip HEAD 2>$null
    # Exit 0: remote tip is an ancestor of HEAD, push fast-forwards, no force needed.
    # Non-zero: the rebase rewrote history the remote holds — lease force required,
    # safe now the tip is proven to be in local history.
    $needsLease = ($LASTEXITCODE -ne 0)
}
# Pin the lease to the exact tip we validated as contained in local history. The
# implicit form re-reads the remote-tracking ref at push time, so a fetch between
# printing the guidance and running it could widen the lease onto a peer commit.
$lease = if ($needsLease) { "--force-with-lease=${destinationRef}:$currentRemoteTip" } else { $null }

if ($Push) {
    if ($needsLease) {
        Write-Host "Pushing '$current' to $Remote/$current with --force-with-lease (rebase rewrote pushed history)..."
        git push $lease --set-upstream -- $Remote $refspec
    }
    else {
        Write-Host "Pushing '$current' to $Remote/$current..."
        git push --set-upstream -- $Remote $refspec
    }
    if ($LASTEXITCODE -ne 0) {
        throw "Push to '$Remote/$current' failed. Review Git's error output; the remote branch was not updated."
    }
    Write-Host "Pushed. Branch is ready for a PR."
}
else {
    Write-Output ""
    Write-Output "Next: push the rebased branch, then open the PR:"
    if ($needsLease) {
        Write-Output "  git push --force-with-lease=refs/heads/${current}:$currentRemoteTip --set-upstream -- $Remote HEAD:refs/heads/$current"
    }
    else {
        Write-Output "  git push --set-upstream -- $Remote HEAD:refs/heads/$current"
    }
}
