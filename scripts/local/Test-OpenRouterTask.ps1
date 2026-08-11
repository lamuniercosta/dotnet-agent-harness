#!/usr/bin/env pwsh
# Proves Invoke-OpenRouterTask.ps1 selects the documented default and can be
# safely dry-run without launching Junie or exposing a credential.

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$runner = Join-Path $PSScriptRoot 'Invoke-OpenRouterTask.ps1'
$checks = 0
$failures = 0

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

$previousKey = $env:OPENROUTER_API_KEY
try {
    # Placeholder only: -WhatIf stops before Junie is launched.
    $env:OPENROUTER_API_KEY = 'test-key-not-used'

    $default = & $runner -Task 'No-op test task' -WhatIf 6>&1 | Out-String
    Assert-That 'the default model is GLM 5.2' ($default -match 'Model:\s+z-ai/glm-5\.2') $default
    Assert-That 'the default deep tier maps to high effort' ($default -match 'Tier:\s+deep \(effort=high\)') $default
    Assert-That 'a dry run does not launch Junie' ($default -match 'Dry run: Junie will not be launched\.') $default

    $override = & $runner -Task 'No-op test task' -Tier balanced -Model 'qwen/qwen3-coder' -WhatIf 6>&1 | Out-String
    Assert-That 'an explicit OpenRouter model overrides GLM 5.2' ($override -match 'Model:\s+qwen/qwen3-coder') $override
    Assert-That 'the balanced tier maps to medium effort' ($override -match 'Tier:\s+balanced \(effort=medium\)') $override
}
finally {
    if ($null -eq $previousKey) {
        Remove-Item Env:OPENROUTER_API_KEY -ErrorAction SilentlyContinue
    }
    else {
        $env:OPENROUTER_API_KEY = $previousKey
    }
}

Write-Host ''
Write-Host "Checks: $checks  Failures: $failures"
if ($failures -gt 0) { exit 1 }
exit 0
