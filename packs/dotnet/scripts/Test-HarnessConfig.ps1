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
# The map prefix widens the key grammar for its direct children only. Every
# near miss stays an unknown key, so a typo cannot silently collect entries of
# its own and revert the exclusion the repo thought it had.
Assert-Throws 'near-miss map key (singular)' "gates:`n  mutation:`n    exclusion:`n      Contoso.Api: reason"
Assert-Throws 'near-miss map key (plural segment)' "gates:`n  mutations:`n    exclusions:`n      Contoso.Api: reason"
Assert-Throws 'map entry nested below an entry' "gates:`n  mutation:`n    exclusions:`n      Contoso.Api:`n        reason: stated below"
Assert-Throws 'map entry without a reason' "gates:`n  mutation:`n    exclusions:`n      Contoso.Api:`n      Contoso.Web: reason"
Assert-Throws 'map entry reason of null' "gates:`n  mutation:`n    exclusions:`n      Contoso.Api: null"
Assert-Throws 'scalar on the map key' "gates:`n  mutation:`n    exclusions: Contoso.Api"
Assert-Throws 'dotted key outside the map prefix' "gates:`n  mutation:`n    threshold: 80`n    extra.thing: 1"
try {
    Assert-HarnessTracker -Tracker 'jira'
    Write-Host "  FAIL  unsupported tracker - expected an error, got none" -ForegroundColor Red
    $script:failures++
} catch {
    Write-Host "  ok    unsupported tracker -> $_"
}

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

$map = ConvertFrom-HarnessYaml -Lines (
    "gates:`n  mutation:`n    threshold: 80`n    exclusions:`n      Contoso.Api: host proof lives elsewhere`n      Contoso.Infrastructure.cs: `"persistence proof lives elsewhere`"" -split "`n"
) -Path 'test.yml'
Assert-Equal 'map entry reason'        'host proof lives elsewhere'         $map['gates.mutation.exclusions.Contoso.Api']
Assert-Equal 'quoted map entry reason' 'persistence proof lives elsewhere'  $map['gates.mutation.exclusions.Contoso.Infrastructure.cs']
Assert-Equal 'map key is not itself stored' $false $map.ContainsKey('gates.mutation.exclusions')
Assert-Equal 'map leaves other keys alone'  80      $map['gates.mutation.threshold']

$defaults = Get-HarnessDefaults
Assert-Equal 'fast Claude default model'  'claude-haiku-4-5-20251001' $defaults['agents.tiers.fast.claude.model']
Assert-Equal 'fast Cursor default model'  'gpt-5.6-luna'               $defaults['agents.tiers.fast.cursor.model']
Assert-Equal 'fast Codex default model'   'gpt-5.6-terra'              $defaults['agents.tiers.fast.codex.model']
Assert-Equal 'balanced model inherits'    'inherit'                    $defaults['agents.tiers.balanced.codex.model']
Assert-Equal 'maxKillShare default'      50                           $defaults['gates.mutation.maxKillShare']
Assert-Equal 'maxKillFileSpan default'   15                           $defaults['gates.mutation.maxKillFileSpan']
Assert-Equal 'concurrency default unset' $null                        $defaults['gates.mutation.concurrency']
Assert-Equal 'runner default unset'      $null                        $defaults['gates.mutation.runner']

Write-Host ''
Write-Host 'Reads the loaded map through Get-HarnessMap:'
# Each case gets its own root: Get-HarnessConfig caches per repo root, and a
# rewritten harness.yml in the same root would be served from that cache. Every
# scratch root declares baseBranch, so loading it needs no git repository.
$scratchRoots = [System.Collections.Generic.List[string]]::new()
function New-ScratchHarnessRoot {
    param([string[]]$Lines)
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("harness-config-map-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $script:scratchRoots.Add($root)
    [System.IO.File]::WriteAllText((Join-Path $root 'harness.yml'), (($Lines -join "`n") + "`n"))
    return $root
}

try {
    $scratch = New-ScratchHarnessRoot -Lines @(
        'baseBranch: main',
        'gates:',
        '  mutation:',
        '    exclusions:',
        '      Contoso.Web: host proof lives elsewhere',
        '      Contoso.Api: "the API is proven through Contoso.Web"'
    )

    $entries = @(Get-HarnessMap -Key 'gates.mutation.exclusions' -RepoRoot $scratch)
    Assert-Equal 'map entry count'         2              $entries.Count
    Assert-Equal 'map entries are ordered' 'Contoso.Api'  $entries[0].Project
    Assert-Equal 'map entries carry reason' 'the API is proven through Contoso.Web' $entries[0].Reason

    # Get-HarnessValue is the wrong reader for a map: it must say so rather than
    # return the entry hashtable and let a caller misread it as a scalar.
    $script:checks++
    try {
        Get-HarnessValue -Key 'gates.mutation.exclusions' -RepoRoot $scratch | Out-Null
        Write-Host '  FAIL  Get-HarnessValue on a map key - expected an error, got none' -ForegroundColor Red
        $script:failures++
    }
    catch {
        Write-Host "  ok    Get-HarnessValue on a map key -> $($_.Exception.Message)"
    }

    foreach ($bad in @(
            @{ Name = 'a .csproj file name'; Line = '      Contoso.Api.csproj: reason' },
            @{ Name = 'a blank reason'; Line = '      Contoso.Api: "   "' })) {
        $badRoot = New-ScratchHarnessRoot -Lines @('baseBranch: main', 'gates:', '  mutation:', '    exclusions:', $bad.Line)
        $script:checks++
        try {
            Get-HarnessMap -Key 'gates.mutation.exclusions' -RepoRoot $badRoot | Out-Null
            Write-Host "  FAIL  map entry with $($bad.Name) - expected an error, got none" -ForegroundColor Red
            $script:failures++
        }
        catch {
            Write-Host "  ok    map entry with $($bad.Name) -> $($_.Exception.Message)"
        }
    }

    # An explicitly written null is the documented way to leave an optional
    # int or scalar unset, so it must load as unset rather than as a bad value.
    $nullRoot = New-ScratchHarnessRoot -Lines @(
        'baseBranch: main',
        'gates:',
        '  mutation:',
        '    concurrency: null',
        '    runner: null'
    )
    $nullConfig = Get-HarnessConfig -RepoRoot $nullRoot
    Assert-Equal 'explicit null int loads unset'    $null $nullConfig['gates.mutation.concurrency']
    Assert-Equal 'explicit null scalar loads unset' $null $nullConfig['gates.mutation.runner']
}
finally {
    foreach ($root in $scratchRoots) {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

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
    # A map key is never a key of the parsed result - only its entries are - so it is
    # covered when at least one child is documented.
    $missing = @($script:HarnessSchema.Keys | Where-Object {
            if ($script:HarnessSchema[$_] -eq 'map') {
                $prefix = "$_."
                -not @($example.Keys | Where-Object { $_.StartsWith($prefix, [System.StringComparison]::Ordinal) }).Count
            }
            else { -not $example.ContainsKey($_) }
        })
    Assert-Equal 'example covers every schema key' 0 $missing.Count
    if ($missing.Count -gt 0) {
        Write-Host "        missing: $($missing -join ', ')" -ForegroundColor Red
    }

    # A fresh install copies the example verbatim, so its stamp - not the VERSION
    # file - is what a brand-new consumer reports. If the two drift, the consumer
    # runs one version's behaviour while reporting another, and the next
    # same-version install reports a phantom upgrade. Pin them together here.
    $version = (Get-Content -LiteralPath (Join-Path $repoRoot 'VERSION') -Raw).Trim()
    Assert-Equal 'example harnessVersion matches the VERSION file' $version $example['harnessVersion']
}

Write-Host ''
if ($failures -gt 0) {
    Write-Host "$failures of $checks checks FAILED." -ForegroundColor Red
    exit 1
}
Write-Host "All $checks checks passed." -ForegroundColor Green
exit 0
