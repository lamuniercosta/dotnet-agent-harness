#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Sets GitHub Project Status to "In Progress" for an issue's project items.

.DESCRIPTION
  Repo-local helper used by /.claude/skills/start-issue (not shipped by install.ps1).

  Discovers project memberships on the issue at runtime. For every project item
  whose Status is not already Done, sets Status to In Progress. If the issue is
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

if ($Help) {
    Get-Help $PSCommandPath -Detailed
    exit 0
}

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw 'gh CLI not found. Install and run gh auth login.'
}

if (-not $Repo) {
    $Repo = (gh repo view --json nameWithOwner -q .nameWithOwner).Trim()
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

$raw = gh api graphql `
    -F "owner=$owner" `
    -F "name=$name" `
    -F "number=$Issue" `
    -F "query=@$queryFile"
$payload = $raw | ConvertFrom-Json

if ($payload.PSObject.Properties['errors']) {
    $msgs = @($payload.errors | ForEach-Object { $_.message }) -join '; '
    throw "GraphQL error: $msgs"
}

$nodes = @()
if ($payload.data.repository.issue.projectItems.nodes) {
    $nodes = @($payload.data.repository.issue.projectItems.nodes)
}

if ($nodes.Count -eq 0) {
    Write-Warning "Issue #$Issue is not on any GitHub Project. Continuing without a Status update."
    exit 0
}

$updated = 0
$skippedDone = 0
$skippedNoStatus = 0

foreach ($node in $nodes) {
    $projectTitle = $node.project.title
    $status = $node.fieldValueByName

    if (-not $status -or $status.__typename -ne 'ProjectV2ItemFieldSingleSelectValue') {
        Write-Warning "Project '$projectTitle': no Status field; skipping."
        $skippedNoStatus++
        continue
    }

    $current = [string]$status.name
    if ($current -eq 'Done') {
        Write-Host "Project '$projectTitle': already Done — leaving unchanged."
        $skippedDone++
        continue
    }

    if ($current -eq 'In Progress') {
        Write-Host "Project '$projectTitle': already In Progress."
        continue
    }

    $inProgress = @($status.field.options | Where-Object { $_.name -eq 'In Progress' } | Select-Object -First 1)
    if (-not $inProgress) {
        Write-Warning "Project '$projectTitle': no 'In Progress' Status option; skipping."
        $skippedNoStatus++
        continue
    }

    gh project item-edit `
        --id $node.id `
        --project-id $node.project.id `
        --field-id $status.field.id `
        --single-select-option-id $inProgress.id | Out-Null

    Write-Host "Project '$projectTitle': $current -> In Progress"
    $updated++
}

Write-Host "Done. Updated=$updated SkippedDone=$skippedDone SkippedNoStatus=$skippedNoStatus"
exit 0
