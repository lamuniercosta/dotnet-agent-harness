#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Reports the always-on context-floor byte and estimated-token cost per host.

.DESCRIPTION
  Repo-local (not packaged, not shipped by install.ps1). Measures the static
  always-on floor from authored sources in this checkout:

    Claude  — alwaysApply: true rule bodies + adapters/claude/CLAUDE.md
    Codex   — adapters/codex/AGENTS.md
    Cursor  — alwaysApply: true rule bodies (no CLAUDE.md adapter)

  Reserve lanes (antigravity, junie, gemini-api, openrouter) have no always-on
  rule surface and are out of scope.

  Bytes are ground truth (UTF-8, LF-normalised). estTokens is ceil(bytes / 4)
  and advisory. -Baseline compares hosts.<name>.bytes only.

.PARAMETER Json
  Write the evidence object as JSON to stdout (or to -OutFile). Exit 0 on
  success, 1 on error. Does not compare against the baseline.

.PARAMETER OutFile
  Write JSON evidence to this path instead of stdout. Implies JSON output.

.PARAMETER Baseline
  Compare current host byte counts against the committed baseline. Exit 0 when
  no host exceeds its baseline bytes, 1 when any does. On regression, prints
  each exceeding host (name, current bytes, baseline bytes). measuredAt, files,
  and estTokens are ignored.

.PARAMETER BaselinePath
  Baseline JSON to read (default: scripts/local/context-floor-baseline.json
  next to this script). Used by tests; the committed file is never required
  to be mutated.

.EXAMPLE
  ./scripts/local/Report-ContextFloor.ps1

.EXAMPLE
  ./scripts/local/Report-ContextFloor.ps1 -Json -OutFile ./scripts/local/context-floor-baseline.json

.EXAMPLE
  ./scripts/local/Report-ContextFloor.ps1 -Baseline
#>
[CmdletBinding()]
param(
    [switch]$Json,

    [string]$OutFile,

    [switch]$Baseline,

    [string]$BaselinePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).Path
if (-not $BaselinePath) {
    $BaselinePath = Join-Path $PSScriptRoot 'context-floor-baseline.json'
}

function Get-RepoRelativePath {
    param([string]$FullPath)

    $full = [System.IO.Path]::GetFullPath($FullPath)
    $root = [System.IO.Path]::GetFullPath($repoRoot)
    if (-not $root.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
        $root += [System.IO.Path]::DirectorySeparatorChar
    }
    if (-not $full.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Path '$FullPath' is outside the repository root."
    }
    return ($full.Substring($root.Length) -replace '\\', '/')
}

function Read-NormalizedText {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Missing source file: $(Get-RepoRelativePath $Path)"
    }
    $text = Get-Content -LiteralPath $Path -Raw -Encoding utf8
    if ($null -eq $text) {
        $text = ''
    }
    return ($text -replace "`r`n", "`n" -replace "`r", "`n")
}

function Split-YamlFrontmatter {
    param(
        [string]$Text,
        [string]$RelativePath
    )

    $lines = $Text.Split([char]10)
    if ($lines.Count -eq 0 -or $lines[0] -ne '---') {
        return [pscustomobject]@{
            HasFrontmatter = $false
            Closed         = $false
            Frontmatter    = $null
            Body           = $Text
        }
    }

    for ($i = 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -eq '---') {
            $fmLines = @()
            if ($i -gt 1) {
                $fmLines = $lines[1..($i - 1)]
            }
            $body = ''
            if ($i -lt ($lines.Count - 1)) {
                $body = $lines[($i + 1)..($lines.Count - 1)] -join "`n"
            }
            return [pscustomobject]@{
                HasFrontmatter = $true
                Closed         = $true
                Frontmatter    = ($fmLines -join "`n")
                Body           = $body
            }
        }
    }

    throw "Unclosed YAML frontmatter in $RelativePath"
}

function Get-AlwaysApplyState {
    param([string]$Frontmatter)

    $match = [regex]::Match($Frontmatter, '(?m)^\s*alwaysApply\s*:\s*(.+)$')
    if (-not $match.Success) {
        return [pscustomobject]@{ State = 'missing'; Value = $null }
    }

    $raw = $match.Groups[1].Value.Trim()
    $hash = $raw.IndexOf('#')
    if ($hash -ge 0) {
        $raw = $raw.Substring(0, $hash).Trim()
    }
    if ($raw.Length -ge 2) {
        $quote = $raw[0]
        if (($quote -eq [char]'"' -or $quote -eq [char]"'") -and $raw[-1] -eq $quote) {
            $raw = $raw.Substring(1, $raw.Length - 2)
        }
    }

    if ($raw -eq 'true' -or $raw -eq 'True' -or $raw -eq 'TRUE') {
        return [pscustomobject]@{ State = 'true'; Value = $raw }
    }
    if ($raw -eq 'false' -or $raw -eq 'False' -or $raw -eq 'FALSE') {
        return [pscustomobject]@{ State = 'false'; Value = $raw }
    }
    return [pscustomobject]@{ State = 'unrecognised'; Value = $raw }
}

function Get-Utf8ByteCount {
    param([string]$Text)
    return [System.Text.Encoding]::UTF8.GetByteCount($Text)
}

function New-HostMeasurement {
    param(
        [int]$Bytes,
        [string[]]$Files
    )

    $fileList = [System.Collections.Generic.List[string]]::new()
    foreach ($file in @($Files)) {
        if ($null -ne $file -and $file -ne '') {
            $fileList.Add($file)
        }
    }

    return [ordered]@{
        bytes     = $Bytes
        estTokens = [int][Math]::Ceiling($Bytes / 4.0)
        files     = $fileList.ToArray()
    }
}

try {
    $rulesDir = Join-Path $repoRoot (Join-Path 'rules' 'pipeline')
    if (-not (Test-Path -LiteralPath $rulesDir)) {
        throw "Missing source file: rules/pipeline"
    }

    $claudeAdapter = Join-Path $repoRoot (Join-Path 'adapters' (Join-Path 'claude' 'CLAUDE.md'))
    $codexAdapter = Join-Path $repoRoot (Join-Path 'adapters' (Join-Path 'codex' 'AGENTS.md'))

    $alwaysOnFiles = [System.Collections.Generic.List[string]]::new()
    $ruleBodyBytes = 0

    $rulePaths = @(Get-ChildItem -LiteralPath $rulesDir -Filter '*.mdc' -File | Sort-Object -Property Name)
    foreach ($rulePath in $rulePaths) {
        $relative = Get-RepoRelativePath $rulePath.FullName
        $text = Read-NormalizedText $rulePath.FullName
        $split = Split-YamlFrontmatter -Text $text -RelativePath $relative

        if (-not $split.HasFrontmatter) {
            Write-Warning "No YAML frontmatter in ${relative}; not counted toward the floor."
            continue
        }

        $apply = Get-AlwaysApplyState -Frontmatter $split.Frontmatter
        switch ($apply.State) {
            'true' {
                $alwaysOnFiles.Add($relative)
                $ruleBodyBytes += Get-Utf8ByteCount $split.Body
            }
            'false' { }
            'missing' {
                Write-Warning "Frontmatter in ${relative} has no alwaysApply field; not counted toward the floor."
            }
            'unrecognised' {
                Write-Warning "Unrecognised alwaysApply value '$($apply.Value)' in ${relative}; not counted toward the floor."
            }
        }
    }

    $claudeAdapterText = Read-NormalizedText $claudeAdapter
    $codexAdapterText = Read-NormalizedText $codexAdapter
    $claudeAdapterRel = Get-RepoRelativePath $claudeAdapter
    $codexAdapterRel = Get-RepoRelativePath $codexAdapter

    $claudeFiles = @($alwaysOnFiles.ToArray() + $claudeAdapterRel)
    $cursorFiles = @($alwaysOnFiles.ToArray())
    $codexFiles = @($codexAdapterRel)

    $claudeBytes = $ruleBodyBytes + (Get-Utf8ByteCount $claudeAdapterText)
    $cursorBytes = $ruleBodyBytes
    $codexBytes = Get-Utf8ByteCount $codexAdapterText

    $hosts = [ordered]@{
        claude = (New-HostMeasurement -Bytes $claudeBytes -Files $claudeFiles)
        codex  = (New-HostMeasurement -Bytes $codexBytes -Files $codexFiles)
        cursor = (New-HostMeasurement -Bytes $cursorBytes -Files $cursorFiles)
    }

    $evidence = [ordered]@{
        schemaVersion = 1
        measuredAt    = (Get-Date -AsUTC -Format o)
        hosts         = $hosts
    }

    $emitJson = $Json -or -not [string]::IsNullOrWhiteSpace($OutFile)
    if ($emitJson) {
        $jsonText = $evidence | ConvertTo-Json -Depth 6
        if (-not [string]::IsNullOrWhiteSpace($OutFile)) {
            $outFull = $OutFile
            if (-not [System.IO.Path]::IsPathRooted($OutFile)) {
                $outFull = Join-Path (Get-Location).Path $OutFile
            }
            $outParent = Split-Path -Parent $outFull
            if ($outParent -and -not (Test-Path -LiteralPath $outParent)) {
                throw "Missing output directory: $outParent"
            }
            [System.IO.File]::WriteAllText($outFull, ($jsonText.TrimEnd() + "`n"), [System.Text.UTF8Encoding]::new($false))
        }
        else {
            Write-Output $jsonText
        }
    }
    else {
        $rows = @(
            [pscustomobject]@{ Host = 'claude'; Bytes = $hosts.claude.bytes; EstTokens = $hosts.claude.estTokens }
            [pscustomobject]@{ Host = 'codex'; Bytes = $hosts.codex.bytes; EstTokens = $hosts.codex.estTokens }
            [pscustomobject]@{ Host = 'cursor'; Bytes = $hosts.cursor.bytes; EstTokens = $hosts.cursor.estTokens }
        )
        $rows | Format-Table -AutoSize | Out-String | Write-Host

        $agentsDir = Join-Path $repoRoot (Join-Path '.claude' 'agents')
        if (Test-Path -LiteralPath $agentsDir) {
            $profiles = @(Get-ChildItem -LiteralPath $agentsDir -Filter '*.md' -File | Sort-Object -Property Name)
            if ($profiles.Count -gt 0) {
                Write-Host 'Agent profiles (listed for reference; not counted — loaded on delegate, not every turn):'
                foreach ($profile in $profiles) {
                    Write-Host "  $(Get-RepoRelativePath $profile.FullName)"
                }
            }
        }
    }

    if ($Baseline) {
        if (-not (Test-Path -LiteralPath $BaselinePath)) {
            throw "Missing source file: $BaselinePath"
        }
        $baselineJson = Get-Content -LiteralPath $BaselinePath -Raw -Encoding utf8
        if ([string]::IsNullOrWhiteSpace($baselineJson)) {
            throw "Baseline file is empty: $BaselinePath"
        }
        $baselineObj = $baselineJson | ConvertFrom-Json
        if ($null -eq $baselineObj.hosts) {
            throw "Baseline is missing hosts: $BaselinePath"
        }

        $regressed = $false
        foreach ($name in @('claude', 'codex', 'cursor')) {
            $currentBytes = [int]$hosts[$name].bytes
            $baseHost = $baselineObj.hosts.PSObject.Properties[$name]
            if ($null -eq $baseHost) {
                throw "Baseline is missing host '$name'"
            }
            $baseBytes = [int]$baseHost.Value.bytes
            if ($currentBytes -gt $baseBytes) {
                $regressed = $true
                $line = "${name} exceeded baseline: current=$currentBytes bytes, baseline=$baseBytes bytes"
                if ($emitJson) {
                    [Console]::Error.WriteLine($line)
                }
                else {
                    Write-Host $line
                }
            }
        }

        if ($regressed) {
            exit 1
        }
    }

    exit 0
}
catch {
    Write-Error $_
    exit 1
}
