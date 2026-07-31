#!/usr/bin/env pwsh
# Creates a task branch from an up-to-date base branch, following the convention:
#   {type}/{issue}-{slugified-title}     where type is feature | bug | hotfix
#
# The title defaults to the GitHub issue title (fetched with `gh`) unless
# -Description is supplied. The harness is GitHub-native but the tracker is
# optional: pass -Description and no -Issue to work with no tracker at all.
#
# Usage:
#   ./scripts/new-task-branch.ps1 -Issue 142
#   ./scripts/new-task-branch.ps1 -Issue 142 -Type bug
#   ./scripts/new-task-branch.ps1 -Description "Add upload retry" -Type feature
#   ./scripts/new-task-branch.ps1 -Issue 142 -Push

[CmdletBinding()]
param(
    [string]$Issue,
    [string]$Type,
    [string]$Description,
    [string]$BaseBranch,
    [string]$Remote = 'origin',
    [switch]$Push,
    [switch]$Help
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '_gate-common.ps1')

if ($Help) {
    Write-Output @"
Usage: new-task-branch.ps1 [-Issue <number>] [-Type <feature|bug|hotfix>] [-Description <text>] [-BaseBranch <name>] [-Push]

Creates {type}/{issue}-{slug} from an up-to-date {Remote}/{BaseBranch}.
If -Description is omitted, the GitHub issue title is used (requires the `gh` CLI, authenticated).
If -Type is omitted, it is inferred from the issue's labels (a 'bug' label -> bug), defaulting to feature.
Hotfix is always an explicit human call - it is never inferred.

OPTIONS:
  -Issue <number>     GitHub issue number, e.g. 142. Optional when -Description is given
  -Type <type>        feature | bug | hotfix (inferred from labels when omitted)
  -Description <text> Branch description; defaults to the issue title
  -BaseBranch <name>  Base branch (default: the remote's default branch)
  -Remote <name>      Remote name (default: origin)
  -Push               Push the new branch and set upstream
  -Help               Show this help
"@
    exit 0
}

if ([string]::IsNullOrWhiteSpace($Issue) -and [string]::IsNullOrWhiteSpace($Description)) {
    throw 'Pass -Issue <number>, -Description <text>, or both. See -Help.'
}
if ($Issue -and $Issue -notmatch '^\d+$') {
    throw "Issue must be a GitHub issue number, e.g. -Issue 142 (got '$Issue')."
}

$validTypes = @('feature', 'bug', 'hotfix')
if ($Type -and $Type -notin $validTypes) {
    throw "Type must be one of: $($validTypes -join ', '). Example: -Type feature."
}

function ConvertTo-BranchSlug {
    param([string]$Text, [int]$MaxLength = 60)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $s = $Text.Trim()
    $s = $s -replace '[\s_/\\]+', '-'      # whitespace and path separators -> hyphen
    $s = $s -replace '[^A-Za-z0-9-]', ''   # drop anything not safe in a branch name
    $s = $s -replace '-{2,}', '-'          # collapse repeated hyphens
    $s = $s.Trim('-').ToLowerInvariant()
    if ($s.Length -gt $MaxLength) { $s = $s.Substring(0, $MaxLength).Trim('-') }
    return $s
}

$repoRoot = Get-RepoRoot

# Refuse to branch on top of uncommitted work.
$dirty = git -C $repoRoot status --porcelain
if ($dirty) {
    throw 'Working tree is not clean. Commit or stash changes before creating a new task branch.'
}

# --- resolve the title (and type) from the issue when not supplied ----------
$summary = $Description
$issueLabels = @()

if ($Issue -and ([string]::IsNullOrWhiteSpace($summary) -or -not $Type)) {
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        throw "The 'gh' CLI is required to read issue #$Issue. Install it (https://cli.github.com) and run 'gh auth login', or pass -Description and -Type explicitly."
    }

    $raw = gh issue view $Issue --json number,title,body,labels 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Could not read issue #${Issue}: $raw"
    }

    $fetched = $raw | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace($summary)) { $summary = $fetched.title }
    $issueLabels = @($fetched.labels | ForEach-Object { $_.name })
}

if ([string]::IsNullOrWhiteSpace($summary)) {
    throw "Could not resolve a description for issue #$Issue. Pass -Description explicitly."
}

# Hotfix is never inferred - it stays an explicit human call.
if (-not $Type) {
    $Type = if ($issueLabels | Where-Object { $_ -match '^(bug|defect)$' }) { 'bug' } else { 'feature' }
    Write-Host "Type not given; inferred '$Type' from issue labels."
}

$slug = ConvertTo-BranchSlug -Text $summary
if (-not $slug) {
    throw "Description slug is empty after sanitizing '$summary'. Pass a -Description with alphanumeric characters."
}

$branch = if ($Issue) { "$Type/$Issue-$slug" } else { "$Type/$slug" }

# --- resolve the base branch ------------------------------------------------
if (-not $BaseBranch) {
    # Resolve-BaseRef returns e.g. 'origin/main'; strip the remote for git switch.
    $BaseBranch = (Resolve-BaseRef -RepoRoot $repoRoot -Explicit '') -replace "^$([regex]::Escape($Remote))/", ''
    if ($BaseBranch -eq 'HEAD') {
        throw 'Could not determine the base branch. Pass -BaseBranch explicitly.'
    }
    Write-Host "Base branch not given; using '$BaseBranch'."
}

Write-Host "Fetching $Remote..."
git -C $repoRoot fetch $Remote --quiet

git -C $repoRoot rev-parse --verify --quiet "$Remote/$BaseBranch" > $null
if ($LASTEXITCODE -ne 0) {
    throw "Base branch '$Remote/$BaseBranch' not found. Run 'git fetch $Remote' or check the branch name."
}

git -C $repoRoot rev-parse --verify --quiet "refs/heads/$branch" > $null
if ($LASTEXITCODE -eq 0) {
    throw "Branch '$branch' already exists locally. Switch to it with 'git switch $branch'."
}

Write-Host "Creating '$branch' from $Remote/$BaseBranch..."
git -C $repoRoot switch -c $branch "$Remote/$BaseBranch"
if ($LASTEXITCODE -ne 0) { throw "Failed to create branch '$branch'." }

if ($Push) {
    Write-Host "Pushing '$branch' to $Remote..."
    git -C $repoRoot push -u $Remote $branch
    if ($LASTEXITCODE -ne 0) { throw "Failed to push '$branch'." }
}

# GitHub auto-links '#142' anywhere in the message. It is deliberately a suffix,
# not a prefix: a subject starting with '#' is treated as a comment by git's
# editor-based commit path and would be silently stripped.
$commitSubject = if ($Issue) { "$summary (#$Issue)" } else { $summary }

Write-Output ''
Write-Output "Branch created: $branch"
Write-Output "Base:           $Remote/$BaseBranch (up to date)"
Write-Output "Commit subject: $commitSubject"
Write-Output ''
Write-Output 'Reference the issue in commit subjects so GitHub links the work. Before opening a PR, run:'
Write-Output '  ./scripts/rebase-task-branch.ps1 -Push'
