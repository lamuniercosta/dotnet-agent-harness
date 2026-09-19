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
    param([string]$Json, [string]$OutputContract = 'Legacy')
    $output = $Json | & pwsh -NoProfile -File $hook -OutputContract $OutputContract 2>&1
    return @{ ExitCode = $LASTEXITCODE; Output = ($output -join "`n") }
}

function Prompt-Payload {
    param([string]$Text)
    return (@{ prompt = $Text } | ConvertTo-Json -Compress -Depth 5)
}

function File-Payload {
    param([string]$Path)
    return (@{ tool_input = @{ file_path = $Path } } | ConvertTo-Json -Compress -Depth 5)
}

function Assert-Flags {
    param([string]$Name, [string]$Text)
    $script:checks++
    if ((Invoke-Scan (Prompt-Payload $Text)).ExitCode -eq 2) { Write-Host "  ok       flagged: $Name" }
    else { Write-Host "  FAIL     missed:  $Name" -ForegroundColor Red; $script:failures++ }
}

function Assert-Quiet {
    param([string]$Name, [string]$Text)
    $script:checks++
    if ((Invoke-Scan (Prompt-Payload $Text)).ExitCode -eq 0) { Write-Host "  ok       quiet:   $Name" }
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
    openrouter = 'sk-or-v1-' + ('A' * 40)
    openai     = 'sk-proj-' + ('B' * 40)
    anthropic  = 'sk-ant-api03-' + ('C' * 40)
    stripe   = 'sk' + '_live_' + 'abcdefghijklmnopqrstuvwx'
    youtrack = 'perm' + ':YWRtaW4=.NDItMQ==.abcdefghijklmnop'
    mapbox   = 'sk' + '.eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9abcdef'
    azureAccountKey = ('Zm9v' * 12)
    bearerOpaque    = ('Z' * 48)
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
Assert-Flags 'OpenRouter key (bare)' $p.openrouter
Assert-Flags 'OpenRouter key (assigned)' "apiKey = '$($p.openrouter)'"
Assert-Flags 'OpenAI key (bare)' $p.openai
Assert-Flags 'OpenAI key (assigned)' "api_key = '$($p.openai)'"
Assert-Flags 'Anthropic key (bare)' $p.anthropic
Assert-Flags 'Anthropic key (assigned)' "secret = '$($p.anthropic)'"
Assert-Flags 'Azure AccountKey (bare)' "AccountKey=$($p.azureAccountKey)"
Assert-Flags 'Azure AccountKey (assigned)' "connectionString = 'DefaultEndpointsProtocol=https;AccountName=x;AccountKey=$($p.azureAccountKey);EndpointSuffix=core.windows.net'"
Assert-Flags 'Generic Bearer token (bare)' "Authorization: Bearer $($p.bearerOpaque)"
Assert-Flags 'Generic Bearer token (assigned)' "authHeader = 'Bearer $($p.bearerOpaque)'"
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
Assert-Quiet 'OpenRouter short token'  'sk-or-v1-ABC123'
Assert-Quiet 'OpenAI short token'     'sk-proj-abc123'
Assert-Quiet 'Anthropic short token'  'sk-ant-api03-abc123'
Assert-Quiet 'Azure short AccountKey' 'AccountKey=abc123'
Assert-Quiet 'Bearer short token'     'Authorization: Bearer abc123'
Assert-Quiet 'ordinary code'         'public static decimal Clamp(decimal value) => Math.Clamp(value, 0m, 100m);'
Assert-Quiet 'empty payload'         ''

Write-Host ''
Write-Host 'File-read path scans file content:'
$readTemp = Join-Path ([System.IO.Path]::GetTempPath()) ('secret-scan-read-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $readTemp | Out-Null
try {
    $permToken = 'perm:test-' + ('x' * 20)
    $flagFile = Join-Path $readTemp 'flagged.txt'
    $quietFile = Join-Path $readTemp 'quiet.txt'
    $largeFile = Join-Path $readTemp 'large.txt'
    Set-Content -LiteralPath $flagFile -Value "token = $permToken"
    Set-Content -LiteralPath $quietFile -Value 'ordinary file content'
    # Must exceed the 512KB threshold so the hook intentionally skips the
    # read path while still writing a stderr diagnostic.
    Set-Content -LiteralPath $largeFile -Value ('x' * (600KB)) -Encoding UTF8

    $checks++
    if ((Invoke-Scan (File-Payload $flagFile)).ExitCode -eq 2) { Write-Host '  ok       flagged: file-read perm token' }
    else { Write-Host '  FAIL     missed:  file-read perm token' -ForegroundColor Red; $failures++ }

    $checks++
    if ((Invoke-Scan (File-Payload $quietFile)).ExitCode -eq 0) { Write-Host '  ok       quiet:   ordinary file' }
    else { Write-Host '  FAIL     false positive: ordinary file' -ForegroundColor Red; $failures++ }

    $checks++
    $largeLegacy = Invoke-Scan (File-Payload $largeFile)
    if ($largeLegacy.ExitCode -eq 0 -and
        $largeLegacy.Output -match 'secret-scan: skipped large file read') {
        Write-Host '  ok       skipped: large file uses stderr diagnostic and allows'
    } else {
        Write-Host '  FAIL     missed: large-file skip diagnostic contract' -ForegroundColor Red; $failures++
    }

    $checks++
    $largeCursor = Invoke-Scan (File-Payload $largeFile) 'CursorPrompt'
    $jsonLine = ($largeCursor.Output -split "`r?`n" | Where-Object { $_.TrimStart().StartsWith('{') } | Select-Object -First 1)
    try { $cursorJson = $jsonLine | ConvertFrom-Json -ErrorAction Stop } catch { $cursorJson = $null }
    if ($largeCursor.ExitCode -eq 0 -and
        $largeCursor.Output -match 'secret-scan: skipped large file read' -and
        $cursorJson -and $cursorJson.continue -eq $true) {
        Write-Host '  ok       CursorPrompt still outputs valid JSON on large-file skip'
    } else {
        Write-Host '  FAIL     CursorPrompt JSON contract on large-file skip' -ForegroundColor Red; $failures++
    }

    $checks++
    $largeCursorRead = Invoke-Scan (File-Payload $largeFile) 'CursorReadFile'
    $jsonLine = ($largeCursorRead.Output -split "`r?`n" | Where-Object { $_.TrimStart().StartsWith('{') } | Select-Object -First 1)
    try { $cursorReadJson = $jsonLine | ConvertFrom-Json -ErrorAction Stop } catch { $cursorReadJson = $null }
    if ($largeCursorRead.ExitCode -eq 0 -and
        $largeCursorRead.Output -match 'secret-scan: skipped large file read' -and
        $cursorReadJson -and $cursorReadJson.permission -eq 'allow') {
        Write-Host '  ok       CursorReadFile still outputs valid JSON on large-file skip'
    } else {
        Write-Host '  FAIL     CursorReadFile JSON contract on large-file skip' -ForegroundColor Red; $failures++
    }

    $checks++
    $claudeFinding = Invoke-Scan (File-Payload $flagFile) 'ClaudePreTool'
    try { $claudeJson = $claudeFinding.Output | ConvertFrom-Json -ErrorAction Stop } catch { $claudeJson = $null }
    if ($claudeFinding.ExitCode -eq 0 -and
        $claudeFinding.Output -match 'secret-scan: possible credential' -and
        -not $claudeJson) {
        Write-Host '  ok       ClaudePreTool file-read finding warns and allows'
    } else {
        Write-Host '  FAIL     ClaudePreTool file-read finding contract' -ForegroundColor Red; $failures++
    }

    $checks++
    $claudeClean = Invoke-Scan (File-Payload $quietFile) 'ClaudePreTool'
    if ($claudeClean.ExitCode -eq 0 -and $claudeClean.Output -notmatch 'secret-scan') {
        Write-Host '  ok       ClaudePreTool clean file stays quiet'
    } else {
        Write-Host '  FAIL     ClaudePreTool clean file should not warn' -ForegroundColor Red; $failures++
    }
} finally {
    Remove-Item -LiteralPath $readTemp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host 'Malformed input never wedges the session:'
$checks++
if ((Invoke-Scan 'not json at all').ExitCode -eq 0) { Write-Host '  ok       quiet:   unparseable payload' }
else { Write-Host '  FAIL     unparseable payload did not exit 0' -ForegroundColor Red; $failures++ }

Write-Host ''
Write-Host 'Redaction holds across output contracts:'
$secret = $p.ghToken

function Extract-JsonLine {
    param([string]$Text)
    return ($Text -split "`r?`n" |
        Where-Object { $_.TrimStart().StartsWith('{') } |
        Select-Object -First 1)
}

$cases = @(
    @{ Contract = 'Legacy';         ExpectedExit = 2; Kind = 'text' },
    @{ Contract = 'ClaudePreTool'; ExpectedExit = 0; Kind = 'text' },
    @{ Contract = 'Codex';          ExpectedExit = 0; Kind = 'codex' },
    @{ Contract = 'CursorPrompt';  ExpectedExit = 0; Kind = 'cursorPrompt' },
    @{ Contract = 'CursorReadFile'; ExpectedExit = 0; Kind = 'cursorReadFile' }
)

foreach ($case in $cases) {
    $checks++
    $contract = $case.Contract
    $expected = $case.ExpectedExit
    $kind = $case.Kind

    $result = Invoke-Scan (Prompt-Payload "GH_TOKEN=$secret") $contract
    $nonLeak = $result.Output -notmatch [regex]::Escape($secret)

    if ($result.ExitCode -ne $expected -or -not $nonLeak) {
        Write-Host "  FAIL     $contract exit-code/redaction contract" -ForegroundColor Red
        $failures++
        continue
    }

    switch ($kind) {
        'text' {
            if ($result.Output -match 'secret-scan: possible credential') {
                Write-Host "  ok       $contract warns and stays redacted"
            } else {
                Write-Host "  FAIL     $contract missing advisory wording" -ForegroundColor Red
                $failures++
            }
        }
        'codex' {
            try { $json = (Extract-JsonLine $result.Output) | ConvertFrom-Json -ErrorAction Stop } catch { $json = $null }
            if ($json -and
                $json.hookSpecificOutput.hookEventName -eq 'UserPromptSubmit' -and
                $json.systemMessage -and
                $json.hookSpecificOutput.additionalContext -and
                -not ($json.PSObject.Properties.Name -contains 'decision')) {
                Write-Host '  ok       Codex warning JSON is nonblocking and redacted'
            } else {
                Write-Host '  FAIL     Codex warning JSON contract' -ForegroundColor Red
                $failures++
            }
        }
        'cursorPrompt' {
            try { $json = (Extract-JsonLine $result.Output) | ConvertFrom-Json -ErrorAction Stop } catch { $json = $null }
            if ($json -and $json.continue -eq $true -and $json.user_message) {
                Write-Host '  ok       CursorPrompt JSON contract is valid and redacted'
            } else {
                Write-Host '  FAIL     CursorPrompt JSON contract' -ForegroundColor Red
                $failures++
            }
        }
        'cursorReadFile' {
            try { $json = (Extract-JsonLine $result.Output) | ConvertFrom-Json -ErrorAction Stop } catch { $json = $null }
            if ($json -and $json.permission -eq 'allow' -and $json.user_message) {
                Write-Host '  ok       CursorReadFile JSON contract is valid and redacted'
            } else {
                Write-Host '  FAIL     CursorReadFile JSON contract' -ForegroundColor Red
                $failures++
            }
        }
    }
}

Write-Host ''
if ($failures -gt 0) {
    Write-Host "$failures of $checks checks FAILED." -ForegroundColor Red
    exit 1
}
Write-Host "All $checks checks passed." -ForegroundColor Green
exit 0
