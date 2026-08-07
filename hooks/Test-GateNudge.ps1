#!/usr/bin/env pwsh
# Focused self-test for the opt-in Codex PostToolUse contract.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$hook = Join-Path $PSScriptRoot 'gate-nudge.ps1'
$payload = @{
    cwd = $PSScriptRoot
    tool_name = 'apply_patch'
    tool_input = @{ command = "*** Begin Patch`n*** Update File: Program.cs`n*** End Patch" }
} | ConvertTo-Json -Compress -Depth 5

# Keep the test's throttle stamp isolated from a real session.
$testTemp = Join-Path ([System.IO.Path]::GetTempPath()) ("gate-nudge-test-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testTemp | Out-Null
try {
    $oldTemp = $env:TEMP
    $env:TEMP = $testTemp
    $output = $payload | & pwsh -NoProfile -File $hook -OutputContract Codex 2>&1
    $exitCode = $LASTEXITCODE
    try { $json = ($output -join "`n") | ConvertFrom-Json -ErrorAction Stop } catch { $json = $null }

    if ($exitCode -ne 0 -or -not $json -or
        $json.hookSpecificOutput.hookEventName -ne 'PostToolUse' -or
        -not $json.systemMessage -or
        -not $json.hookSpecificOutput.additionalContext -or
        ($json.PSObject.Properties.Name -contains 'decision')) {
        throw 'Codex PostToolUse contract did not produce nonblocking nudge JSON.'
    }
    Write-Host 'Codex apply_patch nudge contract passed.' -ForegroundColor Green
} finally {
    $env:TEMP = $oldTemp
    Remove-Item -LiteralPath $testTemp -Recurse -Force -ErrorAction SilentlyContinue
}
