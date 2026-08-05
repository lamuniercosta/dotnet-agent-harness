#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Sets GitHub Project Status to "In Progress" for an issue's project items.

.DESCRIPTION
  Repo-local helper used by /.claude/skills/start-issue (not shipped by install.ps1).

  Discovers project memberships on the issue at runtime. For every project item
  whose Status is empty, Todo, or Backlog, sets Status to In Progress. Leaves
  Done, In Progress, and any other mid-flight statuses alone. If the issue is
  on no projects, warns and exits 0 so /task is not blocked.

.PARAMETER Issue
  GitHub issue number.

.PARAMETER Repo
  owner/name. Defaults to the gh repo for the current directory.

.EXAMPLE
  ./scripts/local/Set-IssueInProgress.ps1 -Issue 40
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [int]$Issue,

    [string]$Repo,

    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Status values we treat as "not started yet" — re-running mid-flight must not
# yank In Review / Blocked / etc. back to In Progress.
$script:StartableStatuses = @('', 'Todo', 'Backlog')

if ($Help) {
    Get-Help $PSCommandPath -Detailed
    exit 0
}

function Assert-GhOk {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Action,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Output
    )

    if ($LASTEXITCODE -ne 0) {
        $detail = if ([string]::IsNullOrWhiteSpace($Output)) { '(no output)' } else { $Output.Trim() }
        throw "gh failed while $Action (exit $LASTEXITCODE): $detail"
    }
}

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw 'gh CLI not found. Install it (https://cli.github.com) and run: gh auth login && gh auth refresh -s project'
}

if (-not $Repo) {
    $repoRaw = gh repo view --json nameWithOwner -q .nameWithOwner 2>&1 | Out-String
    Assert-GhOk -Action 'resolving the current repository (gh auth login?)' -Output $repoRaw
    $Repo = $repoRaw.Trim()
}

if ($Repo -notmatch '^([^/]+)/([^/]+)$') {
    throw "Repo must be owner/name; got: $Repo"
}
$owner = $Matches[1]
$name = $Matches[2]

$queryFile = Join-Path $PSScriptRoot 'set-issue-in-progress.graphql'
if (-not (Test-Path -LiteralPath $queryFile)) {
    throw "Missing GraphQL query file: $queryFile"
}

# -f for String! scalars so names like "2026" are not JSON-parsed as Int.
# -F for Int! number. query=@file must use -F so gh expands the file contents
# (with -f the literal "@path" string is sent and GraphQL rejects it).
# projectItems(first: 20) — no pagination; issues rarely sit on more boards.
$raw = gh api graphql `
    -f "owner=$owner" `
    -f "name=$name" `
    -F "number=$Issue" `
    -F "query=@$queryFile" 2>&1 | Out-String

# gh may prefix a human line before the JSON body on stderr-merged failure.
$jsonText = $raw
if ($raw -match '(?s)(\{.*\})\s*$') {
    $jsonText = $Matches[1]
}

$payload = $null
try { $payload = $jsonText | ConvertFrom-Json } catch { $payload = $null }

# Prefer a clear message when the issue number does not exist (gh exits 1 and
# returns "issue": null, sometimes with a NOT_FOUND GraphQL error).
if ($null -ne $payload `
    -and $null -ne $payload.data `
    -and $null -ne $payload.data.repository `
    -and $null -eq $payload.data.repository.issue) {
    throw "Issue #$Issue not found in $Repo"
}

Assert-GhOk -Action "querying project items for issue #$Issue (need 'project' scope: gh auth refresh -s project)" -Output $raw

if ($null -eq $payload) {
    throw "gh returned non-JSON while querying issue #$Issue`: $raw"
}

if ($null -ne $payload.PSObject.Properties['errors'] -and $payload.errors) {
    $msgs = @($payload.errors | ForEach-Object { $_.message }) -join '; '
    throw "GraphQL error: $msgs"
}

$issueNode = $payload.data.repository.issue

$nodes = @()
if ($null -ne $issueNode.projectItems -and $null -ne $issueNode.projectItems.nodes) {
    $nodes = @($issueNode.projectItems.nodes)
}

if ($nodes.Count -eq 0) {
    Write-Warning "Issue #$Issue is not on any GitHub Project. Continuing without a Status update."
    exit 0
}

$updated = 0
$skippedDone = 0
$skippedInProgress = 0
$skippedOther = 0
$skippedNoField = 0
$skippedNoOption = 0

foreach ($node in $nodes) {
    $projectTitle = [string]$node.project.title
    $statusField = $node.project.field

    if ($null -eq $statusField -or [string]::IsNullOrWhiteSpace([string]$statusField.id)) {
        Write-Warning "Project '$projectTitle': board has no Status field; skipping."
        $skippedNoField++
        continue
    }

    $current = ''
    $value = $node.fieldValueByName
    if ($null -ne $value -and $value.__typename -eq 'ProjectV2ItemFieldSingleSelectValue' -and $null -ne $value.name) {
        $current = [string]$value.name
    }

    if ($current -eq 'Done') {
        Write-Host "Project '$projectTitle': already Done — leaving unchanged."
        $skippedDone++
        continue
    }

    if ($current -eq 'In Progress') {
        Write-Host "Project '$projectTitle': already In Progress."
        $skippedInProgress++
        continue
    }

    if ($script:StartableStatuses -notcontains $current) {
        Write-Host "Project '$projectTitle': Status is '$current' — leaving unchanged (only empty/Todo/Backlog are started)."
        $skippedOther++
        continue
    }

    $inProgress = @($statusField.options | Where-Object { $_.name -eq 'In Progress' } | Select-Object -First 1)
    if ($inProgress.Count -eq 0) {
        Write-Warning "Project '$projectTitle': no 'In Progress' Status option; skipping."
        $skippedNoOption++
        continue
    }

    $label = if ([string]::IsNullOrEmpty($current)) { '(empty)' } else { $current }

    $editOut = gh project item-edit `
        --id $node.id `
        --project-id $node.project.id `
        --field-id $statusField.id `
        --single-select-option-id $inProgress[0].id 2>&1 | Out-String
    Assert-GhOk -Action "setting '$projectTitle' Status to In Progress" -Output $editOut

    Write-Host "Project '$projectTitle': $label -> In Progress"
    $updated++
}

Write-Host ("Done. Updated={0} SkippedDone={1} SkippedInProgress={2} SkippedOther={3} SkippedNoField={4} SkippedNoOption={5}" -f `
    $updated, $skippedDone, $skippedInProgress, $skippedOther, $skippedNoField, $skippedNoOption)
exit 0
