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

# A first push has no remote branch of this name to overwrite, so a force is both
# unnecessary and rejected by cruder push guards. Force only when the remote task
# ref already exists AND local history is no longer a fast-forward of it - the real
# post-rebase case. The fetch above made the remote-tracking ref current.
$destinationRef = "refs/heads/$current"
$refspec = "HEAD:$destinationRef"
git rev-parse --verify --quiet "refs/remotes/$Remote/$current" > $null
$remoteRefExists = ($LASTEXITCODE -eq 0)
$needsLease = $false
if ($remoteRefExists) {
    git merge-base --is-ancestor "refs/remotes/$Remote/$current" HEAD 2>$null
    # Exit 0: the remote ref is an ancestor of HEAD, so the push fast-forwards and
    # no force is needed. Non-zero: history diverged and the lease is required.
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
