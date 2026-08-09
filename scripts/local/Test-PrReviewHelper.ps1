#!/usr/bin/env pwsh
# Self-test for skills/pr-review/scripts/pr-review.ps1.
#
# Guards the two defects that shipped in #86 and that no test caught:
#
#   1. `gh api --paginate` emits one JSON document per page, so any PR crossing a
#      page of files/commits/reviews/check-runs aborted resolve and post.
#   2. The posting receipt was keyed by head SHA, so a deliberate re-review of an
#      unchanged head exited as an idempotent no-op and published nothing.
#
# Unit checks dot-source the helper's top-level functions out of its AST (the
# script's own dispatch calls exit, so it cannot be dot-sourced directly).
# End-to-end checks run the real script against a fake `gh` on PATH.
#
#   pwsh ./scripts/local/Test-PrReviewHelper.ps1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$helper = Join-Path $repoRoot 'skills/pr-review/scripts/pr-review.ps1'
if (-not (Test-Path -LiteralPath $helper)) {
    throw "Helper not found: $helper"
}

$failures = 0
$checks = 0

function Assert-True {
    param([string]$Name, [bool]$Condition)
    $script:checks++
    if ($Condition) { Write-Host "  ok       $Name" }
    else { Write-Host "  FAIL     $Name" -ForegroundColor Red; $script:failures++ }
}

function Assert-Equal {
    param([string]$Name, $Expected, $Actual)
    $script:checks++
    if ($Expected -eq $Actual) { Write-Host "  ok       $Name" }
    else {
        Write-Host "  FAIL     $Name (expected=$Expected actual=$Actual)" -ForegroundColor Red
        $script:failures++
    }
}

# ---------------------------------------------------------------------------
# Load the helper's top-level functions without running its dispatch block.
# ---------------------------------------------------------------------------

$parseErrors = $null
$tokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($helper, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors -and $parseErrors.Count -gt 0) {
    throw "Helper does not parse: $($parseErrors[0].Message)"
}
foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    . ([scriptblock]::Create($fn.Extent.Text))
}

Write-Host ''
Write-Host 'pr-review helper: pagination, receipts, and workspace safety'
Write-Host ''
Write-Host 'Split-JsonDocuments'

# 1. The exact shape `gh api --paginate` produces: one document per page.
$twoPages = "[{`"filename`":`"a.cs`"}]`n[{`"filename`":`"b.cs`"}]"
$docs = @(Split-JsonDocuments -Text $twoPages)
Assert-Equal 'two concatenated pages split into two documents' 2 $docs.Count

# 2. Brackets and braces inside string values must not move the nesting depth —
#    a diff patch routinely contains `new[] { 1 }`.
$withBrackets = '[{"patch":"@@ -1,2 +1,3 @@\n var x = new[] { 1 };\n"}]'
$docs = @(Split-JsonDocuments -Text $withBrackets)
Assert-Equal 'brackets inside a string stay in one document' 1 $docs.Count
Assert-True 'that document round-trips' (($docs[0] | ConvertFrom-Json).patch -match 'new\[\] \{ 1 \}')

# 3. An escaped quote must not end the string early.
$withEscape = '[{"body":"he said \"]\" and left"}]'
$docs = @(Split-JsonDocuments -Text $withEscape)
Assert-Equal 'escaped quote does not terminate the string' 1 $docs.Count

# 4. Degenerate inputs.
Assert-Equal 'single document stays single' 1 @(Split-JsonDocuments -Text '[]').Count
Assert-Equal 'empty text yields no documents' 0 @(Split-JsonDocuments -Text '').Count

$threw = $false
try { [void](Split-JsonDocuments -Text '[{"a":1}') } catch { $threw = $true }
Assert-True 'truncated JSON is reported, not silently accepted' $threw

Write-Host ''
Write-Host 'Merge-CheckRunPages'

$page1 = '{"total_count":1,"check_runs":[{"name":"build"}]}' | ConvertFrom-Json
$page2 = '{"total_count":1,"check_runs":[{"name":"lint"}]}' | ConvertFrom-Json
$merged = Merge-CheckRunPages -Pages @($page1, $page2)
Assert-Equal 'check-run pages merge into one envelope' 2 @($merged.check_runs).Count
Assert-Equal 'merged total_count reflects every page' 2 $merged.total_count
Assert-Equal 'a page without check_runs is skipped, not fatal' 1 `
    @((Merge-CheckRunPages -Pages @($page1, ('{"message":"Not Found"}' | ConvertFrom-Json))).check_runs).Count

Write-Host ''
Write-Host 'Get-PostResultPath'

$ws = Join-Path ([System.IO.Path]::GetTempPath()) 'pr-review-receipt-shape'
Assert-True 'a run id keys the receipt' `
    ((Get-PostResultPath -Workspace $ws -RunId 'aaaa1111') -match 'post-result-aaaa1111\.json$')
Assert-True 'two runs get two receipts' `
    ((Get-PostResultPath -Workspace $ws -RunId 'aaaa1111') -ne (Get-PostResultPath -Workspace $ws -RunId 'bbbb2222'))
Assert-True 'a workspace without a run id keeps the legacy path' `
    ((Get-PostResultPath -Workspace $ws) -match 'post-result\.json$')

# ---------------------------------------------------------------------------
# End-to-end against a fake gh.
# ---------------------------------------------------------------------------

Write-Host ''
Write-Host 'End-to-end (-Resolve / -Post) against a fake gh'

$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ("pr-review-selftest-{0}" -f [guid]::NewGuid().ToString('n'))
$fixtures = Join-Path $sandbox 'fixtures'
$shimDir = Join-Path $sandbox 'bin'
$tempHome = Join-Path $sandbox 'temp'
New-Item -ItemType Directory -Path $fixtures -Force | Out-Null
New-Item -ItemType Directory -Path $shimDir -Force | Out-Null
New-Item -ItemType Directory -Path $tempHome -Force | Out-Null

$headSha = '2222222222222222222222222222222222222222'
$baseSha = '1111111111111111111111111111111111111111'

Set-Content -LiteralPath (Join-Path $fixtures 'pr.json') -Encoding UTF8 -Value @"
{"number":7,"title":"Test PR","html_url":"https://github.com/acme/widgets/pull/7",
 "base":{"sha":"$baseSha","ref":"main"},"head":{"sha":"$headSha","ref":"feature/x"}}
"@

# Two pages, one file each — plus brackets inside a patch string.
Set-Content -LiteralPath (Join-Path $fixtures 'files.json') -Encoding UTF8 -Value @'
[{"filename":"src/a.cs","status":"modified","patch":"@@ -1,2 +1,3 @@\n var x = new[] { 1 };\n+added\n"}]
[{"filename":"src/b.cs","status":"modified","patch":"@@ -1,2 +1,3 @@\n context\n+added\n"}]
'@

Set-Content -LiteralPath (Join-Path $fixtures 'commits.json') -Encoding UTF8 -Value @"
[{"sha":"$headSha","commit":{"message":"work"}}]
"@

Set-Content -LiteralPath (Join-Path $fixtures 'empty.json') -Encoding UTF8 -Value '[]'

Set-Content -LiteralPath (Join-Path $fixtures 'threads.json') -Encoding UTF8 -Value @'
{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}}
'@

Set-Content -LiteralPath (Join-Path $fixtures 'check-runs.json') -Encoding UTF8 -Value @'
{"total_count":1,"check_runs":[{"name":"build","conclusion":"success"}]}
{"total_count":1,"check_runs":[{"name":"lint","conclusion":"success"}]}
'@

Set-Content -LiteralPath (Join-Path $fixtures 'post-review.json') -Encoding UTF8 -Value '{"id":4242,"state":"COMMENTED"}'

$shimScript = Join-Path $shimDir 'gh-shim.ps1'
Set-Content -LiteralPath $shimScript -Encoding UTF8 -Value @'
[CmdletBinding(PositionalBinding = $false)]
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$CommandArgs)

$joined = ($CommandArgs -join ' ')
Add-Content -LiteralPath $env:PRREVIEW_TEST_LOG -Value $joined

function Emit([string]$Name) {
    Write-Output (Get-Content -LiteralPath (Join-Path $env:PRREVIEW_TEST_FIXTURES $Name) -Raw)
    exit 0
}

if ($joined -match '--method\s+POST' -and $joined -match 'pulls/7/reviews') { Emit 'post-review.json' }
if ($joined -match 'reviews/\d+/comments')                                 { Emit 'empty.json' }
if ($joined -match '^api graphql')                                         { Emit 'threads.json' }
if ($joined -match 'check-runs')                                           { Emit 'check-runs.json' }
if ($joined -match 'pulls/7/files')                                        { Emit 'files.json' }
if ($joined -match 'pulls/7/commits')                                      { Emit 'commits.json' }
if ($joined -match 'pulls/7/reviews')                                      { Emit 'empty.json' }
if ($joined -match 'pulls/7' -and $joined -match '\.head\.sha') {
    Write-Output $env:PRREVIEW_TEST_HEAD
    exit 0
}
if ($joined -match 'pulls/7')                                              { Emit 'pr.json' }

Write-Error "fake gh: unexpected arguments: $joined"
exit 1
'@

if ($IsWindows) {
    Set-Content -LiteralPath (Join-Path $shimDir 'gh.cmd') -Encoding Ascii -Value @(
        '@echo off'
        'pwsh -NoProfile -File "%~dp0gh-shim.ps1" %*'
        'exit /b %ERRORLEVEL%'
    )
}
else {
    $unixShim = Join-Path $shimDir 'gh'
    Set-Content -LiteralPath $unixShim -Encoding UTF8 -Value @(
        '#!/bin/sh'
        'exec pwsh -NoProfile -File "$(dirname "$0")/gh-shim.ps1" "$@"'
    )
    & chmod +x $unixShim
}

$ghLog = Join-Path $sandbox 'gh-calls.log'
Set-Content -LiteralPath $ghLog -Value '' -Encoding UTF8

function Invoke-Helper {
    param([string[]]$HelperArgs)

    $sep = [System.IO.Path]::PathSeparator
    $env:PATH = "$shimDir$sep$($script:originalPath)"
    $env:PRREVIEW_TEST_FIXTURES = $fixtures
    $env:PRREVIEW_TEST_LOG = $ghLog
    $env:PRREVIEW_TEST_HEAD = $headSha
    # Keep every workspace this test creates inside the sandbox.
    $env:TMPDIR = $tempHome
    $env:TEMP = $tempHome
    $env:TMP = $tempHome

    $out = & pwsh -NoProfile -File $helper @HelperArgs 2>&1 | Out-String
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Text = $out }
}

function Get-PostCount {
    return @(Get-Content -LiteralPath $ghLog | Where-Object { $_ -match '--method POST' }).Count
}

$script:originalPath = $env:PATH
$originalTmpdir = $env:TMPDIR
$originalTemp = $env:TEMP
$originalTmp = $env:TMP

try {
    $target = 'https://github.com/acme/widgets/pull/7'

    # ── Resolve: the multi-page fetch that used to abort ─────────────────────
    $resolve1 = Invoke-Helper -HelperArgs @('-Resolve', $target)
    Assert-Equal 'resolve succeeds against a multi-page PR' 0 $resolve1.ExitCode
    if ($resolve1.ExitCode -ne 0) { Write-Host $resolve1.Text -ForegroundColor DarkYellow }

    $workspace = $null
    if ($resolve1.Text -match '(?m)^workspace:\s*(.+)$') { $workspace = $Matches[1].Trim() }
    Assert-True 'resolve reports a workspace' (-not [string]::IsNullOrWhiteSpace($workspace))

    if ($workspace -and (Test-Path -LiteralPath $workspace)) {
        $changed = @(Get-Content -LiteralPath (Join-Path $workspace 'changed-files.json') -Raw | ConvertFrom-Json)
        Assert-Equal 'both pages of changed files survive pagination' 2 $changed.Count
        Assert-True 'a patch containing brackets round-trips intact' `
            (@($changed | Where-Object { $_.patch -match 'new\[\] \{ 1 \}' }).Count -eq 1)

        $ci = Get-Content -LiteralPath (Join-Path $workspace 'ci.json') -Raw | ConvertFrom-Json
        Assert-Equal 'both pages of check runs survive pagination' 2 @($ci.check_runs).Count

        $threadState = Get-Content -LiteralPath (Join-Path $workspace 'review-threads.json') -Raw | ConvertFrom-Json
        Assert-True 'thread coverage is recorded as complete' ([bool]$threadState.complete)

        $pinned1 = Get-Content -LiteralPath (Join-Path $workspace 'pinned.json') -Raw | ConvertFrom-Json
        Assert-True 'resolve mints a run id' (-not [string]::IsNullOrWhiteSpace([string]$pinned1.runId))

        # ── Post: first publish ──────────────────────────────────────────────
        $payloadPath = Join-Path $workspace 'review.input.json'
        Set-Content -LiteralPath $payloadPath -Encoding UTF8 -Value @"
{"commit_id":"$headSha","event":"COMMENT","body":"Summary for run one.","comments":[]}
"@
        $postsBefore = Get-PostCount
        $post1 = Invoke-Helper -HelperArgs @('-Post', '-Payload', $payloadPath)
        Assert-Equal 'first post succeeds' 0 $post1.ExitCode
        Assert-Equal 'first post reaches GitHub' ($postsBefore + 1) (Get-PostCount)
        Assert-True 'the receipt is keyed by run id' `
            (Test-Path -LiteralPath (Join-Path $workspace "post-result-$($pinned1.runId).json"))

        # ── Post again, same run: a retry must stay idempotent ───────────────
        $postsBefore = Get-PostCount
        $post2 = Invoke-Helper -HelperArgs @('-Post', '-Payload', $payloadPath)
        Assert-Equal 'retrying the same run succeeds' 0 $post2.ExitCode
        Assert-True 'retrying the same run is a no-op' ($post2.Text -match 'idempotent no-op')
        Assert-Equal 'retrying the same run posts nothing new' $postsBefore (Get-PostCount)

        # ── Re-review the same head: a new run must publish ──────────────────
        $resolve2 = Invoke-Helper -HelperArgs @('-Resolve', $target)
        Assert-Equal 'a second resolve on the same head succeeds' 0 $resolve2.ExitCode
        $pinned2 = Get-Content -LiteralPath (Join-Path $workspace 'pinned.json') -Raw | ConvertFrom-Json
        Assert-True 'a second resolve mints a different run id' ([string]$pinned2.runId -ne [string]$pinned1.runId)

        Set-Content -LiteralPath $payloadPath -Encoding UTF8 -Value @"
{"commit_id":"$headSha","event":"COMMENT","body":"Summary for run two, with a new finding.","comments":[]}
"@
        $postsBefore = Get-PostCount
        $post3 = Invoke-Helper -HelperArgs @('-Post', '-Payload', $payloadPath)
        Assert-Equal 'the new run posts successfully' 0 $post3.ExitCode
        Assert-Equal 'an explicit re-review of an unchanged head still publishes' ($postsBefore + 1) (Get-PostCount)
    }
    else {
        Assert-True 'workspace exists on disk' $false
    }
}
finally {
    $env:PATH = $script:originalPath
    $env:TMPDIR = $originalTmpdir
    $env:TEMP = $originalTemp
    $env:TMP = $originalTmp
    Remove-Item Env:\PRREVIEW_TEST_FIXTURES -ErrorAction SilentlyContinue
    Remove-Item Env:\PRREVIEW_TEST_LOG -ErrorAction SilentlyContinue
    Remove-Item Env:\PRREVIEW_TEST_HEAD -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($failures -gt 0) {
    Write-Host "$failures of $checks checks FAILED" -ForegroundColor Red
    exit 1
}
Write-Host "$checks checks passed" -ForegroundColor Green
exit 0
