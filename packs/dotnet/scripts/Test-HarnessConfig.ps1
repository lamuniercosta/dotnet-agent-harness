#!/usr/bin/env pwsh
# Self-test for the harness.yml subset parser.
#
# The parser is the single point where a mistyped threshold either fails loudly
# or silently reverts to a default - so it gets its own test rather than being
# trusted. Run directly, or from CI via lint-harness.yml.
#
#   pwsh ./packs/dotnet/scripts/Test-HarnessConfig.ps1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '_gate-common.ps1')

$failures = 0
$checks = 0

function Assert-Throws {
    param([string]$Name, [string]$Yaml)
    $script:checks++
    try {
        ConvertFrom-HarnessYaml -Lines ($Yaml -split "`n") -Path 'test.yml' | Out-Null
        Write-Host "  FAIL  $Name - expected an error, got none" -ForegroundColor Red
        $script:failures++
    }
    catch {
        $first = ($_.Exception.Message -split "`n")[0]
        Write-Host "  ok    $Name -> $first"
    }
}

function Assert-Equal {
    param([string]$Name, $Expected, $Actual)
    $script:checks++
    if ($Expected -eq $Actual) {
        Write-Host "  ok    $Name = $Actual"
    }
    else {
        Write-Host "  FAIL  $Name - expected '$Expected', got '$Actual'" -ForegroundColor Red
        $script:failures++
    }
}

Write-Host 'Rejects malformed input:'
Assert-Throws 'unknown key'      "gates:`n  mutation:`n    threshhold: 80"
Assert-Throws 'non-integer int'  "gates:`n  mutation:`n    threshold: eighty"
Assert-Throws 'non-boolean bool' "gates:`n  inspectCode:`n    enabled: yes"
Assert-Throws 'odd indent'       "gates:`n   mutation:`n     threshold: 80"
Assert-Throws 'list'             "gates:`n  - one"
Assert-Throws 'duplicate key'    "tracker: github`ntracker: none"
Assert-Throws 'tab indent'       "gates:`n`tmutation: x"
Assert-Throws 'garbage line'     "this is not yaml"

Write-Host ''
Write-Host 'Accepts valid input:'
$parsed = ConvertFrom-HarnessYaml -Lines (
    "# a comment`ntracker: none`ngates:`n  complexity:`n    implement: 20`n    refactor: 4`n  mutation:`n    threshold: 90" -split "`n"
) -Path 'test.yml'

Assert-Equal 'tracker'                    'none' $parsed['tracker']
Assert-Equal 'gates.complexity.implement' 20     $parsed['gates.complexity.implement']
Assert-Equal 'gates.complexity.refactor'  4      $parsed['gates.complexity.refactor']
Assert-Equal 'gates.mutation.threshold'   90     $parsed['gates.mutation.threshold']
Assert-Equal 'key count'                  4      $parsed.Count

Write-Host ''
Write-Host 'Parses the shipped example:'
# scripts -> dotnet -> packs -> repo root
$repoRoot = Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
$examplePath = Join-Path $repoRoot 'harness.yml.example'
if (-not (Test-Path $examplePath)) {
    Write-Host "  FAIL  harness.yml.example not found at $examplePath" -ForegroundColor Red
    $failures++
    $checks++
}
else {
    $example = ConvertFrom-HarnessYaml -Lines (Get-Content -LiteralPath $examplePath) -Path 'harness.yml.example'
    # Every documented key must be present, or the example has drifted from the schema.
    $missing = @($script:HarnessSchema.Keys | Where-Object { -not $example.ContainsKey($_) })
    Assert-Equal 'example covers every schema key' 0 $missing.Count
    if ($missing.Count -gt 0) {
        Write-Host "        missing: $($missing -join ', ')" -ForegroundColor Red
    }
}

Write-Host ''
if ($failures -gt 0) {
    Write-Host "$failures of $checks checks FAILED." -ForegroundColor Red
    exit 1
}
Write-Host "All $checks checks passed." -ForegroundColor Green
exit 0
