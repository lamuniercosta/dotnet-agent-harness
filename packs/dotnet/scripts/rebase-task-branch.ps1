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

# Record what this checkout last knew the remote task ref to be, and the local tip,
# BEFORE fetching. The fetch below advances the remote-tracking ref onto whatever
# the remote now holds; capturing after it cannot tell "the remote still holds the
# commit I pushed" from "someone advanced the remote while I wasn't looking", and a
# force in the second case silently deletes their work. Reading the value first
# keeps that distinction: the remote is only unsafe to force over if it CHANGED
# from what we knew to a commit this checkout never had.
$remoteTaskRef = "refs/remotes/$Remote/$current"
$knownRemoteTip = (git rev-parse --verify --quiet $remoteTaskRef)
if ($knownRemoteTip) { $knownRemoteTip = $knownRemoteTip.Trim() }
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
    # A first push has no remote branch to overwrite, and a fast-forward needs no
    # force; either way this stays a plain push. A force is needed only when the
    # rebase left local history no longer a fast-forward of the remote tip.
    if ($currentRemoteTip -ne $knownRemoteTip) {
        # The remote moved since we last knew it. Safe to force over only if that
        # new tip is something this checkout already had (e.g. our own push seen
        # from another angle); if it is not in our pre-fetch history, another actor
        # advanced the branch and forcing would delete their commits. Refuse.
        git merge-base --is-ancestor $currentRemoteTip $preFetchHead 2>$null
        if ($LASTEXITCODE -ne 0) {
            throw @"
Refusing to push '$current': $Remote/$current advanced to a commit this checkout never had, so it is ahead or has diverged independently. Forcing would delete it.
Reconcile first, then re-run:
  git fetch $Remote
  git rebase $Remote/$current      # replay your work on top of theirs
Inspect what is there with: git log --oneline HEAD..$Remote/$current
"@
        }
    }
    git merge-base --is-ancestor $currentRemoteTip HEAD 2>$null
    # Exit 0: the remote tip is an ancestor of HEAD, so the push fast-forwards and
    # no force is needed. Non-zero: the rebase rewrote history the remote holds, so
    # a lease force is required - safe now the remote tip is known to be either what
    # we pushed or a commit already in local history.
    $needsLease = ($LASTEXITCODE -ne 0)
}
$lease = if ($needsLease) { "--force-with-lease=$destinationRef" } else { $null }

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
        Write-Output "  git push --force-with-lease=refs/heads/$current --set-upstream -- $Remote HEAD:refs/heads/$current"
    }
    else {
        Write-Output "  git push --set-upstream -- $Remote HEAD:refs/heads/$current"
    }
}
