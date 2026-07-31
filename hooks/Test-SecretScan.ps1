#!/usr/bin/env pwsh
<#
  Self-test for secret-scan.ps1.

  A scanner that silently matches nothing looks exactly like a clean codebase.
  The guard hook's suite found three bugs in its own implementation, including
  a reserved-variable collision that made every check pass vacuously - so this
  one asserts both directions too: it must fire on credential shapes, and it
  must stay quiet on the things that look like them.

  The false-positive half matters as much as the true-positive half. This hook
  runs on every prompt and every file read; noise gets it switched off.

    pwsh ./hooks/Test-SecretScan.ps1
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$hook = Join-Path $PSScriptRoot 'secret-scan.ps1'
$failures = 0
$checks = 0

function Invoke-Scan {
    param([string]$Json)
    $Json | & pwsh -NoProfile -File $hook 2>&1 | Out-Null
    return $LASTEXITCODE
}

function Prompt-Payload {
    param([string]$Text)
    return (@{ prompt = $Text } | ConvertTo-Json -Compress -Depth 5)
}

function Assert-Flags {
    param([string]$Name, [string]$Text)
    $script:checks++
    if ((Invoke-Scan (Prompt-Payload $Text)) -eq 2) { Write-Host "  ok       flagged: $Name" }
    else { Write-Host "  FAIL     missed:  $Name" -ForegroundColor Red; $script:failures++ }
}

function Assert-Quiet {
    param([string]$Name, [string]$Text)
    $script:checks++
    if ((Invoke-Scan (Prompt-Payload $Text)) -eq 0) { Write-Host "  ok       quiet:   $Name" }
    else { Write-Host "  FAIL     false positive: $Name" -ForegroundColor Red; $script:failures++ }
}

# Every credential shape below is ASSEMBLED AT RUNTIME rather than written as a
# literal.
#
# GitHub push protection rejected the first version of this file: the Slack and
# Stripe fixtures were realistic enough that GitHub's own scanner flagged them.
# It was right to - a literal `xoxb-...` in a repository is indistinguishable
# from a live one, whoever wrote it and for whatever reason.
#
# The alternative was clicking "allow this secret", which trains exactly the
# reflex this hook exists to prevent. Splitting the prefix from the body means
# no credential-shaped literal exists in the source, while the string the
# scanner actually receives is identical.
$p = @{
    aws      = 'AKIA' + 'IOSFODNN7EXAMPLE'
    ghToken  = 'ghp' + '_' + 'aBcDeFgHiJkLmNoPqRsTuVwXyZ0123456'
    slack    = 'xox' + 'b-1234567890-abcdefghijklmnop'
    google   = 'AIza' + 'SyA1234567890abcdefghijklmnopqrstuv'
    stripe   = 'sk' + '_live_' + 'abcdefghijklmnopqrstuvwx'
    youtrack = 'perm' + ':YWRtaW4=.NDItMQ==.abcdefghijklmnop'
    mapbox   = 'sk' + '.eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9abcdef'
    jwt      = 'eyJhbGciOiJIUzI1NiJ9' + '.eyJzdWIiOiIxMjM0NTY3ODkwIn0' + '.dozjgNryP4J3jVmNHl0w5N-XgL0n3I9PlFUP0THsR8U'
}

Write-Host 'Credential shapes are flagged:'
Assert-Flags 'AWS access key'      "aws_access_key_id = $($p.aws)"
Assert-Flags 'private key block'   "-----BEGIN RSA PRIVATE KEY-----`nMIIEow..."
Assert-Flags 'GitHub token'        "GH_TOKEN=$($p.ghToken)"
Assert-Flags 'Slack token'         $p.slack
Assert-Flags 'Google API key'      "key: $($p.google)"
Assert-Flags 'Stripe secret key'   $p.stripe
Assert-Flags 'YouTrack perm token' "YOUTRACK_TOKEN=$($p.youtrack)"
Assert-Flags 'Mapbox secret token' "mapbox: $($p.mapbox)"
Assert-Flags 'JWT'                 "Authorization: Bearer $($p.jwt)"
Assert-Flags 'connection password' 'Server=db;Database=app;User Id=sa;Password=hunter2hunter2;'
Assert-Flags 'assigned api key'    'const apiKey = "abcdef1234567890abcdef1234567890"'

Write-Host ''
Write-Host 'Look-alikes stay quiet:'
Assert-Quiet 'prose about secrets'   'Never commit an api key or token to source control.'
Assert-Quiet 'placeholder'           'apiKey = "REPLACE_ME"'
Assert-Quiet 'env var reference'     'apiKey = Environment.GetEnvironmentVariable("API_KEY")'
Assert-Quiet 'config key name only'  'Add the ApiKey setting to appsettings.json'
Assert-Quiet 'git sha'               'Vendored at upstream commit 4f2e1a9c8b7d6e5f4a3b2c1d0e9f8a7b6c5d4e3f'
Assert-Quiet 'short assignment'      'var token = "abc123"'
Assert-Quiet 'ordinary code'         'public static decimal Clamp(decimal value) => Math.Clamp(value, 0m, 100m);'
Assert-Quiet 'empty payload'         ''

Write-Host ''
Write-Host 'Malformed input never wedges the session:'
$checks++
if ((Invoke-Scan 'not json at all') -eq 0) { Write-Host '  ok       quiet:   unparseable payload' }
else { Write-Host '  FAIL     unparseable payload did not exit 0' -ForegroundColor Red; $failures++ }

Write-Host ''
if ($failures -gt 0) {
    Write-Host "$failures of $checks checks FAILED." -ForegroundColor Red
    exit 1
}
Write-Host "All $checks checks passed." -ForegroundColor Green
exit 0
