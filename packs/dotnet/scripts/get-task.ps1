#!/usr/bin/env pwsh
# Tracker-neutral task retrieval. Dispatches on harness.yml `tracker`
# (github | youtrack | none) and returns a JSON object:
#   { Id, Summary, Description, Type }
#
# Offline-test seams (production callers omit them):
#   -EnvironmentReader  { param($Name, $Target) ... }  # Target is Process or User
#   -RestMethodInvoker  { param($Method, $Uri, $Headers, $TimeoutSec) ... }
#   -GitHubInvoker      { param($Id) ... }             # returns gh --json text
#
# The token is sent only as Authorization: Bearer, never in a URL, query
# string, error, or log. Seams must not print it either.

[CmdletBinding()]
param(
    [Alias('Issue')]
    [string]$TaskId,
    [string]$Description,
    [string]$Type,
    [string]$RepoRoot,
    [scriptblock]$EnvironmentReader,
    [scriptblock]$RestMethodInvoker,
    [scriptblock]$GitHubInvoker,
    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '_gate-common.ps1')

if ($Help) {
    Write-Output @'
Usage: get-task.ps1 [-TaskId <id>] [-Type <feature|bug|hotfix>] [-Description <text>] [-RepoRoot <path>]

Reads the configured tracker and writes a JSON object with Id, Summary,
Description, and Type. -Issue is a compatibility alias for -TaskId.

  github    numeric ids only; uses the gh CLI
  youtrack  readable ids such as DAH-123; REST via YOUTRACK_URL / YOUTRACK_TOKEN
  none      description-only; supplying -TaskId / -Issue is an error

OPTIONS:
  -TaskId <id>        Tracker task id (canonical). Alias: -Issue
  -Type <type>        feature | bug | hotfix (inferred when omitted)
  -Description <text> Overrides the fetched summary when supplied
  -RepoRoot <path>    Repo whose harness.yml to read (default: this checkout)
  -Help               Show this help
'@
    exit 0
}

$validTypes = @('feature', 'bug', 'hotfix')
if ($Type -and $Type -notin $validTypes) {
    throw "Type must be one of: $($validTypes -join ', '). Example: -Type feature."
}

if ([string]::IsNullOrWhiteSpace($TaskId) -and [string]::IsNullOrWhiteSpace($Description)) {
    throw 'Pass -TaskId <id>, -Description <text>, or both. See -Help.'
}

if (-not $RepoRoot) { $RepoRoot = Get-RepoRoot }
$config = Get-HarnessConfig -RepoRoot $RepoRoot
$tracker = [string]$config['tracker']

function Protect-SecretText {
    param([AllowNull()][string]$Text, [AllowNull()][string]$Secret)
    if ([string]::IsNullOrEmpty($Text) -or [string]::IsNullOrEmpty($Secret)) { return $Text }
    return $Text.Replace($Secret, '<redacted>')
}

function Get-TrackerEnvironmentVariable {
    param([Parameter(Mandatory)][string]$Name)

    $reader = $EnvironmentReader
    if (-not $reader) {
        $reader = { param([string]$Name, [string]$Target) [Environment]::GetEnvironmentVariable($Name, $Target) }
    }

    $process = & $reader $Name 'Process'
    if ($null -ne $process) {
        if ([string]::IsNullOrWhiteSpace([string]$process)) { return $null }
        return ([string]$process).Trim()
    }

    $onWindows = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
        [System.Runtime.InteropServices.OSPlatform]::Windows)

    if ($onWindows) {
        $user = & $reader $Name 'User'
        if ([string]::IsNullOrWhiteSpace([string]$user)) { return $null }
        return ([string]$user).Trim()
    }

    return $null
}

function Get-YouTrackCustomFieldName {
    param($Issue, [string]$FieldName)

    if ($null -eq $Issue) { return $null }
    $fields = @()
    try { $fields = @($Issue.customFields) } catch { return $null }
    foreach ($field in $fields) {
        if ($null -eq $field) { continue }
        $name = $null
        try { $name = [string]$field.name } catch { continue }
        if ($name -ne $FieldName) { continue }
        $value = $null
        try { $value = $field.value } catch { return $null }
        if ($null -eq $value) { return $null }
        if ($value -is [string]) { return [string]$value }
        try { return [string]$value.name } catch { return $null }
    }
    return $null
}

function ConvertTo-InferredType {
    param([string]$ExplicitType, [string[]]$Labels, [string]$YouTrackType)

    if ($ExplicitType) { return $ExplicitType }
    if ($Labels | Where-Object { $_ -match '^(bug|defect)$' }) { return 'bug' }
    if ($YouTrackType -and ($YouTrackType.Equals('Bug', [StringComparison]::OrdinalIgnoreCase))) { return 'bug' }
    return 'feature'
}

function New-TaskRecord {
    param($Id, [string]$Summary, [string]$DescriptionBody, [string]$ResolvedType)

    [pscustomobject]@{
        Id          = $Id
        Summary     = $Summary
        Description = $DescriptionBody
        Type        = $ResolvedType
    }
}

function Get-GitHubTask {
    param([string]$Id)

    if ($Id -notmatch '^\d+$') {
        throw "GitHub task ids must be numeric, e.g. -TaskId 142 (got '$Id')."
    }

    $raw = $null
    if ($GitHubInvoker) {
        $raw = & $GitHubInvoker $Id
    }
    else {
        if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
            throw "The 'gh' CLI is required to read issue #$Id. Install it (https://cli.github.com) and run 'gh auth login', or pass -Description and -Type explicitly."
        }
        $raw = gh issue view $Id --json number,title,body,labels 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Could not read issue #${Id}: $raw"
        }
    }

    $fetched = $raw | ConvertFrom-Json
    $summary = if (-not [string]::IsNullOrWhiteSpace($Description)) { $Description } else { [string]$fetched.title }
    if ([string]::IsNullOrWhiteSpace($summary)) {
        throw "Could not resolve a description for issue #$Id. Pass -Description explicitly."
    }

    $labels = @()
    try { $labels = @($fetched.labels | ForEach-Object { $_.name }) } catch { $labels = @() }
    $body = ''
    try { $body = [string]$fetched.body } catch { $body = '' }

    return New-TaskRecord -Id ([string]$Id) -Summary $summary -DescriptionBody $body `
        -ResolvedType (ConvertTo-InferredType -ExplicitType $Type -Labels $labels -YouTrackType $null)
}

function Get-YouTrackTask {
    param([string]$Id)

    if ($Id -notmatch '^[A-Za-z][A-Za-z0-9._]*-\d+$') {
        throw "YouTrack task ids must be a readable id such as DAH-123 (got '$Id')."
    }

    $url = Get-TrackerEnvironmentVariable -Name 'YOUTRACK_URL'
    $token = Get-TrackerEnvironmentVariable -Name 'YOUTRACK_TOKEN'

    if ([string]::IsNullOrWhiteSpace($url)) {
        throw 'YOUTRACK_URL is not set. Set it in the process environment, or on Windows as a User-scope variable.'
    }
    if ([string]::IsNullOrWhiteSpace($token)) {
        throw 'YOUTRACK_TOKEN is not set. Set a permanent token (perm:...) in the process environment, or on Windows as a User-scope variable.'
    }
    if (-not $token.StartsWith('perm:', [StringComparison]::Ordinal)) {
        throw "YOUTRACK_TOKEN must be a YouTrack permanent token beginning with 'perm:'."
    }

    $base = $url.Trim().TrimEnd('/')
    $fields = 'idReadable,summary,description,customFields(name,value(name))'
    $uri = "$base/api/issues/$([uri]::EscapeDataString($Id))?fields=$fields"
    $headers = @{
        Accept        = 'application/json'
        Authorization = "Bearer $token"
    }

    $invoker = $RestMethodInvoker
    if (-not $invoker) {
        $invoker = {
            param($Method, $Uri, $Headers, $TimeoutSec)
            Invoke-RestMethod -Method $Method -Uri $Uri -Headers $Headers -TimeoutSec $TimeoutSec
        }
    }

    try {
        $fetched = & $invoker -Method Get -Uri $uri -Headers $headers -TimeoutSec 30
    }
    catch {
        $status = $null
        try { $status = [int]$_.Exception.Response.StatusCode } catch { $status = $null }
        $public = Protect-SecretText -Text $_.Exception.Message -Secret $token
        switch ($status) {
            401 { throw 'YouTrack authentication failed (HTTP 401). Check YOUTRACK_TOKEN is a permanent token with permission to read the task.' }
            403 { throw "YouTrack refused access to task '$Id' (HTTP 403)." }
            404 { throw "YouTrack task '$Id' was not found (HTTP 404)." }
            default { throw "YouTrack request for '$Id' failed: $public" }
        }
    }

    $readable = $Id
    try {
        if (-not [string]::IsNullOrWhiteSpace([string]$fetched.idReadable)) {
            $readable = [string]$fetched.idReadable
        }
    }
    catch { }

    $summary = if (-not [string]::IsNullOrWhiteSpace($Description)) { $Description } else { $null }
    if ([string]::IsNullOrWhiteSpace($summary)) {
        try { $summary = [string]$fetched.summary } catch { $summary = $null }
    }
    if ([string]::IsNullOrWhiteSpace($summary)) {
        throw "Could not resolve a description for task '$readable'. Pass -Description explicitly."
    }

    $body = ''
    try { $body = [string]$fetched.description } catch { $body = '' }
    $ytType = Get-YouTrackCustomFieldName -Issue $fetched -FieldName 'Type'

    return New-TaskRecord -Id $readable -Summary $summary -DescriptionBody $body `
        -ResolvedType (ConvertTo-InferredType -ExplicitType $Type -Labels @() -YouTrackType $ytType)
}

function Get-DescriptionOnlyTask {
    $summary = $Description
    if ([string]::IsNullOrWhiteSpace($summary)) {
        throw 'tracker: none requires -Description. Do not pass -TaskId / -Issue.'
    }
    $resolved = if ($Type) { $Type } else { 'feature' }
    return New-TaskRecord -Id $null -Summary $summary -DescriptionBody $summary -ResolvedType $resolved
}

$task = switch ($tracker) {
    'none' {
        if (-not [string]::IsNullOrWhiteSpace($TaskId)) {
            throw "tracker: none does not accept -TaskId / -Issue (got '$TaskId'). Pass -Description only."
        }
        Get-DescriptionOnlyTask
    }
    'github' {
        if ([string]::IsNullOrWhiteSpace($TaskId)) {
            Get-DescriptionOnlyTask
        }
        else {
            Get-GitHubTask -Id $TaskId.Trim()
        }
    }
    'youtrack' {
        if ([string]::IsNullOrWhiteSpace($TaskId)) {
            Get-DescriptionOnlyTask
        }
        else {
            Get-YouTrackTask -Id $TaskId.Trim()
        }
    }
    default {
        throw "harness.yml tracker '$tracker' is unsupported. Expected github, youtrack, or none."
    }
}

$task | ConvertTo-Json -Compress -Depth 5
