#!/usr/bin/env pwsh
# Proves Report-ContextFloor.ps1 emits the evidence schema, attributes files
# by scanning alwaysApply: true rules (not a hardcoded count), and that
# -Baseline ratchets on bytes via a temp copy — never by mutating the
# committed baseline.

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$harnessRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$reporter = Join-Path $PSScriptRoot 'Report-ContextFloor.ps1'
$committedBaseline = Join-Path $PSScriptRoot 'context-floor-baseline.json'

$checks = 0
$failures = 0
$temporaryFiles = [System.Collections.Generic.List[string]]::new()

function Assert-That {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')

    $script:checks++
    if ($Condition) {
        Write-Host "  ok    $Name"
    }
    else {
        Write-Host "  FAIL  $Name" -ForegroundColor Red
        if ($Detail) { Write-Host "        $Detail" -ForegroundColor DarkGray }
        $script:failures++
    }
}

function Invoke-Reporter {
    param([string[]]$ReporterArgs = @())

    $output = & pwsh -NoProfile -File $reporter @ReporterArgs 2>&1 | Out-String
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output   = $output
    }
}

function Get-ExpectedAlwaysOnRules {
    $rulesDir = Join-Path $harnessRoot (Join-Path 'rules' 'pipeline')
    $expected = [System.Collections.Generic.List[string]]::new()
    foreach ($file in @(Get-ChildItem -LiteralPath $rulesDir -Filter '*.mdc' -File | Sort-Object -Property Name)) {
        $text = Get-Content -LiteralPath $file.FullName -Raw -Encoding utf8
        $text = $text -replace "`r`n", "`n" -replace "`r", "`n"
        $lines = $text.Split([char]10)
        if ($lines[0] -ne '---') { continue }
        $closed = $false
        $frontmatter = $null
        for ($i = 1; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -eq '---') {
                $closed = $true
                if ($i -gt 1) {
                    $frontmatter = $lines[1..($i - 1)] -join "`n"
                }
                else {
                    $frontmatter = ''
                }
                break
            }
        }
        if (-not $closed) { continue }
        if ($frontmatter -match '(?m)^\s*alwaysApply\s*:\s*["'']?true["'']?\s*(#.*)?$') {
            $rel = $file.FullName.Substring($harnessRoot.Length).TrimStart([char]'\', [char]'/') -replace '\\', '/'
            $expected.Add($rel)
        }
    }
    return @($expected.ToArray())
}

function ConvertFrom-JsonStdout {
    param([string]$Output)

    $start = $Output.IndexOf('{')
    $end = $Output.LastIndexOf('}')
    if ($start -lt 0 -or $end -lt $start) {
        throw "Reporter output did not contain a JSON object.`n$Output"
    }
    return $Output.Substring($start, $end - $start + 1) | ConvertFrom-Json
}

try {
    Write-Host 'Context floor — JSON evidence'

    $jsonRun = Invoke-Reporter -ReporterArgs @('-Json')
    Assert-That 'Report runs without error with -Json' ($jsonRun.ExitCode -eq 0) "exit $($jsonRun.ExitCode)`n$($jsonRun.Output)"

    $evidence = $null
    try {
        $evidence = ConvertFrom-JsonStdout $jsonRun.Output
        Assert-That 'produces valid JSON with -Json' $true
    }
    catch {
        Assert-That 'produces valid JSON with -Json' $false $_.Exception.Message
    }

    if ($null -ne $evidence) {
        foreach ($name in @('claude', 'codex', 'cursor')) {
            $hostRow = $evidence.hosts.$name
            Assert-That "$name bytes > 0" ($null -ne $hostRow -and [int]$hostRow.bytes -gt 0) "bytes=$($hostRow.bytes)"
            Assert-That "$name estTokens > 0" ($null -ne $hostRow -and [int]$hostRow.estTokens -gt 0) "estTokens=$($hostRow.estTokens)"
            if ($null -ne $hostRow) {
                $expectedTokens = [int][Math]::Ceiling([int]$hostRow.bytes / 4.0)
                Assert-That "$name estTokens is ceil(bytes / 4)" ([int]$hostRow.estTokens -eq $expectedTokens) "estTokens=$($hostRow.estTokens) expected=$expectedTokens"
            }
        }

        Assert-That 'schemaVersion is 1' ([int]$evidence.schemaVersion -eq 1) "schemaVersion=$($evidence.schemaVersion)"
        $rawMeasuredAt = $null
        if ($jsonRun.Output -match '"measuredAt"\s*:\s*"([^"]+)"') {
            $rawMeasuredAt = $Matches[1]
        }
        $parsedAt = $null
        $parsedOk = $false
        try {
            if ($null -ne $rawMeasuredAt) {
                $parsedAt = [datetimeoffset]::Parse(
                    $rawMeasuredAt,
                    [cultureinfo]::InvariantCulture,
                    [System.Globalization.DateTimeStyles]::RoundtripKind)
                $parsedOk = $true
            }
        }
        catch {
            $parsedOk = $false
        }
        Assert-That 'measuredAt parses as ISO-8601' $parsedOk "measuredAt=$rawMeasuredAt"
        if ($parsedOk) {
            $isUtc = ($parsedAt.Offset -eq [timespan]::Zero) -or $rawMeasuredAt.EndsWith('Z')
            Assert-That 'measuredAt is UTC' $isUtc "measuredAt=$rawMeasuredAt offset=$($parsedAt.Offset)"
        }

        $scannedRules = @(Get-ExpectedAlwaysOnRules)
        $claudeExpected = @($scannedRules + 'adapters/claude/CLAUDE.md')
        $cursorExpected = @($scannedRules)
        $codexExpected = @('adapters/codex/AGENTS.md')

        function Get-HostFiles {
            param($HostRow)
            return @($HostRow.files | ForEach-Object { $_ -replace '\\', '/' })
        }

        function Test-FileSet {
            param([string]$HostName, [string[]]$Actual, [string[]]$Expected)
            $actualSorted = @($Actual | Sort-Object)
            $expectedSorted = @($Expected | Sort-Object)
            $sameCount = $actualSorted.Count -eq $expectedSorted.Count
            $sameItems = $true
            if ($sameCount) {
                for ($i = 0; $i -lt $expectedSorted.Count; $i++) {
                    if ($actualSorted[$i] -ne $expectedSorted[$i]) { $sameItems = $false; break }
                }
            }
            else {
                $sameItems = $false
            }
            Assert-That "$HostName files match the scanned expected set" ($sameCount -and $sameItems) `
                "actual=$($actualSorted -join ', ') expected=$($expectedSorted -join ', ')"
        }

        Test-FileSet -HostName 'claude' -Actual (Get-HostFiles $evidence.hosts.claude) -Expected $claudeExpected
        Test-FileSet -HostName 'codex' -Actual (Get-HostFiles $evidence.hosts.codex) -Expected $codexExpected
        Test-FileSet -HostName 'cursor' -Actual (Get-HostFiles $evidence.hosts.cursor) -Expected $cursorExpected
    }

    Write-Host ''
    Write-Host 'Context floor — baseline ratchet'

    Assert-That 'committed baseline exists' (Test-Path -LiteralPath $committedBaseline)
    $baselineBefore = $null
    if (Test-Path -LiteralPath $committedBaseline) {
        $baselineBefore = [System.IO.File]::ReadAllBytes($committedBaseline)
    }

    $baselineRun = Invoke-Reporter -ReporterArgs @('-Baseline')
    Assert-That '-Baseline exits 0 against the committed baseline' ($baselineRun.ExitCode -eq 0) "exit $($baselineRun.ExitCode)`n$($baselineRun.Output)"

    $tempBaseline = Join-Path ([System.IO.Path]::GetTempPath()) ('context-floor-baseline-test-' + [guid]::NewGuid().ToString('N') + '.json')
    $temporaryFiles.Add($tempBaseline)
    Copy-Item -LiteralPath $committedBaseline -Destination $tempBaseline -Force

    $tempObj = Get-Content -LiteralPath $tempBaseline -Raw -Encoding utf8 | ConvertFrom-Json
    $originalClaude = [int]$tempObj.hosts.claude.bytes
    $lowered = [Math]::Max(0, $originalClaude - 1)
    $tempObj.hosts.claude.bytes = $lowered
    $tempJson = $tempObj | ConvertTo-Json -Depth 6
    [System.IO.File]::WriteAllText($tempBaseline, ($tempJson.TrimEnd() + "`n"), [System.Text.UTF8Encoding]::new($false))

    $loweredRun = Invoke-Reporter -ReporterArgs @('-Baseline', '-BaselinePath', $tempBaseline)
    Assert-That '-Baseline exits 1 when a host baseline is artificially lowered' ($loweredRun.ExitCode -eq 1) "exit $($loweredRun.ExitCode)`n$($loweredRun.Output)"
    Assert-That 'regression output names the host that exceeded' ($loweredRun.Output -match 'claude') $loweredRun.Output
    Assert-That 'regression output includes current and baseline bytes' (
        $loweredRun.Output -match [string]$originalClaude -and $loweredRun.Output -match [string]$lowered
    ) $loweredRun.Output

    $baselineAfter = [System.IO.File]::ReadAllBytes($committedBaseline)
    $unchanged = $baselineBefore.Length -eq $baselineAfter.Length
    if ($unchanged) {
        for ($i = 0; $i -lt $baselineBefore.Length; $i++) {
            if ($baselineBefore[$i] -ne $baselineAfter[$i]) { $unchanged = $false; break }
        }
    }
    Assert-That 'committed baseline is never modified by tests' $unchanged
}
finally {
    foreach ($path in $temporaryFiles) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
    }
}

Write-Host ''
Write-Host "Checks: $checks  Failures: $failures"
if ($failures -gt 0) { exit 1 }
exit 0
