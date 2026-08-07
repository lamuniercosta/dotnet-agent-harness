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
Assert-Throws 'legacy scalar agent tier' "agents:`n  tiers:`n    fast:`n      claude: inherit"

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

$tiers = ConvertFrom-HarnessYaml -Lines (
    "agents:`n  tiers:`n    fast:`n      codex:`n        model: gpt-5.6-terra`n        effort: low" -split "`n"
) -Path 'test.yml'
Assert-Equal 'nested agent model'  'gpt-5.6-terra' $tiers['agents.tiers.fast.codex.model']
Assert-Equal 'nested agent effort' 'low'           $tiers['agents.tiers.fast.codex.effort']

$defaults = Get-HarnessDefaults
Assert-Equal 'fast Claude default model'  'claude-haiku-4-5-20251001' $defaults['agents.tiers.fast.claude.model']
Assert-Equal 'fast Cursor default model'  'gpt-5.6-luna'               $defaults['agents.tiers.fast.cursor.model']
Assert-Equal 'fast Codex default model'   'gpt-5.6-terra'              $defaults['agents.tiers.fast.codex.model']
Assert-Equal 'balanced model inherits'    'inherit'                    $defaults['agents.tiers.balanced.codex.model']

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
