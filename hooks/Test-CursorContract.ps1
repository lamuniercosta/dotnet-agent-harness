#!/usr/bin/env pwsh
# Self-test for Cursor hook output contracts.
#
# Cursor requires valid JSON on stdout for successful hook paths, and treats
# exit 2 as a block at every event. These checks assert that the shared hook
# scripts keep their legacy defaults while Cursor wiring gets explicit JSON.
#
#   pwsh ./hooks/Test-CursorContract.ps1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$guard = Join-Path $PSScriptRoot 'guard.ps1'
$secretScan = Join-Path $PSScriptRoot 'secret-scan.ps1'
$gateNudge = Join-Path $PSScriptRoot 'gate-nudge.ps1'
$formatOnEdit = Join-Path $PSScriptRoot 'format-on-edit.ps1'
$failures = 0
$checks = 0

function Invoke-Hook {
    param([string]$Script, [string[]]$ScriptArgs, [string]$Json)
    $stdout = @($Json | & pwsh -NoProfile -File $Script @ScriptArgs 2>$null)
    return [PSCustomObject]@{
        ExitCode = $LASTEXITCODE
        StdOut   = ($stdout -join [Environment]::NewLine).Trim()
    }
}

function Convert-StdOutJson {
    param([string]$Text)
    try { return $Text | ConvertFrom-Json -ErrorAction Stop } catch { return $null }
}

function Assert-Json {
    param([string]$Name, [object]$Result, [scriptblock]$Predicate)
    $script:checks++
    $json = Convert-StdOutJson $Result.StdOut
    if (& $Predicate $Result $json) { Write-Host "  ok       $Name" }
    else { Write-Host "  FAIL     $Name" -ForegroundColor Red; $script:failures++ }
}

function Assert-Empty {
    param([string]$Name, [object]$Result, [int]$ExitCode)
    $script:checks++
    if ($Result.ExitCode -eq $ExitCode -and $Result.StdOut -eq '') { Write-Host "  ok       $Name" }
    else { Write-Host "  FAIL     $Name" -ForegroundColor Red; $script:failures++ }
}

function Assert-ExitCode {
    param([string]$Name, [object]$Result, [int]$ExitCode)
    $script:checks++
    if ($Result.ExitCode -eq $ExitCode) { Write-Host "  ok       $Name" }
    else { Write-Host "  FAIL     $Name" -ForegroundColor Red; $script:failures++ }
}

function Bash { param([string]$Cmd) (@{ tool_name = 'Bash'; tool_input = @{ command = $Cmd } } | ConvertTo-Json -Compress -Depth 5) }
function Edit { param([string]$Path) (@{ cwd = $PSScriptRoot; tool_name = 'Edit'; tool_input = @{ file_path = $Path } } | ConvertTo-Json -Compress -Depth 5) }
function Prompt-Payload { param([string]$Text) (@{ prompt = $Text } | ConvertTo-Json -Compress -Depth 5) }

$cursor = @('-OutputContract', 'Cursor')
$cursorPrompt = @('-OutputContract', 'CursorPrompt')
$cursorReadFile = @('-OutputContract', 'CursorReadFile')
$allowPayload = Bash 'dotnet build'
$destructive = 'rm' + ' -rf ' + '/'
$denyPayload = Bash $destructive
$fakeAwsKey = 'AKIA' + 'ABCDEFGHIJKLMNOP'

Write-Host 'guard.ps1 Cursor contract:'
Assert-Json 'allow emits permission allow' (Invoke-Hook $guard $cursor $allowPayload) {
    param($Result, $Json)
    $Result.ExitCode -eq 0 -and $Json -and $Json.permission -eq 'allow'
}
Assert-Json 'deny emits permission deny with messages' (Invoke-Hook $guard $cursor $denyPayload) {
    param($Result, $Json)
    $Result.ExitCode -eq 2 -and $Json -and $Json.permission -eq 'deny' -and
        -not [string]::IsNullOrWhiteSpace($Json.agent_message) -and
        -not [string]::IsNullOrWhiteSpace($Json.user_message)
}

Write-Host ''
Write-Host 'guard.ps1 Legacy default remains silent:'
Assert-Empty 'legacy allow stdout empty' (Invoke-Hook $guard @() $allowPayload) 0
Assert-Empty 'legacy deny stdout empty' (Invoke-Hook $guard @() $denyPayload) 2

Write-Host ''
Write-Host 'secret-scan.ps1 CursorPrompt contract:'
Assert-Json 'clean prompt continues' (Invoke-Hook $secretScan $cursorPrompt (Prompt-Payload 'ordinary prompt')) {
    param($Result, $Json)
    $continue = if ($Json) { $Json.PSObject.Properties['continue'].Value } else { $null }
    $Result.ExitCode -eq 0 -and $Json -and $continue -eq $true
}
Assert-Json 'credential-shaped prompt warns but continues' (Invoke-Hook $secretScan $cursorPrompt (Prompt-Payload "aws_access_key_id = $fakeAwsKey")) {
    param($Result, $Json)
    $continue = if ($Json) { $Json.PSObject.Properties['continue'].Value } else { $null }
    $Result.ExitCode -eq 0 -and $Json -and $continue -eq $true
}

Write-Host ''
Write-Host 'secret-scan.ps1 CursorReadFile contract:'
Assert-Json 'credential-shaped read warns but allows' (Invoke-Hook $secretScan $cursorReadFile (Prompt-Payload "aws_access_key_id = $fakeAwsKey")) {
    param($Result, $Json)
    $Result.ExitCode -eq 0 -and $Json -and $Json.permission -eq 'allow'
}

Write-Host ''
Write-Host 'secret-scan.ps1 Legacy default remains blocking:'
Assert-ExitCode 'legacy credential-shaped prompt exits 2' (Invoke-Hook $secretScan @() (Prompt-Payload "aws_access_key_id = $fakeAwsKey")) 2

Write-Host ''
Write-Host 'gate-nudge.ps1 Cursor contract:'
$testTemp = Join-Path ([System.IO.Path]::GetTempPath()) ("cursor-contract-gate-nudge-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testTemp | Out-Null
try {
    $oldTemp = $env:TEMP
    $env:TEMP = $testTemp
    Assert-Json 'C# edit exits 0 with valid JSON' (Invoke-Hook $gateNudge $cursor (Edit 'Program.cs')) {
        param($Result, $Json)
        $Result.ExitCode -eq 0 -and $Json
    }
} finally {
    $env:TEMP = $oldTemp
    Remove-Item -LiteralPath $testTemp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host 'format-on-edit.ps1 Cursor contract:'
Assert-Json 'edit exits 0 with valid JSON' (Invoke-Hook $formatOnEdit $cursor (Edit 'Program.cs')) {
    param($Result, $Json)
    $Result.ExitCode -eq 0 -and $Json
}

Write-Host ''
if ($failures -gt 0) {
    Write-Host "$failures of $checks checks FAILED." -ForegroundColor Red
    exit 1
}
Write-Host "All $checks checks passed." -ForegroundColor Green
exit 0
