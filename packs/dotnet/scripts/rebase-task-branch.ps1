#!/usr/bin/env pwsh
# Rebases the current task branch onto the latest base branch before opening a PR,
# so the branch includes anything merged in the meantime.
#
# Usage:
#   ./scripts/rebase-task-branch.ps1
#   ./scripts/rebase-task-branch.ps1 -Push        # force-with-lease after a clean rebase
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
and prints next steps. With -Push it force-pushes (--force-with-lease) after a clean rebase.
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

if ($Push) {
    Write-Host "Pushing with --force-with-lease..."
    git push --force-with-lease
    if ($LASTEXITCODE -ne 0) { throw "Push failed. Someone may have pushed to '$current'; re-fetch and retry." }
    Write-Host "Pushed. Branch is ready for a PR."
}
else {
    Write-Output ""
    Write-Output "Next: push the rebased branch, then open the PR:"
    Write-Output "  git push --force-with-lease"
}
