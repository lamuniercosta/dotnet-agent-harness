#!/usr/bin/env pwsh
# Creates a task branch from an up-to-date base branch, following the convention:
#   {type}/{id}-{slugified-title}     where type is feature | bug | hotfix
#
# By default the branch is created in its own git worktree beside the repo, so
# several tasks - and several agents - can run at once. A single checkout
# serialises them: one branch at a time, and a dirty tree blocks intake
# entirely. Pass -NoWorktree (or set task.worktree: false) for the old
# switch-in-place behaviour.
#
# Retrieval is tracker-neutral via get-task.ps1. harness.yml `tracker` is
# github (default), youtrack, or none. -TaskId is canonical; -Issue is a
# compatibility alias. Pass -Description and no -TaskId for description-only
# intake. Provider/config/id/fetch failures happen before any git mutation.
#
# Usage:
#   ./scripts/new-task-branch.ps1 -TaskId 142
#   ./scripts/new-task-branch.ps1 -Issue 142
#   ./scripts/new-task-branch.ps1 -TaskId 142 -Type bug
#   ./scripts/new-task-branch.ps1 -Description "Add upload retry" -Type feature
#   ./scripts/new-task-branch.ps1 -TaskId 142 -Push
#   ./scripts/new-task-branch.ps1 -TaskId 142 -NoWorktree

[CmdletBinding()]
param(
    [Alias('Issue')]
    [string]$TaskId,
    [string]$Type,
    [string]$Description,
    [string]$BaseBranch,
    [string]$Remote = 'origin',
    [switch]$Push,
    [switch]$Worktree,
    [switch]$NoWorktree,
    [string]$WorktreeRoot,
    [switch]$Help
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '_gate-common.ps1')

if ($Help) {
    Write-Output @"
Usage: new-task-branch.ps1 [-TaskId <id>] [-Type <feature|bug|hotfix>] [-Description <text>] [-BaseBranch <name>] [-Push] [-NoWorktree]

Creates {type}/{id}-{slug} from an up-to-date {Remote}/{BaseBranch}, in its own
git worktree under <repo>.worktrees/ unless worktrees are turned off.
Retrieval is delegated to get-task.ps1 using harness.yml tracker (github, youtrack, none).
If -Description is omitted, the tracker summary is used.
If -Type is omitted, it is inferred by the provider (GitHub labels / YouTrack Type), defaulting to feature.
Hotfix is always an explicit human call - it is never inferred.

OPTIONS:
  -TaskId <id>        Tracker task id (canonical). Alias: -Issue
  -Type <type>        feature | bug | hotfix (inferred from the tracker when omitted)
  -Description <text> Branch description; defaults to the tracker summary
  -BaseBranch <name>  Base branch (default: the remote's default branch)
  -Remote <name>      Remote name (default: origin)
  -Push               Push the new branch and set upstream
  -Worktree           Force worktree mode, whatever harness.yml says
  -NoWorktree         Switch the current checkout instead of creating a worktree
  -WorktreeRoot <dir> Where to create worktrees (default: <repo>.worktrees beside the repo)
  -Help               Show this help
"@
    exit 0
}

if ($Worktree -and $NoWorktree) {
    throw 'Pass -Worktree or -NoWorktree, not both.'
}

if ([string]::IsNullOrWhiteSpace($TaskId) -and [string]::IsNullOrWhiteSpace($Description)) {
    throw 'Pass -TaskId <id>, -Description <text>, or both. See -Help.'
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

function Get-MainWorktreeRoot {
    <#
      The main worktree, not whichever one we happen to be standing in.

      `Get-RepoRoot` returns the git toplevel, which inside a linked worktree is
      that worktree. Deriving the worktree root from it would nest the next
      task's checkout inside the current task's, so worktree roots would grow a
      level deeper on every task. `git worktree list` reports the main worktree
      first, which is the anchor we actually want.
    #>
    param([string]$RepoRoot)

    $listed = @(git -C $RepoRoot worktree list --porcelain 2>$null)
    if ($LASTEXITCODE -eq 0) {
        $first = $listed | Where-Object { $_ -like 'worktree *' } | Select-Object -First 1
        if ($first) {
            $path = $first -replace '^worktree ', ''
            if (Test-Path -LiteralPath $path) { return (Resolve-Path -LiteralPath $path).Path }
        }
    }
    return $RepoRoot
}

$repoRoot = Get-RepoRoot
$mainRoot = Get-MainWorktreeRoot -RepoRoot $repoRoot

# Worktree mode: -Worktree / -NoWorktree beat harness.yml, which beats the default.
# Read the config from the MAIN worktree: harness.yml is gitignored, so a linked
# worktree does not have one and would silently answer with defaults.
$config = Get-HarnessConfig -RepoRoot $mainRoot
$useWorktree = if ($Worktree) { $true } elseif ($NoWorktree) { $false } else { [bool]$config['task.worktree'] }
$tracker = [string]$config['tracker']

# Provider/config/id/fetch failures happen before any branch, worktree, git
# fetch, git push, or file mutation. get-task.ps1 owns retrieval and type
# inference so this script does not duplicate provider logic.
$getTaskScript = Join-Path $PSScriptRoot 'get-task.ps1'
if (-not (Test-Path -LiteralPath $getTaskScript)) {
    throw "Required helper '$getTaskScript' is missing. Re-run install.ps1 to ship get-task.ps1."
}

$getTaskArgs = @{ RepoRoot = $mainRoot }
if (-not [string]::IsNullOrWhiteSpace($TaskId)) { $getTaskArgs['TaskId'] = $TaskId }
if (-not [string]::IsNullOrWhiteSpace($Description)) { $getTaskArgs['Description'] = $Description }
if ($Type) { $getTaskArgs['Type'] = $Type }

$task = & $getTaskScript @getTaskArgs | ConvertFrom-Json
$summary = [string]$task.Summary
$resolvedId = $task.Id
if (-not $Type) {
    $Type = [string]$task.Type
    Write-Host "Type not given; inferred '$Type'."
}

if ([string]::IsNullOrWhiteSpace($summary)) {
    throw 'Could not resolve a description for this task. Pass -Description explicitly.'
}

# A dirty tree only conflicts with switching THIS checkout. Creating a separate
# worktree touches no tracked file here, and refusing anyway would reintroduce
# exactly the serialisation worktrees exist to remove - an agent mid-edit could
# not start the next task.
if (-not $useWorktree) {
    $dirty = git -C $repoRoot status --porcelain
    if ($dirty) {
        throw 'Working tree is not clean. Commit or stash changes before creating a new task branch, or use worktree mode (the default) which leaves this checkout alone.'
    }
}

$slug = ConvertTo-BranchSlug -Text $summary
if (-not $slug) {
    throw "Description slug is empty after sanitizing '$summary'. Pass a -Description with alphanumeric characters."
}

$branch = if ($resolvedId) { "$Type/$resolvedId-$slug" } else { "$Type/$slug" }

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
    $existsHint = if ($useWorktree) {
        "Branch '$branch' already exists locally. Find its worktree with 'git worktree list', or delete the branch if it is stale."
    }
    else {
        "Branch '$branch' already exists locally. Switch to it with 'git switch $branch'."
    }
    throw $existsHint
}

$worktreePath = $null

if ($useWorktree) {
    if (-not $WorktreeRoot) {
        $WorktreeRoot = if ($config['task.worktreeRoot']) {
            $config['task.worktreeRoot']
        }
        else {
            # A sibling of the repo, not a child. Git keeps linked worktrees out
            # of `git status`, but `dotnet build`, InspectCode, and every
            # recursive glob still walk them - an in-repo worktree puts one
            # task's checkout into another task's gate results.
            Join-Path (Split-Path $mainRoot -Parent) ((Split-Path $mainRoot -Leaf) + '.worktrees')
        }
    }
    if (-not [System.IO.Path]::IsPathRooted($WorktreeRoot)) {
        $WorktreeRoot = Join-Path $mainRoot $WorktreeRoot
    }

    # Normalise before the containment check so '..', '.', and trailing
    # separators cannot smuggle an in-repo root past it.
    $WorktreeRoot = [System.IO.Path]::GetFullPath($WorktreeRoot)
    $resolvedRepo = [System.IO.Path]::GetFullPath($mainRoot)

    # The one topology the ADR, task skill, workflow rule, and Codex adapter all
    # forbid: a worktree inside the repo. Git keeps linked worktrees out of
    # `git status`, but `dotnet build`, InspectCode, and every recursive glob
    # still walk them, so one task's checkout contaminates another's gate
    # results. The default root is a sibling; an override must not reach back in -
    # whether relative (joined to the repo above) or an absolute in-repo path.
    $sep = [System.IO.Path]::DirectorySeparatorChar
    $altSep = [System.IO.Path]::AltDirectorySeparatorChar
    $repoPrefix = $resolvedRepo.TrimEnd($sep, $altSep) + $sep
    $rootPrefix = $WorktreeRoot.TrimEnd($sep, $altSep) + $sep
    $pathCmp = if ($IsWindows) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
    if ($rootPrefix.StartsWith($repoPrefix, $pathCmp)) {
        throw "Worktree root '$WorktreeRoot' is inside the repository '$resolvedRepo'. Worktrees must live outside the repo (the default is a sibling, '$(Split-Path $resolvedRepo -Leaf).worktrees'), because dotnet build, InspectCode, and recursive globs walk in-repo worktrees and mix one task's files into another's gate results. Pass -WorktreeRoot with a path outside the repo, or set task.worktreeRoot in harness.yml."
    }

    # Branch names carry '/', which would silently become a directory level.
    $worktreePath = Join-Path $WorktreeRoot ($branch -replace '/', '-')
    if (Test-Path -LiteralPath $worktreePath) {
        throw "Worktree path '$worktreePath' already exists. Remove it with 'git worktree remove' (or delete it) before reusing the name."
    }

    if (-not (Test-Path -LiteralPath $WorktreeRoot)) {
        New-Item -ItemType Directory -Path $WorktreeRoot -Force | Out-Null
    }

    Write-Host "Creating worktree for '$branch' from $Remote/$BaseBranch..."
    git -C $repoRoot worktree add -b $branch -- $worktreePath "$Remote/$BaseBranch"
    if ($LASTEXITCODE -ne 0) { throw "Failed to create worktree for '$branch' at '$worktreePath'." }
}
else {
    Write-Host "Creating '$branch' from $Remote/$BaseBranch..."
    git -C $repoRoot switch -c $branch "$Remote/$BaseBranch"
    if ($LASTEXITCODE -ne 0) { throw "Failed to create branch '$branch'." }
}

# Gitignored files do not come with a new worktree, and harness.yml is one of
# them. Without it every configured threshold silently reverts to the harness
# default - a gate that passes because it forgot the bar, which is the one
# failure this pipeline exists to prevent. Copy it, or say plainly that the
# worktree is running on defaults.
$configWarnings = @()
if ($worktreePath) {
    $sourceConfig = Join-Path $mainRoot 'harness.yml'
    if (Test-Path -LiteralPath $sourceConfig) {
        Copy-Item -LiteralPath $sourceConfig -Destination (Join-Path $worktreePath 'harness.yml') -Force
        Write-Host 'Copied harness.yml into the worktree (gitignored, so git does not).'
    }
    else {
        $configWarnings += 'No harness.yml in the main worktree - gates in this worktree run on harness defaults.'
    }

    # Spec Kit is a runtime dependency, not vendored, so it is gitignored too.
    # Re-initialising it is the consumer's call, not something to do behind them.
    if ((Test-Path -LiteralPath (Join-Path $mainRoot '.specify')) -and
        -not (Test-Path -LiteralPath (Join-Path $worktreePath '.specify'))) {
        $configWarnings += "Spec Kit's .specify/ is gitignored and was not copied - run 'specify init' in the worktree before any /speckit-* step."
    }
}

if ($Push) {
    $pushFrom = if ($worktreePath) { $worktreePath } else { $repoRoot }
    Write-Host "Pushing '$branch' to $Remote..."
    git -C $pushFrom push -u $Remote $branch
    if ($LASTEXITCODE -ne 0) { throw "Failed to push '$branch'." }
}

# GitHub auto-links '#142' anywhere in the message. YouTrack links a bare
# readable id in parentheses. Both are suffixes: a subject starting with '#'
# is treated as a comment by git's editor-based commit path and would be
# silently stripped. Description-only intake has no tracker suffix.
$commitSubject = if (-not $resolvedId) {
    $summary
}
elseif ($tracker -eq 'youtrack') {
    "$summary ($resolvedId)"
}
else {
    "$summary (#$resolvedId)"
}

Write-Output ''
Write-Output "Branch created: $branch"
Write-Output "Base:           $Remote/$BaseBranch (up to date)"
if ($worktreePath) {
    Write-Output "Worktree:       $worktreePath"
}
Write-Output "Commit subject: $commitSubject"

foreach ($warning in $configWarnings) { Write-Warning $warning }

Write-Output ''
if ($worktreePath) {
    Write-Output 'Work in the worktree - this checkout is untouched and still on its own branch:'
    Write-Output "  cd `"$worktreePath`""
    Write-Output '  dotnet tool restore   # each worktree restores its own tools'
    Write-Output ''
}
Write-Output 'Reference the task in commit subjects so the tracker links the work. Before opening a PR, run:'
Write-Output '  ./scripts/rebase-task-branch.ps1 -Push'
if ($worktreePath) {
    Write-Output ''
    Write-Output 'When the PR is merged, remove the worktree:'
    Write-Output "  git worktree remove `"$worktreePath`""
}
