#!/usr/bin/env pwsh
<#
  Asserts that every threshold quoted in prose agrees with harness.yml.example.

  Thresholds live in exactly one place. Prose may still quote the number - "≤ 6"
  reads better than "≤ gates.complexity.refactor" - but only alongside its key,
  and only if the number is right. Documentation quoting a stale threshold is how
  a team ends up believing the bar is 6 while the gate enforces 10.

  Values are read through the harness's own parser rather than grepped, so this
  cannot drift from how the config is actually interpreted.

    pwsh ./packs/dotnet/scripts/Test-ThresholdDocs.ps1
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '_gate-common.ps1')

# scripts -> dotnet -> packs -> repo root
$repoRoot = Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
$example = Join-Path $repoRoot 'harness.yml.example'

$config = ConvertFrom-HarnessYaml -Lines (Get-Content -LiteralPath $example) -Path 'harness.yml.example'

$watched = @{
    'gates.complexity.implement' = $config['gates.complexity.implement']
    'gates.complexity.refactor'  = $config['gates.complexity.refactor']
    'gates.mutation.threshold'   = $config['gates.mutation.threshold']
}

Write-Host 'harness.yml.example:'
foreach ($k in ($watched.Keys | Sort-Object)) { Write-Host ("  {0,-30} {1}" -f $k, $watched[$k]) }
Write-Host ''

$searchRoots = @('skills', 'rules', '.claude/agents') |
    ForEach-Object { Join-Path $repoRoot $_ } |
    Where-Object { Test-Path $_ }

$files = Get-ChildItem -Path $searchRoots -Recurse -Include '*.md', '*.mdc' -File
$failures = 0

# 1. A documented default must match the example.
foreach ($file in $files) {
    $lineNo = 0
    foreach ($line in (Get-Content -LiteralPath $file.FullName)) {
        $lineNo++
        foreach ($key in $watched.Keys) {
            # Match the default that FOLLOWS this key, not the first on the line.
            # One sentence often names both complexity keys with both defaults
            # ("implement (default 15) ... refactor (default 6)"), and taking the
            # first match reported a mismatch on correct prose.
            $pattern = [regex]::Escape($key) + '[^\r\n]{0,80}?default\s+\*{0,2}(\d+)'
            if ($line -notmatch $pattern) { continue }

            $documented = [int]$Matches[1]
            if ($documented -ne $watched[$key]) {
                $rel = $file.FullName.Substring($repoRoot.Length + 1)
                Write-Host "  FAIL  ${rel}:${lineNo}" -ForegroundColor Red
                Write-Host "        $key documented as $documented, example says $($watched[$key])" -ForegroundColor Red
                $failures++
            }
        }
    }
}

# 2. A threshold number must never appear without its key on the same line.
#    Scoped to comparison operators against the exact values in play, so prose
#    like "bullets, <=6 words" is not a false positive.
$bare = '(?<![\w.])(≤|<=)\s*(6|15)(?![\w%])|(≥|>=)\s*80\s*%'

foreach ($file in $files) {
    $lineNo = 0
    foreach ($line in (Get-Content -LiteralPath $file.FullName)) {
        $lineNo++
        if ($line -notmatch $bare) { continue }
        if ($line -match 'harness\.yml' -or $line -match 'gates\.') { continue }
        if ($line -match '\bwords?\b|\bchars?\b|\bitems?\b|\bbullets?\b') { continue }

        $rel = $file.FullName.Substring($repoRoot.Length + 1)
        Write-Host "  FAIL  ${rel}:${lineNo}" -ForegroundColor Red
        Write-Host "        threshold quoted without its harness.yml key: $($line.Trim())" -ForegroundColor Red
        $failures++
    }
}

Write-Host ''
if ($failures -gt 0) {
    Write-Host "$failures threshold reference(s) out of sync." -ForegroundColor Red
    Write-Host 'Quote a threshold as: `<= 6 (gates.complexity.refactor in harness.yml, default 6)`'
    exit 1
}

Write-Host "All quoted thresholds agree with harness.yml.example." -ForegroundColor Green
exit 0
