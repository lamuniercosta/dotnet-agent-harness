#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Deterministic helper for the /pr-review skill.

.DESCRIPTION
  Owns only mechanical PR-review operations: resolve/pin a PR, manage the
  off-repo workspace, validate findings/payloads against review-schema.json,
  fingerprint and dedupe findings, build one COMMENT review payload, post it
  via gh api, and render a Markdown fallback.

  Semantic analysis stays with the model. This script never pattern-matches
  code to invent findings.

  Verbs (exactly one per invocation):
    -Resolve [number-or-url]
    -Post -Payload <path>
    -NewWorkspace -Owner <o> -Repo <r> -Pr <n> -HeadSha <sha>
    -Validate -Findings <path> | -Payload <path>
    -Fingerprint -Findings <path>
    -Dedupe -Findings <path> -Prior <path>
    -BuildPayload -Findings <path> -BaseSha <sha> -HeadSha <sha> -Body <path-or-string>
    -MarkdownFallback -Payload <path>
    -Help

.EXAMPLE
  pwsh ./skills/pr-review/scripts/pr-review.ps1 -Help

.EXAMPLE
  pwsh ./skills/pr-review/scripts/pr-review.ps1 -Validate -Findings $env:TEMP/findings.json
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Resolve,

    [switch]$Post,
    [switch]$NewWorkspace,
    [switch]$Validate,
    [switch]$Fingerprint,
    [switch]$Dedupe,
    [switch]$BuildPayload,
    [switch]$MarkdownFallback,
    [switch]$Help,

    [string]$Payload,
    [string]$Findings,
    [string]$Prior,
    [string]$Owner,
    [string]$Repo,
    [int]$Pr,
    [string]$HeadSha,
    [string]$BaseSha,
    [string]$Body
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:SchemaPath = Join-Path $PSScriptRoot 'review-schema.json'
$script:SeverityEnum = @('Critical', 'High', 'Medium', 'Low')
$script:CategoryEnum = @('risk', 'security', 'standards', 'spec', 'coverage', 'performance')
$script:VerdictEnum = @('CONFIRMED', 'PLAUSIBLE')
$script:SideEnum = @('LEFT', 'RIGHT')
$script:PlacementEnum = @('inline', 'file', 'summary')

# ---------------------------------------------------------------------------
# Usage / dispatch helpers
# ---------------------------------------------------------------------------

function Show-Usage {
    @'
pr-review.ps1 — deterministic helper for /pr-review

USAGE (exactly one verb):
  -Help
  -Resolve [<number-or-url>]
  -Post -Payload <path>
  -NewWorkspace -Owner <o> -Repo <r> -Pr <n> -HeadSha <sha>
  -Validate (-Findings <path> | -Payload <path>)
  -Fingerprint -Findings <path>
  -Dedupe -Findings <path> -Prior <path>
  -BuildPayload -Findings <path> -BaseSha <sha> -HeadSha <sha> -Body <path-or-string>
  -MarkdownFallback -Payload <path>

NOTES
  - Requires PowerShell 7+ and (for -Resolve/-Post) an authenticated gh CLI.
  - Workspace lives under the OS temp dir: <temp>/pr-review/<owner>-<repo>/<pr>-<headsha>/
  - Exit 0 on success; non-zero on failure. Offline verbs do no network I/O.
'@ | Write-Output
}

function Test-ResolveRequested {
    # -Resolve may be bound as an empty string (current-branch resolution).
    return $PSBoundParameters.ContainsKey('Resolve')
}

# ---------------------------------------------------------------------------
# Common utilities
# ---------------------------------------------------------------------------

function Assert-GhPresent {
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        throw 'gh CLI not found. Install https://cli.github.com and run: gh auth login'
    }
}

function Invoke-Gh {
    <#
      Run gh, capture merged stdout/stderr, assert exit 0, return trimmed text.
    #>
    param(
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][string[]]$GhArgs,
        [switch]$AllowFailure
    )

    $output = & gh @GhArgs 2>&1 | Out-String
    if (-not $AllowFailure -and $LASTEXITCODE -ne 0) {
        $detail = if ([string]::IsNullOrWhiteSpace($output)) { '(no output)' } else { $output.Trim() }
        throw "gh failed while $Action (exit $LASTEXITCODE): $detail"
    }
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Text     = $output
    }
}

function ConvertFrom-GhJson {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][string]$Action
    )

    $jsonText = $Text
    if ($Text -match '(?s)(\[.*\]|\{.*\})\s*$') {
        $jsonText = $Matches[1]
    }

    try {
        return $jsonText | ConvertFrom-Json -Depth 100
    }
    catch {
        throw "Failed to parse gh JSON while $Action`: $($_.Exception.Message)`nRaw: $($Text.Trim())"
    }
}

function Read-JsonFile {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "File not found: $Path"
    }
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding utf8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "File is empty: $Path"
    }
    try {
        return $raw | ConvertFrom-Json -Depth 100
    }
    catch {
        throw "Invalid JSON in ${Path}: $($_.Exception.Message)"
    }
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory)]$Value,
        [Parameter(Mandatory)][string]$Path
    )
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    ($Value | ConvertTo-Json -Depth 100) | Set-Content -LiteralPath $Path -Encoding utf8
}

function Get-PropertyValue {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [hashtable] -or $Object -is [System.Collections.IDictionary]) {
        if ($Object.ContainsKey($Name)) { return $Object[$Name] }
        return $null
    }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}

function Test-HasProperty {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $false }
    if ($Object -is [hashtable] -or $Object -is [System.Collections.IDictionary]) {
        return $Object.ContainsKey($Name)
    }
    return $null -ne $Object.PSObject.Properties[$Name]
}

function Normalize-PathKey {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    return (($Path -replace '\\', '/').Trim().TrimStart('./')).ToLowerInvariant()
}

function Get-SchemaDocument {
    if (-not (Test-Path -LiteralPath $script:SchemaPath)) {
        throw "Missing schema file: $script:SchemaPath"
    }
    return Read-JsonFile -Path $script:SchemaPath
}

# ---------------------------------------------------------------------------
# Workspace
# ---------------------------------------------------------------------------

function Get-WorkspaceRoot {
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][int]$Pr,
        [Parameter(Mandatory)][string]$HeadSha
    )

    $safeOwner = ($Owner -replace '[^A-Za-z0-9._-]', '_')
    $safeRepo = ($Repo -replace '[^A-Za-z0-9._-]', '_')
    $safeSha = ($HeadSha -replace '[^A-Fa-f0-9]', '').ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($safeSha)) {
        throw "HeadSha must be a hex git SHA; got: $HeadSha"
    }

    $base = Join-Path ([System.IO.Path]::GetTempPath()) 'pr-review'
    $repoKey = "${safeOwner}-${safeRepo}"
    $prKey = "${Pr}-${safeSha}"
    return Join-Path (Join-Path $base $repoKey) $prKey
}

function New-OrGetWorkspace {
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][int]$Pr,
        [Parameter(Mandatory)][string]$HeadSha
    )

    $path = Get-WorkspaceRoot -Owner $Owner -Repo $Repo -Pr $Pr -HeadSha $HeadSha
    if (-not (Test-Path -LiteralPath $path)) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }
    return $path
}

function Get-WorkspaceMetaPath {
    param([Parameter(Mandatory)][string]$Workspace)
    return Join-Path $Workspace 'pinned.json'
}

function Read-WorkspacePinned {
    param([Parameter(Mandatory)][string]$Workspace)
    $meta = Get-WorkspaceMetaPath -Workspace $Workspace
    if (-not (Test-Path -LiteralPath $meta)) {
        throw "Workspace is missing pinned.json: $Workspace"
    }
    return Read-JsonFile -Path $meta
}

function Find-WorkspaceForPr {
    <#
      Locate an existing workspace for owner/repo/pr (any head). Prefers the
      pinned head recorded in the newest workspace folder.
    #>
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$Repo,
        [Parameter(Mandatory)][int]$Pr
    )

    $safeOwner = ($Owner -replace '[^A-Za-z0-9._-]', '_')
    $safeRepo = ($Repo -replace '[^A-Za-z0-9._-]', '_')
    $repoDir = Join-Path (Join-Path ([System.IO.Path]::GetTempPath()) 'pr-review') "${safeOwner}-${safeRepo}"
    if (-not (Test-Path -LiteralPath $repoDir)) { return $null }

    $prefix = "$Pr-"
    $candidates = @(Get-ChildItem -LiteralPath $repoDir -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name.StartsWith($prefix) } |
            Sort-Object LastWriteTime -Descending)
    if ($candidates.Count -eq 0) { return $null }
    return $candidates[0].FullName
}

# ---------------------------------------------------------------------------
# Schema validation (native walk — required/enum/const/line shape)
# ---------------------------------------------------------------------------

function Add-Violation {
    param(
        [System.Collections.Generic.List[string]]$List,
        [string]$Path,
        [string]$Message
    )
    $List.Add("${Path}: $Message")
}

function Test-FindingObject {
    param(
        $Finding,
        [string]$Path,
        [System.Collections.Generic.List[string]]$Violations
    )

    foreach ($req in @('severity', 'category', 'file', 'verdict')) {
        if (-not (Test-HasProperty -Object $Finding -Name $req) -or
            $null -eq (Get-PropertyValue -Object $Finding -Name $req) -or
            [string]::IsNullOrWhiteSpace([string](Get-PropertyValue -Object $Finding -Name $req))) {
            Add-Violation -List $Violations -Path $Path -Message "missing required property '$req'"
        }
    }

    $severity = [string](Get-PropertyValue -Object $Finding -Name 'severity')
    if ($severity -and $severity -notin $script:SeverityEnum) {
        Add-Violation -List $Violations -Path "$Path.severity" -Message "must be one of: $($script:SeverityEnum -join ', ')"
    }

    $category = [string](Get-PropertyValue -Object $Finding -Name 'category')
    if ($category -and $category -notin $script:CategoryEnum) {
        Add-Violation -List $Violations -Path "$Path.category" -Message "must be one of: $($script:CategoryEnum -join ', ')"
    }

    $verdict = [string](Get-PropertyValue -Object $Finding -Name 'verdict')
    if ($verdict -and $verdict -notin $script:VerdictEnum) {
        Add-Violation -List $Violations -Path "$Path.verdict" -Message "must be one of: $($script:VerdictEnum -join ', ')"
    }

    foreach ($sideProp in @('side', 'start_side')) {
        if (Test-HasProperty -Object $Finding -Name $sideProp) {
            $sideVal = [string](Get-PropertyValue -Object $Finding -Name $sideProp)
            if ($sideVal -and $sideVal -notin $script:SideEnum) {
                Add-Violation -List $Violations -Path "$Path.$sideProp" -Message "must be LEFT or RIGHT"
            }
        }
    }

    if (Test-HasProperty -Object $Finding -Name 'placement') {
        $placement = [string](Get-PropertyValue -Object $Finding -Name 'placement')
        if ($placement -and $placement -notin $script:PlacementEnum) {
            Add-Violation -List $Violations -Path "$Path.placement" -Message "must be one of: $($script:PlacementEnum -join ', ')"
        }
        if ($placement -eq 'inline' -and $verdict -eq 'PLAUSIBLE') {
            Add-Violation -List $Violations -Path $Path -Message "PLAUSIBLE findings cannot use placement 'inline' (summary-only)"
        }
    }

    $hasLine = (Test-HasProperty -Object $Finding -Name 'line') -and ($null -ne (Get-PropertyValue -Object $Finding -Name 'line'))
    $hasStart = (Test-HasProperty -Object $Finding -Name 'start_line') -and ($null -ne (Get-PropertyValue -Object $Finding -Name 'start_line'))
    if ($hasStart -and -not $hasLine) {
        Add-Violation -List $Violations -Path $Path -Message "start_line requires line"
    }
    if ($hasStart -and $hasLine) {
        $startLine = [int](Get-PropertyValue -Object $Finding -Name 'start_line')
        $line = [int](Get-PropertyValue -Object $Finding -Name 'line')
        if ($startLine -gt $line) {
            Add-Violation -List $Violations -Path $Path -Message "start_line ($startLine) must be <= line ($line)"
        }
    }
}

function Test-ReviewCommentObject {
    param(
        $Comment,
        [string]$Path,
        [System.Collections.Generic.List[string]]$Violations
    )

    foreach ($req in @('path', 'body')) {
        $val = Get-PropertyValue -Object $Comment -Name $req
        if ([string]::IsNullOrWhiteSpace([string]$val)) {
            Add-Violation -List $Violations -Path $Path -Message "missing required property '$req'"
        }
    }

    $hasLine = (Test-HasProperty -Object $Comment -Name 'line') -and ($null -ne (Get-PropertyValue -Object $Comment -Name 'line'))
    $hasStart = (Test-HasProperty -Object $Comment -Name 'start_line') -and ($null -ne (Get-PropertyValue -Object $Comment -Name 'start_line'))
    if (-not $hasLine) {
        Add-Violation -List $Violations -Path $Path -Message "must include 'line' (single-line) or 'start_line'+'line' (multi-line)"
    }
    if ($hasStart -and $hasLine) {
        $startLine = [int](Get-PropertyValue -Object $Comment -Name 'start_line')
        $line = [int](Get-PropertyValue -Object $Comment -Name 'line')
        if ($startLine -gt $line) {
            Add-Violation -List $Violations -Path $Path -Message "start_line ($startLine) must be <= line ($line)"
        }
    }

    foreach ($sideProp in @('side', 'start_side')) {
        if (Test-HasProperty -Object $Comment -Name $sideProp) {
            $sideVal = [string](Get-PropertyValue -Object $Comment -Name $sideProp)
            if ($sideVal -and $sideVal -notin $script:SideEnum) {
                Add-Violation -List $Violations -Path "$Path.$sideProp" -Message "must be LEFT or RIGHT"
            }
        }
    }
}

function Test-ReviewPayloadObject {
    param(
        $Payload,
        [string]$Path,
        [System.Collections.Generic.List[string]]$Violations
    )

    foreach ($req in @('commit_id', 'event', 'body')) {
        if (-not (Test-HasProperty -Object $Payload -Name $req) -or
            $null -eq (Get-PropertyValue -Object $Payload -Name $req) -or
            ($req -ne 'body' -and [string]::IsNullOrWhiteSpace([string](Get-PropertyValue -Object $Payload -Name $req)))) {
            Add-Violation -List $Violations -Path $Path -Message "missing required property '$req'"
        }
    }

    $event = [string](Get-PropertyValue -Object $Payload -Name 'event')
    if ($event -and $event -ne 'COMMENT') {
        Add-Violation -List $Violations -Path "$Path.event" -Message "const must be 'COMMENT' (never APPROVE or REQUEST_CHANGES)"
    }

    $commitId = [string](Get-PropertyValue -Object $Payload -Name 'commit_id')
    if ($commitId -and $commitId.Length -lt 7) {
        Add-Violation -List $Violations -Path "$Path.commit_id" -Message "must be a git SHA (at least 7 chars)"
    }

    if (Test-HasProperty -Object $Payload -Name 'comments') {
        # ConvertFrom-Json unwraps a single-element JSON array to a lone object,
        # so a one-comment payload arrives here as a scalar, not an array. Wrap
        # with @() before iterating (as every other comments reader in this file
        # does); a genuine non-array scalar like a string is still rejected, and
        # malformed items are still caught per-item by Test-ReviewCommentObject.
        $comments = Get-PropertyValue -Object $Payload -Name 'comments'
        if ($null -ne $comments -and $comments -is [string]) {
            Add-Violation -List $Violations -Path "$Path.comments" -Message "must be an array of comment objects"
        }
        else {
            $i = 0
            foreach ($c in @($comments)) {
                Test-ReviewCommentObject -Comment $c -Path "$Path.comments[$i]" -Violations $Violations
                $i++
            }
        }
    }
}

function Get-FindingsArray {
    param($Document)
    if ($null -eq $Document) { return @() }
    if ($Document -is [System.Collections.IEnumerable] -and $Document -isnot [string] -and $Document -isnot [pscustomobject] -and $Document -isnot [hashtable]) {
        return @($Document)
    }
    # ConvertFrom-Json arrays become Object[]
    if ($Document -is [System.Array]) {
        return @($Document)
    }
    if (Test-HasProperty -Object $Document -Name 'findings') {
        $inner = Get-PropertyValue -Object $Document -Name 'findings'
        if ($null -eq $inner) { return @() }
        return @($inner)
    }
    # Single finding object
    if (Test-HasProperty -Object $Document -Name 'severity') {
        return @($Document)
    }
    throw 'Findings JSON must be an array, a { findings: [...] } object, or a single finding object.'
}

function Invoke-Validate {
    param(
        [string]$FindingsPath,
        [string]$PayloadPath
    )

    # Touch schema so missing file fails early (and keeps the schema coupled).
    $null = Get-SchemaDocument

    $violations = [System.Collections.Generic.List[string]]::new()

    if ($FindingsPath) {
        $doc = Read-JsonFile -Path $FindingsPath
        try {
            $items = Get-FindingsArray -Document $doc
        }
        catch {
            Write-Error $_.Exception.Message
            exit 1
        }
        if ($items.Count -eq 0) {
            $violations.Add('findings: array is empty (expected at least one finding to validate)')
        }
        $i = 0
        foreach ($f in $items) {
            Test-FindingObject -Finding $f -Path "findings[$i]" -Violations $violations
            $i++
        }
    }
    elseif ($PayloadPath) {
        $doc = Read-JsonFile -Path $PayloadPath
        Test-ReviewPayloadObject -Payload $doc -Path 'payload' -Violations $violations
    }
    else {
        throw '-Validate requires -Findings <path> or -Payload <path>'
    }

    if ($violations.Count -gt 0) {
        Write-Output 'VALIDATION FAILED'
        foreach ($v in $violations) {
            Write-Output " - $v"
        }
        exit 1
    }

    Write-Output 'VALIDATION OK'
    exit 0
}

# ---------------------------------------------------------------------------
# Fingerprint / dedupe
# ---------------------------------------------------------------------------

function Get-NormalizedSubstance {
    param($Finding)
    $parts = @(
        [string](Get-PropertyValue -Object $Finding -Name 'summary')
        [string](Get-PropertyValue -Object $Finding -Name 'failure_scenario')
        [string](Get-PropertyValue -Object $Finding -Name 'evidence')
        [string](Get-PropertyValue -Object $Finding -Name 'body')
    )
    $text = ($parts -join ' ')
    $text = $text.ToLowerInvariant()
    $text = [regex]::Replace($text, '\s+', ' ').Trim()
    return $text
}

function Get-FindingFingerprint {
    param(
        $Finding,
        [string]$Repo,
        [string]$Pr
    )

    $existing = Get-PropertyValue -Object $Finding -Name 'fingerprint'
    if (-not [string]::IsNullOrWhiteSpace([string]$existing)) {
        return [string]$existing
    }

    $repoVal = if ($Repo) { $Repo } else { [string](Get-PropertyValue -Object $Finding -Name 'repo') }
    $prVal = if ($Pr) { $Pr } else { [string](Get-PropertyValue -Object $Finding -Name 'pr') }
    $category = [string](Get-PropertyValue -Object $Finding -Name 'category')
    $file = Normalize-PathKey -Path ([string](Get-PropertyValue -Object $Finding -Name 'file'))
    $line = Get-PropertyValue -Object $Finding -Name 'line'
    $startLine = Get-PropertyValue -Object $Finding -Name 'start_line'
    $side = [string](Get-PropertyValue -Object $Finding -Name 'side')
    if (-not $side) { $side = 'RIGHT' }
    $range = if ($null -ne $startLine -and $null -ne $line) {
        "${side}:${startLine}-${line}"
    }
    elseif ($null -ne $line) {
        "${side}:${line}"
    }
    else {
        'none'
    }
    $substance = Get-NormalizedSubstance -Finding $Finding

    $material = (@($repoVal, $prVal, $category, $file, $range, $substance) -join '|')
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($material)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($bytes)
    }
    finally {
        $sha.Dispose()
    }
    return ([System.BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
}

function Invoke-Fingerprint {
    param([Parameter(Mandatory)][string]$FindingsPath)

    $doc = Read-JsonFile -Path $FindingsPath
    $items = Get-FindingsArray -Document $doc
    $clean = [System.Collections.Generic.List[object]]::new()
    foreach ($f in $items) {
        $clean.Add([pscustomobject]@{
                file        = [string](Get-PropertyValue -Object $f -Name 'file')
                category    = [string](Get-PropertyValue -Object $f -Name 'category')
                severity    = [string](Get-PropertyValue -Object $f -Name 'severity')
                verdict     = [string](Get-PropertyValue -Object $f -Name 'verdict')
                fingerprint = Get-FindingFingerprint -Finding $f
            })
    }
    Write-Output ($clean | ConvertTo-Json -Depth 10)
}

function Get-PriorFingerprints {
    param($PriorDocument)

    $set = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)

    if ($null -eq $PriorDocument) { return $set }

    # Accept: findings array/object, { fingerprints: [...] }, { findings: [...] },
    # or prior review state with nested findings.
    if (Test-HasProperty -Object $PriorDocument -Name 'fingerprints') {
        foreach ($fp in @((Get-PropertyValue -Object $PriorDocument -Name 'fingerprints'))) {
            if (-not [string]::IsNullOrWhiteSpace([string]$fp)) { [void]$set.Add([string]$fp) }
        }
    }

    try {
        $items = Get-FindingsArray -Document $PriorDocument
        foreach ($f in $items) {
            $fp = Get-FindingFingerprint -Finding $f
            if ($fp) { [void]$set.Add($fp) }
        }
    }
    catch {
        # Prior may be a posting-result style object without findings — ignore.
    }

    if (Test-HasProperty -Object $PriorDocument -Name 'priorFindings') {
        foreach ($f in @((Get-PropertyValue -Object $PriorDocument -Name 'priorFindings'))) {
            $fp = Get-FindingFingerprint -Finding $f
            if ($fp) { [void]$set.Add($fp) }
        }
    }

    return $set
}

function Invoke-Dedupe {
    param(
        [Parameter(Mandatory)][string]$FindingsPath,
        [Parameter(Mandatory)][string]$PriorPath
    )

    $doc = Read-JsonFile -Path $FindingsPath
    $prior = Read-JsonFile -Path $PriorPath
    $items = Get-FindingsArray -Document $doc
    $priorSet = Get-PriorFingerprints -PriorDocument $prior

    $kept = [System.Collections.Generic.List[object]]::new()
    $dropped = [System.Collections.Generic.List[object]]::new()

    foreach ($f in $items) {
        $fp = Get-FindingFingerprint -Finding $f
        # Attach fingerprint onto a shallow copy dictionary for output.
        $hash = [ordered]@{}
        foreach ($p in $f.PSObject.Properties) {
            $hash[$p.Name] = $p.Value
        }
        $hash['fingerprint'] = $fp

        if ($priorSet.Contains($fp)) {
            $hash['dedupe'] = 'dropped-identical'
            $dropped.Add([pscustomobject]$hash)
        }
        else {
            $hash['dedupe'] = 'kept'
            $kept.Add([pscustomobject]$hash)
        }
    }

    $result = [pscustomobject]@{
        kept    = @($kept)
        dropped = @($dropped)
        keptCount = $kept.Count
        droppedCount = $dropped.Count
    }
    Write-Output ($result | ConvertTo-Json -Depth 100)
}

# ---------------------------------------------------------------------------
# Build payload / markdown
# ---------------------------------------------------------------------------

function Get-BodyText {
    param([Parameter(Mandatory)][string]$BodyArg)
    if (Test-Path -LiteralPath $BodyArg) {
        return (Get-Content -LiteralPath $BodyArg -Raw -Encoding utf8)
    }
    return $BodyArg
}

function Format-InlineCommentBody {
    param($Finding)

    $explicit = Get-PropertyValue -Object $Finding -Name 'body'
    if (-not [string]::IsNullOrWhiteSpace([string]$explicit)) {
        return [string]$explicit
    }

    $severity = [string](Get-PropertyValue -Object $Finding -Name 'severity')
    $category = [string](Get-PropertyValue -Object $Finding -Name 'category')
    $summary = [string](Get-PropertyValue -Object $Finding -Name 'summary')
    $failure = [string](Get-PropertyValue -Object $Finding -Name 'failure_scenario')
    $evidence = [string](Get-PropertyValue -Object $Finding -Name 'evidence')
    $suggestion = [string](Get-PropertyValue -Object $Finding -Name 'suggestion')

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("**${severity}** · ${category}")
    if ($summary) { $lines.Add($summary) }
    if ($failure) { $lines.Add(""); $lines.Add("Failure scenario: $failure") }
    if ($evidence) { $lines.Add(""); $lines.Add("Evidence: $evidence") }
    if ($suggestion) {
        $lines.Add('')
        $lines.Add('```suggestion')
        $lines.Add($suggestion)
        $lines.Add('```')
    }
    return ($lines -join "`n")
}

function Test-IsInlineEligible {
    param($Finding)

    $verdict = [string](Get-PropertyValue -Object $Finding -Name 'verdict')
    if ($verdict -ne 'CONFIRMED') { return $false }

    $placement = [string](Get-PropertyValue -Object $Finding -Name 'placement')
    if ($placement -eq 'summary' -or $placement -eq 'file') { return $false }

    $file = [string](Get-PropertyValue -Object $Finding -Name 'file')
    $line = Get-PropertyValue -Object $Finding -Name 'line'
    if ([string]::IsNullOrWhiteSpace($file)) { return $false }
    if ($null -eq $line) { return $false }
    if ($placement -eq 'inline' -or [string]::IsNullOrWhiteSpace($placement)) { return $true }
    return $false
}

function New-ReviewCommentFromFinding {
    param($Finding)

    $comment = [ordered]@{
        path = [string](Get-PropertyValue -Object $Finding -Name 'file')
        body = Format-InlineCommentBody -Finding $Finding
        line = [int](Get-PropertyValue -Object $Finding -Name 'line')
    }

    $side = Get-PropertyValue -Object $Finding -Name 'side'
    if ($side) { $comment['side'] = [string]$side } else { $comment['side'] = 'RIGHT' }

    $startLine = Get-PropertyValue -Object $Finding -Name 'start_line'
    if ($null -ne $startLine) {
        $comment['start_line'] = [int]$startLine
        $startSide = Get-PropertyValue -Object $Finding -Name 'start_side'
        if ($startSide) {
            $comment['start_side'] = [string]$startSide
        }
        else {
            $comment['start_side'] = [string]$comment['side']
        }
    }

    return [pscustomobject]$comment
}

function Invoke-BuildPayload {
    param(
        [Parameter(Mandatory)][string]$FindingsPath,
        [Parameter(Mandatory)][string]$BaseSha,
        [Parameter(Mandatory)][string]$HeadSha,
        [Parameter(Mandatory)][string]$BodyArg
    )

    $null = $BaseSha  # reserved for callers/workspace symmetry; payload uses head
    $doc = Read-JsonFile -Path $FindingsPath
    $items = Get-FindingsArray -Document $doc
    $violations = [System.Collections.Generic.List[string]]::new()
    $i = 0
    foreach ($f in $items) {
        Test-FindingObject -Finding $f -Path "findings[$i]" -Violations $violations
        $i++
    }
    if ($violations.Count -gt 0) {
        Write-Output 'VALIDATION FAILED (findings)'
        foreach ($v in $violations) { Write-Output " - $v" }
        exit 1
    }

    $bodyText = Get-BodyText -BodyArg $BodyArg
    $comments = [System.Collections.Generic.List[object]]::new()
    $summaryOnly = [System.Collections.Generic.List[object]]::new()

    foreach ($f in $items) {
        if (Test-IsInlineEligible -Finding $f) {
            $comments.Add((New-ReviewCommentFromFinding -Finding $f))
        }
        else {
            $summaryOnly.Add($f)
        }
    }

    # PLAUSIBLE / non-inline findings are never inline; surface them briefly if
    # the caller did not already mention them (append only when summary-only list
    # is non-empty and body lacks an explicit Questions heading).
    if ($summaryOnly.Count -gt 0 -and $bodyText -notmatch '(?m)^##\s+Questions\b') {
        $q = [System.Collections.Generic.List[string]]::new()
        $q.Add('')
        $q.Add('## Questions / non-inline findings')
        foreach ($f in $summaryOnly) {
            $verdict = [string](Get-PropertyValue -Object $f -Name 'verdict')
            $sev = [string](Get-PropertyValue -Object $f -Name 'severity')
            $cat = [string](Get-PropertyValue -Object $f -Name 'category')
            $sum = [string](Get-PropertyValue -Object $f -Name 'summary')
            $file = [string](Get-PropertyValue -Object $f -Name 'file')
            $q.Add("- [$verdict] **$sev**/$cat ``$file`` — $sum")
        }
        $bodyText = $bodyText.TrimEnd() + "`n" + ($q -join "`n") + "`n"
    }

    $payload = [pscustomobject]@{
        commit_id = $HeadSha
        event     = 'COMMENT'
        body      = $bodyText
        comments  = @($comments)
    }

    $payloadViolations = [System.Collections.Generic.List[string]]::new()
    Test-ReviewPayloadObject -Payload $payload -Path 'payload' -Violations $payloadViolations
    if ($payloadViolations.Count -gt 0) {
        Write-Output 'VALIDATION FAILED (payload)'
        foreach ($v in $payloadViolations) { Write-Output " - $v" }
        exit 1
    }

    Write-Output ($payload | ConvertTo-Json -Depth 100)
}

function ConvertTo-ReviewMarkdown {
    param($Payload)

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('# Pull request review (manual fallback)')
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("commit_id: ``$($Payload.commit_id)``")
    [void]$sb.AppendLine('event: COMMENT')
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('## Summary')
    [void]$sb.AppendLine()
    [void]$sb.AppendLine([string]$Payload.body)
    [void]$sb.AppendLine()

    $comments = @()
    if (Test-HasProperty -Object $Payload -Name 'comments') {
        $comments = @((Get-PropertyValue -Object $Payload -Name 'comments'))
    }
    if ($comments.Count -gt 0) {
        [void]$sb.AppendLine('## Inline comments')
        [void]$sb.AppendLine()
        $n = 1
        foreach ($c in $comments) {
            $path = [string](Get-PropertyValue -Object $c -Name 'path')
            $line = Get-PropertyValue -Object $c -Name 'line'
            $start = Get-PropertyValue -Object $c -Name 'start_line'
            $side = [string](Get-PropertyValue -Object $c -Name 'side')
            if (-not $side) { $side = 'RIGHT' }
            $loc = if ($null -ne $start) { "${path}:${start}-${line} ($side)" } else { "${path}:${line} ($side)" }
            [void]$sb.AppendLine("### Comment $n — ``$loc``")
            [void]$sb.AppendLine()
            [void]$sb.AppendLine([string](Get-PropertyValue -Object $c -Name 'body'))
            [void]$sb.AppendLine()
            $n++
        }
    }

    return $sb.ToString()
}

function Invoke-MarkdownFallback {
    param([Parameter(Mandatory)][string]$PayloadPath)
    $payload = Read-JsonFile -Path $PayloadPath
    $violations = [System.Collections.Generic.List[string]]::new()
    Test-ReviewPayloadObject -Payload $payload -Path 'payload' -Violations $violations
    if ($violations.Count -gt 0) {
        Write-Output 'VALIDATION FAILED'
        foreach ($v in $violations) { Write-Output " - $v" }
        exit 1
    }
    Write-Output (ConvertTo-ReviewMarkdown -Payload $payload)
}

# ---------------------------------------------------------------------------
# Diff line map (for publish-time path/range checks)
# ---------------------------------------------------------------------------

function Get-DiffLineMap {
    <#
      Parse unified patches from the PR files list into a map:
        path -> @{ RIGHT = HashSet[int]; LEFT = HashSet[int] }
    #>
    param($Files)

    $map = @{}
    foreach ($f in @($Files)) {
        $filename = [string](Get-PropertyValue -Object $f -Name 'filename')
        if (-not $filename) { continue }
        $key = Normalize-PathKey -Path $filename
        $right = [System.Collections.Generic.HashSet[int]]::new()
        $left = [System.Collections.Generic.HashSet[int]]::new()

        $patch = [string](Get-PropertyValue -Object $f -Name 'patch')
        if ($patch) {
            $oldLine = 0
            $newLine = 0
            foreach ($raw in ($patch -split "`n")) {
                $line = $raw.TrimEnd("`r")
                if ($line -match '^@@\s+-([0-9]+)(?:,([0-9]+))?\s+\+([0-9]+)(?:,([0-9]+))?\s@@') {
                    $oldLine = [int]$Matches[1]
                    $newLine = [int]$Matches[3]
                    continue
                }
                if ($line.StartsWith('+++') -or $line.StartsWith('---') -or $line.StartsWith('\') -or $line.StartsWith('diff ')) {
                    continue
                }
                if ($line.StartsWith('+')) {
                    [void]$right.Add($newLine)
                    $newLine++
                }
                elseif ($line.StartsWith('-')) {
                    [void]$left.Add($oldLine)
                    $oldLine++
                }
                elseif ($line.StartsWith(' ') -or $line -eq '') {
                    [void]$right.Add($newLine)
                    [void]$left.Add($oldLine)
                    $newLine++
                    $oldLine++
                }
            }
        }

        $map[$key] = @{
            RIGHT    = $right
            LEFT     = $left
            filename = $filename
            status   = [string](Get-PropertyValue -Object $f -Name 'status')
        }
    }
    return $map
}

function Test-CommentAgainstDiff {
    param(
        $Comment,
        $DiffMap,
        [System.Collections.Generic.List[string]]$Problems
    )

    $path = [string](Get-PropertyValue -Object $Comment -Name 'path')
    $key = Normalize-PathKey -Path $path
    if (-not $DiffMap.ContainsKey($key)) {
        $Problems.Add("path not in pinned diff: $path")
        return
    }

    $side = [string](Get-PropertyValue -Object $Comment -Name 'side')
    if (-not $side) { $side = 'RIGHT' }
    $line = [int](Get-PropertyValue -Object $Comment -Name 'line')
    $set = $DiffMap[$key][$side]
    if ($null -eq $set -or -not $set.Contains($line)) {
        $Problems.Add("line $line ($side) not in diff hunks for $path")
    }

    $startLine = Get-PropertyValue -Object $Comment -Name 'start_line'
    if ($null -ne $startLine) {
        $startSide = [string](Get-PropertyValue -Object $Comment -Name 'start_side')
        if (-not $startSide) { $startSide = $side }
        $startSet = $DiffMap[$key][$startSide]
        if ($null -eq $startSet -or -not $startSet.Contains([int]$startLine)) {
            $Problems.Add("start_line $startLine ($startSide) not in diff hunks for $path")
        }
    }
}

# ---------------------------------------------------------------------------
# Resolve
# ---------------------------------------------------------------------------

function Parse-PrTarget {
    param([string]$Target)

    $owner = $null
    $repo = $null
    $number = $null

    if ([string]::IsNullOrWhiteSpace($Target)) {
        Assert-GhPresent
        $raw = Invoke-Gh -Action 'resolving PR for current branch' -GhArgs @(
            'pr', 'view', '--json', 'number,url,baseRefName,headRefName'
        )
        $pr = ConvertFrom-GhJson -Text $raw.Text -Action 'parsing current-branch PR'
        $number = [int]$pr.number
        $repoRaw = Invoke-Gh -Action 'resolving current repository' -GhArgs @(
            'repo', 'view', '--json', 'nameWithOwner', '-q', '.nameWithOwner'
        )
        $full = $repoRaw.Text.Trim()
        if ($full -notmatch '^([^/]+)/([^/]+)$') {
            throw "Unexpected repo nameWithOwner: $full"
        }
        $owner = $Matches[1]
        $repo = $Matches[2]
        return [pscustomobject]@{ Owner = $owner; Repo = $repo; Number = $number }
    }

    if ($Target -match '^(?:https://)?(?:www\.)?github\.com/([^/]+)/([^/]+)/pull/([0-9]+)') {
        return [pscustomobject]@{
            Owner  = $Matches[1]
            Repo   = $Matches[2]
            Number = [int]$Matches[3]
        }
    }

    if ($Target -match '^[0-9]+$') {
        Assert-GhPresent
        $repoRaw = Invoke-Gh -Action 'resolving current repository' -GhArgs @(
            'repo', 'view', '--json', 'nameWithOwner', '-q', '.nameWithOwner'
        )
        $full = $repoRaw.Text.Trim()
        if ($full -notmatch '^([^/]+)/([^/]+)$') {
            throw "Unexpected repo nameWithOwner: $full"
        }
        return [pscustomobject]@{
            Owner  = $Matches[1]
            Repo   = $Matches[2]
            Number = [int]$Target
        }
    }

    throw "Unrecognized -Resolve target (expected integer, GitHub PR URL, or empty): $Target"
}

function Invoke-Resolve {
    param([string]$Target)

    Assert-GhPresent
    $target = Parse-PrTarget -Target $Target
    $owner = $target.Owner
    $repo = $target.Repo
    $number = $target.Number
    $apiBase = "repos/$owner/$repo"

    $prRaw = Invoke-Gh -Action "fetching PR #$number" -GhArgs @(
        'api', "$apiBase/pulls/$number"
    )
    $pr = ConvertFrom-GhJson -Text $prRaw.Text -Action "parsing PR #$number"

    $baseSha = [string]$pr.base.sha
    $headSha = [string]$pr.head.sha
    $baseRef = [string]$pr.base.ref
    $headRef = [string]$pr.head.ref

    $filesRaw = Invoke-Gh -Action 'fetching changed files' -GhArgs @(
        'api', "$apiBase/pulls/$number/files", '--paginate'
    )
    $files = @(ConvertFrom-GhJson -Text $filesRaw.Text -Action 'parsing changed files')

    $commitsRaw = Invoke-Gh -Action 'fetching commits' -GhArgs @(
        'api', "$apiBase/pulls/$number/commits", '--paginate'
    )
    $commits = @(ConvertFrom-GhJson -Text $commitsRaw.Text -Action 'parsing commits')

    $reviewsRaw = Invoke-Gh -Action 'fetching reviews' -GhArgs @(
        'api', "$apiBase/pulls/$number/reviews", '--paginate'
    )
    $reviews = @(ConvertFrom-GhJson -Text $reviewsRaw.Text -Action 'parsing reviews')

    # Review threads (GraphQL) — resolved/unresolved state for incremental dedupe.
    $threadsQuery = @'
query($owner:String!, $repo:String!, $number:Int!) {
  repository(owner:$owner, name:$repo) {
    pullRequest(number:$number) {
      reviewThreads(first: 100) {
        nodes {
          id
          isResolved
          isOutdated
          comments(first: 20) {
            nodes {
              id
              databaseId
              body
              path
              diffHunk
              originalCommit { oid }
              commit { oid }
            }
          }
        }
      }
    }
  }
}
'@
    $threadsTmp = Join-Path ([System.IO.Path]::GetTempPath()) ("pr-review-threads-{0}.graphql" -f [guid]::NewGuid().ToString('n'))
    try {
        Set-Content -LiteralPath $threadsTmp -Value $threadsQuery -Encoding utf8
        $threadsRaw = Invoke-Gh -Action 'fetching review threads' -GhArgs @(
            'api', 'graphql',
            '-f', "owner=$owner",
            '-f', "repo=$repo",
            '-F', "number=$number",
            '-F', "query=@$threadsTmp"
        ) -AllowFailure
        $threads = $null
        if ($threadsRaw.ExitCode -eq 0) {
            $threads = ConvertFrom-GhJson -Text $threadsRaw.Text -Action 'parsing review threads'
        }
        else {
            Write-Warning "Could not fetch review threads (continuing without them): $($threadsRaw.Text.Trim())"
            $threads = [pscustomobject]@{ warning = 'review threads unavailable'; raw = $threadsRaw.Text }
        }
    }
    finally {
        Remove-Item -LiteralPath $threadsTmp -ErrorAction SilentlyContinue
    }

    $ciRaw = Invoke-Gh -Action 'fetching check status' -GhArgs @(
        'api', "$apiBase/commits/$headSha/check-runs", '--paginate'
    ) -AllowFailure
    $ci = $null
    if ($ciRaw.ExitCode -eq 0) {
        $ci = ConvertFrom-GhJson -Text $ciRaw.Text -Action 'parsing check runs'
    }
    else {
        # Fallback: combined status
        $statusRaw = Invoke-Gh -Action 'fetching combined status' -GhArgs @(
            'api', "$apiBase/commits/$headSha/status"
        ) -AllowFailure
        if ($statusRaw.ExitCode -eq 0) {
            $ci = ConvertFrom-GhJson -Text $statusRaw.Text -Action 'parsing combined status'
        }
        else {
            Write-Warning 'Could not fetch CI/check state; continuing without it.'
            $ci = [pscustomobject]@{ warning = 'CI state unavailable' }
        }
    }

    $workspace = New-OrGetWorkspace -Owner $owner -Repo $repo -Pr $number -HeadSha $headSha

    $pinned = [pscustomobject]@{
        owner     = $owner
        repo      = $repo
        pr        = $number
        baseSha   = $baseSha
        headSha   = $headSha
        baseRef   = $baseRef
        headRef   = $headRef
        title     = [string]$pr.title
        htmlUrl   = [string]$pr.html_url
        resolvedAt = (Get-Date).ToUniversalTime().ToString('o')
        workspace = $workspace
    }

    Write-JsonFile -Value $pinned -Path (Join-Path $workspace 'pinned.json')
    Write-JsonFile -Value $pr -Path (Join-Path $workspace 'pr.json')
    Write-JsonFile -Value $files -Path (Join-Path $workspace 'changed-files.json')
    Write-JsonFile -Value $commits -Path (Join-Path $workspace 'commits.json')
    Write-JsonFile -Value $reviews -Path (Join-Path $workspace 'reviews.json')
    Write-JsonFile -Value $threads -Path (Join-Path $workspace 'review-threads.json')
    Write-JsonFile -Value $ci -Path (Join-Path $workspace 'ci.json')

    Write-Output "Resolved PR $owner/$repo#$number"
    Write-Output "baseSha: $baseSha"
    Write-Output "headSha: $headSha"
    Write-Output "workspace: $workspace"
}

# ---------------------------------------------------------------------------
# Post
# ---------------------------------------------------------------------------

function Get-PostResultPath {
    param([Parameter(Mandatory)][string]$Workspace)
    return Join-Path $Workspace 'post-result.json'
}

function Move-UnmappableToSummary {
    param(
        $Payload,
        [object[]]$UnmappableComments
    )

    $body = [string]$Payload.body
    $section = [System.Collections.Generic.List[string]]::new()
    $section.Add('')
    $section.Add('## Unmappable findings')
    $section.Add('')
    $section.Add('The following findings could not be mapped to a current diff location and were moved out of inline comments:')
    $section.Add('')
    foreach ($c in $UnmappableComments) {
        $path = [string](Get-PropertyValue -Object $c -Name 'path')
        $line = Get-PropertyValue -Object $c -Name 'line'
        $cbody = [string](Get-PropertyValue -Object $c -Name 'body')
        $section.Add("### ``${path}:${line}``")
        $section.Add('')
        $section.Add($cbody)
        $section.Add('')
    }

    $kept = @()
    if (Test-HasProperty -Object $Payload -Name 'comments') {
        $all = @((Get-PropertyValue -Object $Payload -Name 'comments'))
        $unmapPaths = @(
            foreach ($u in $UnmappableComments) {
                '{0}|{1}|{2}' -f (Normalize-PathKey ([string](Get-PropertyValue $u 'path'))),
                (Get-PropertyValue $u 'line'),
                ([string](Get-PropertyValue $u 'body')).GetHashCode()
            }
        )
        $kept = @(
            foreach ($c in $all) {
                $key = '{0}|{1}|{2}' -f (Normalize-PathKey ([string](Get-PropertyValue $c 'path'))),
                (Get-PropertyValue $c 'line'),
                ([string](Get-PropertyValue $c 'body')).GetHashCode()
                if ($key -notin $unmapPaths) { $c }
            }
        )
    }

    return [pscustomobject]@{
        commit_id = [string]$Payload.commit_id
        event     = 'COMMENT'
        body      = ($body.TrimEnd() + "`n" + ($section -join "`n"))
        comments  = $kept
    }
}

function Invoke-Post {
    param([Parameter(Mandatory)][string]$PayloadPath)

    Assert-GhPresent
    $payload = Read-JsonFile -Path $PayloadPath

    $violations = [System.Collections.Generic.List[string]]::new()
    Test-ReviewPayloadObject -Payload $payload -Path 'payload' -Violations $violations
    if ($violations.Count -gt 0) {
        Write-Output 'VALIDATION FAILED'
        foreach ($v in $violations) { Write-Output " - $v" }
        exit 1
    }

    $headSha = [string]$payload.commit_id

    # Prefer workspace pinned metadata next to the payload; else scan temp workspaces.
    $workspace = Split-Path -Parent $PayloadPath
    $pinnedPath = Join-Path $workspace 'pinned.json'
    $pinned = $null
    if (Test-Path -LiteralPath $pinnedPath) {
        $pinned = Read-JsonFile -Path $pinnedPath
    }
    if ($null -eq $pinned) {
        throw "Cannot locate pinned.json beside payload ($pinnedPath). Run -Resolve first and post from the workspace."
    }

    $owner = [string]$pinned.owner
    $repo = [string]$pinned.repo
    $number = [int]$pinned.pr
    $pinnedHead = [string]$pinned.headSha

    # Idempotent retry: same head already posted.
    $resultPath = Get-PostResultPath -Workspace $workspace
    if (Test-Path -LiteralPath $resultPath) {
        $prior = Read-JsonFile -Path $resultPath
        if ([string]$prior.headSha -eq $headSha -and $prior.reviewId) {
            Write-Output "Already posted for head $headSha (idempotent no-op)"
            Write-Output "reviewId: $($prior.reviewId)"
            Write-Output ("commentIds: " + ((@($prior.commentIds) | ForEach-Object { $_ }) -join ', '))
            Write-Output "postedAt: $($prior.postedAt)"
            exit 0
        }
    }

    # 1. Re-fetch head; refuse if moved.
    $liveRaw = Invoke-Gh -Action 're-fetching PR head SHA' -GhArgs @(
        'api', "repos/$owner/$repo/pulls/$number", '-q', '.head.sha'
    )
    $liveHead = $liveRaw.Text.Trim()
    if ($liveHead -ne $pinnedHead -or $liveHead -ne $headSha) {
        Write-Error "head moved, re-run resolve/revalidate (pinned=$pinnedHead payload=$headSha live=$liveHead)"
        exit 1
    }

    # 2. Validate comments against pinned diff (refresh files list).
    $filesRaw = Invoke-Gh -Action 'refreshing changed files for line map' -GhArgs @(
        'api', "repos/$owner/$repo/pulls/$number/files", '--paginate'
    )
    $files = @(ConvertFrom-GhJson -Text $filesRaw.Text -Action 'parsing changed files')
    Write-JsonFile -Value $files -Path (Join-Path $workspace 'changed-files.json')
    $diffMap = Get-DiffLineMap -Files $files

    $working = $payload
    $comments = @()
    if (Test-HasProperty -Object $working -Name 'comments') {
        $comments = @((Get-PropertyValue -Object $working -Name 'comments'))
    }

    $unmappable = [System.Collections.Generic.List[object]]::new()
    $mappable = [System.Collections.Generic.List[object]]::new()
    foreach ($c in $comments) {
        $problems = [System.Collections.Generic.List[string]]::new()
        Test-CommentAgainstDiff -Comment $c -DiffMap $diffMap -Problems $problems
        if ($problems.Count -gt 0) {
            $unmappable.Add($c)
        }
        else {
            $mappable.Add($c)
        }
    }

    if ($unmappable.Count -gt 0) {
        # Pre-flight remap: drop known-bad from inline before first post attempt.
        $working = Move-UnmappableToSummary -Payload $working -UnmappableComments @($unmappable)
    }
    else {
        $working = [pscustomobject]@{
            commit_id = [string]$payload.commit_id
            event     = 'COMMENT'
            body      = [string]$payload.body
            comments  = @($mappable)
        }
    }

    function Submit-Review {
        param($ReviewPayload)
        $tmp = Join-Path $workspace 'review.post.json'
        Write-JsonFile -Value $ReviewPayload -Path $tmp
        return Invoke-Gh -Action 'posting pull request review' -GhArgs @(
            'api',
            '--method', 'POST',
            "repos/$owner/$repo/pulls/$number/reviews",
            '--input', $tmp
        ) -AllowFailure
    }

    # Preserve exact outgoing payload before attempt.
    Write-JsonFile -Value $working -Path (Join-Path $workspace 'review.json')

    $response = Submit-Review -ReviewPayload $working

    # 3. If gh rejects line locations, refresh + remap exactly once.
    if ($response.ExitCode -ne 0 -and $response.Text -match '(?i)(line|position|pull_request_review_thread|Path)') {
        Write-Warning 'GitHub rejected one or more line locations; refreshing diff and retrying once.'
        $filesRaw2 = Invoke-Gh -Action 're-refreshing changed files' -GhArgs @(
            'api', "repos/$owner/$repo/pulls/$number/files", '--paginate'
        )
        $files2 = @(ConvertFrom-GhJson -Text $filesRaw2.Text -Action 'parsing changed files (retry)')
        Write-JsonFile -Value $files2 -Path (Join-Path $workspace 'changed-files.json')
        $diffMap2 = Get-DiffLineMap -Files $files2

        $stillBad = [System.Collections.Generic.List[object]]::new()
        $stillGood = [System.Collections.Generic.List[object]]::new()
        $retryComments = @()
        if (Test-HasProperty -Object $working -Name 'comments') {
            $retryComments = @((Get-PropertyValue -Object $working -Name 'comments'))
        }
        foreach ($c in $retryComments) {
            $problems = [System.Collections.Generic.List[string]]::new()
            Test-CommentAgainstDiff -Comment $c -DiffMap $diffMap2 -Problems $problems
            if ($problems.Count -gt 0) { $stillBad.Add($c) } else { $stillGood.Add($c) }
        }

        # If GitHub rejected but our map still thinks lines are fine, treat ALL
        # remaining inline comments as unmappable rather than looping.
        if ($stillBad.Count -eq 0 -and $retryComments.Count -gt 0) {
            $stillBad = [System.Collections.Generic.List[object]]::new()
            foreach ($c in $retryComments) { $stillBad.Add($c) }
            $stillGood = [System.Collections.Generic.List[object]]::new()
        }

        $working = [pscustomobject]@{
            commit_id = [string]$payload.commit_id
            event     = 'COMMENT'
            body      = [string](Get-PropertyValue -Object $working -Name 'body')
            comments  = @($stillGood)
        }
        if ($stillBad.Count -gt 0) {
            $working = Move-UnmappableToSummary -Payload $working -UnmappableComments @($stillBad)
        }

        Write-JsonFile -Value $working -Path (Join-Path $workspace 'review.json')
        $response = Submit-Review -ReviewPayload $working
    }

    if ($response.ExitCode -ne 0) {
        # 4. Auth / rate-limit / API failure — preserve payload + markdown fallback.
        $mdPath = Join-Path $workspace 'review.md'
        $md = ConvertTo-ReviewMarkdown -Payload $working
        Set-Content -LiteralPath $mdPath -Value $md -Encoding utf8
        Write-JsonFile -Value $working -Path (Join-Path $workspace 'review.json')

        Write-Output ''
        Write-Output 'Could not post'
        Write-Output "Fallback markdown: $mdPath"
        Write-Output "Preserved payload: $(Join-Path $workspace 'review.json')"
        Write-Output "gh error: $($response.Text.Trim())"
        exit 1
    }

    $created = ConvertFrom-GhJson -Text $response.Text -Action 'parsing created review'
    $reviewId = $created.id

    # Collect comment ids from the review comments endpoint.
    $commentIds = @()
    $cRaw = Invoke-Gh -Action 'listing review comments' -GhArgs @(
        'api', "repos/$owner/$repo/pulls/$number/reviews/$reviewId/comments"
    ) -AllowFailure
    if ($cRaw.ExitCode -eq 0) {
        $clist = @(ConvertFrom-GhJson -Text $cRaw.Text -Action 'parsing review comment ids')
        $commentIds = @($clist | ForEach-Object { $_.id })
    }

    $postedAt = (Get-Date).ToUniversalTime().ToString('o')
    $result = [pscustomobject]@{
        reviewId   = $reviewId
        commentIds = $commentIds
        headSha    = $headSha
        postedAt   = $postedAt
    }
    Write-JsonFile -Value $result -Path $resultPath
    Write-JsonFile -Value $working -Path (Join-Path $workspace 'review.json')

    Write-Output "Posted COMMENT review $reviewId on $owner/$repo#$number"
    Write-Output "reviewId: $reviewId"
    Write-Output ("commentIds: " + ($commentIds -join ', '))
    Write-Output "headSha: $headSha"
    Write-Output "postedAt: $postedAt"
}

# ---------------------------------------------------------------------------
# Main dispatch
# ---------------------------------------------------------------------------

try {
    if ($Help) {
        Show-Usage
        exit 0
    }

    $resolveRequested = Test-ResolveRequested
    $verbCount = 0
    if ($resolveRequested) { $verbCount++ }
    if ($Post) { $verbCount++ }
    if ($NewWorkspace) { $verbCount++ }
    if ($Validate) { $verbCount++ }
    if ($Fingerprint) { $verbCount++ }
    if ($Dedupe) { $verbCount++ }
    if ($BuildPayload) { $verbCount++ }
    if ($MarkdownFallback) { $verbCount++ }

    if ($verbCount -eq 0) {
        Show-Usage
        Write-Error 'No verb specified. Pass -Help or one of the documented switches.'
        exit 1
    }
    if ($verbCount -gt 1) {
        Write-Error 'Specify exactly one verb per invocation.'
        exit 1
    }

    if ($resolveRequested) {
        Invoke-Resolve -Target $Resolve
        exit 0
    }

    if ($NewWorkspace) {
        if ([string]::IsNullOrWhiteSpace($Owner) -or [string]::IsNullOrWhiteSpace($Repo) -or
            $Pr -le 0 -or [string]::IsNullOrWhiteSpace($HeadSha)) {
            throw '-NewWorkspace requires -Owner, -Repo, -Pr, and -HeadSha'
        }
        $path = New-OrGetWorkspace -Owner $Owner -Repo $Repo -Pr $Pr -HeadSha $HeadSha
        Write-Output $path
        exit 0
    }

    if ($Validate) {
        Invoke-Validate -FindingsPath $Findings -PayloadPath $Payload
    }

    if ($Fingerprint) {
        if ([string]::IsNullOrWhiteSpace($Findings)) {
            throw '-Fingerprint requires -Findings <path>'
        }
        Invoke-Fingerprint -FindingsPath $Findings
        exit 0
    }

    if ($Dedupe) {
        if ([string]::IsNullOrWhiteSpace($Findings) -or [string]::IsNullOrWhiteSpace($Prior)) {
            throw '-Dedupe requires -Findings <path> and -Prior <path>'
        }
        Invoke-Dedupe -FindingsPath $Findings -PriorPath $Prior
        exit 0
    }

    if ($BuildPayload) {
        if ([string]::IsNullOrWhiteSpace($Findings) -or [string]::IsNullOrWhiteSpace($BaseSha) -or
            [string]::IsNullOrWhiteSpace($HeadSha) -or [string]::IsNullOrWhiteSpace($Body)) {
            throw '-BuildPayload requires -Findings, -BaseSha, -HeadSha, and -Body'
        }
        Invoke-BuildPayload -FindingsPath $Findings -BaseSha $BaseSha -HeadSha $HeadSha -BodyArg $Body
        exit 0
    }

    if ($MarkdownFallback) {
        if ([string]::IsNullOrWhiteSpace($Payload)) {
            throw '-MarkdownFallback requires -Payload <path>'
        }
        Invoke-MarkdownFallback -PayloadPath $Payload
        exit 0
    }

    if ($Post) {
        if ([string]::IsNullOrWhiteSpace($Payload)) {
            throw '-Post requires -Payload <path>'
        }
        Invoke-Post -PayloadPath $Payload
        exit 0
    }
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
