#!/usr/bin/env pwsh
# Proves what install.ps1 writes into a target repo's own files.
#
# Two artifacts, one failure mode. CLAUDE.md carries the @imports that are the
# ONLY route by which Claude Code reaches the rules in .cursor/rules, and
# constitution.md is the project law that /implement reads. Getting either wrong
# is silent: rules simply stop arriving, and nothing reports it.
#
# Runs the REAL install.ps1 against throwaway repos and asserts file CONTENT.
# install.ps1 exits 0 whether it wrote, appended, or skipped, so an exit-code
# assertion would pass in every branch and prove nothing.

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$harnessRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$installer = Join-Path $harnessRoot 'install.ps1'
$adapter = Join-Path $harnessRoot 'adapters/claude/CLAUDE.md'

$checks = 0
$failures = 0

function Assert-That {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')

    $script:checks++
    if ($Condition) {
        Write-Host ("  ok    {0}" -f $Name)
    }
    else {
        Write-Host ("  FAIL  {0}" -f $Name) -ForegroundColor Red
        if ($Detail) { Write-Host ("        {0}" -f $Detail) -ForegroundColor DarkGray }
        $script:failures++
    }
}

function New-TargetRepo {
    # [string[]] on the content parameters: an array bound to [string] is joined
    # into one space-separated line, producing a file that passes assertions for
    # entirely the wrong reason.
    param([string[]]$ClaudeMd, [switch]$WithSpecify, [string[]]$Csproj)

    $repo = Join-Path ([System.IO.Path]::GetTempPath()) ("harness-artifacts-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $repo -Force | Out-Null

    if ($null -ne $ClaudeMd) {
        Set-Content -LiteralPath (Join-Path $repo 'CLAUDE.md') -Value $ClaudeMd -Encoding UTF8
    }
    if ($WithSpecify) {
        New-Item -ItemType Directory -Path (Join-Path $repo '.specify') -Force | Out-Null
    }
    if ($null -ne $Csproj) {
        Set-Content -LiteralPath (Join-Path $repo 'Sample.csproj') -Value $Csproj -Encoding UTF8
    }
    return $repo
}

function Invoke-Install {
    param([string]$Repo)
    & pwsh -NoProfile -File $installer $Repo *>&1 | Out-String
}

Write-Host ''
Write-Host 'install.ps1 target-repo artifacts'
Write-Host ''

$repos = @()
$expectedImports = @(Get-Content -LiteralPath $adapter | Where-Object { $_ -match '^@\.cursor/rules/' }).Count

try {
    Assert-That 'adapter declares the always-on rule imports' `
        ($expectedImports -gt 0) `
        "no @.cursor/rules/ imports found in $adapter"

    # ── CLAUDE.md: absent ────────────────────────────────────────────────────
    $repo = New-TargetRepo
    $repos += $repo
    Invoke-Install -Repo $repo | Out-Null
    $claude = Get-Content -LiteralPath (Join-Path $repo 'CLAUDE.md') -Raw

    Assert-That 'absent CLAUDE.md is created with every import' `
        (@([regex]::Matches($claude, '(?m)^@\.cursor/rules/')).Count -eq $expectedImports)

    # ── CLAUDE.md: exists without imports ────────────────────────────────────
    # The case that mattered: both repos that adopted the harness had their own
    # CLAUDE.md, so the imports were never added and NO rule loaded on Claude Code.
    $ownContent = @(
        '# My project'
        ''
        'Some instructions that must survive untouched.'
    )
    $repo = New-TargetRepo -ClaudeMd $ownContent
    $repos += $repo
    $output = Invoke-Install -Repo $repo
    $claude = Get-Content -LiteralPath (Join-Path $repo 'CLAUDE.md') -Raw

    Assert-That 'existing CLAUDE.md gains every import' `
        (@([regex]::Matches($claude, '(?m)^@\.cursor/rules/')).Count -eq $expectedImports) `
        'without these, Claude Code loads no harness rules at all and says nothing'
    Assert-That 'the repo''s own CLAUDE.md content survives the append' `
        (($claude -match '# My project') -and ($claude -match 'must survive untouched'))
    Assert-That 'appending is reported, not silent' `
        ($output -match 'APPENDED')
    # Guards the parse: a heading rename in the adapter would otherwise append
    # prose with no imports, which looks like success.
    Assert-That 'the appended block carries the do-not-delete-.cursor warning' `
        ($claude -match 'do not delete') `
        'the section parse picked up the wrong content'

    # ── CLAUDE.md: exists with imports (re-install) ──────────────────────────
    $before = Get-Content -LiteralPath (Join-Path $repo 'CLAUDE.md') -Raw
    $output = Invoke-Install -Repo $repo
    $after = Get-Content -LiteralPath (Join-Path $repo 'CLAUDE.md') -Raw

    Assert-That 'a second install does not append the imports twice' `
        ($before -ceq $after) `
        'the idempotency check failed; every re-install would stack another copy'
    Assert-That 'the no-op is reported as SKIPPED' `
        ($output -match 'SKIPPED')

    # ── Constitution: rendered when absent ───────────────────────────────────
    $repo = New-TargetRepo -WithSpecify -Csproj @(
        '<Project Sdk="Microsoft.NET.Sdk">'
        '  <PropertyGroup><TargetFramework>net10.0</TargetFramework></PropertyGroup>'
        '</Project>'
    )
    $repos += $repo
    $output = Invoke-Install -Repo $repo
    $constitutionPath = Join-Path $repo '.specify/memory/constitution.md'

    Assert-That 'constitution is rendered when .specify exists and it does not' `
        (Test-Path $constitutionPath)

    if (Test-Path $constitutionPath) {
        $constitution = Get-Content -LiteralPath $constitutionPath -Raw
        Assert-That 'no placeholders survive rendering' `
            ($constitution -notmatch '\{\{') `
            'an unsubstituted {{PLACEHOLDER}} shipped into the project law'
        Assert-That 'the detected target framework is used' `
            ($constitution -match '\.NET 10') `
            'TargetFramework net10.0 was declared but not picked up'
        Assert-That 'the rendered name comes from the repo' `
            ($constitution -match [regex]::Escape((Split-Path $repo -Leaf)))
        Assert-That 'the chosen framework is reported, not applied silently' `
            ($output -match 'RENDERED')
    }

    # ── Constitution: never overwritten ──────────────────────────────────────
    # Guarded on the directory rather than assuming the render happened: when it
    # did not, writing here would throw and abandon every assertion below it. A
    # test that dies mid-run reports less than one that fails.
    $memoryDir = Split-Path $constitutionPath -Parent
    New-Item -ItemType Directory -Path $memoryDir -Force | Out-Null

    $mine = @('# My constitution', '', 'Article I. This must not be touched.')
    Set-Content -LiteralPath $constitutionPath -Value $mine -Encoding UTF8
    $before = Get-Content -LiteralPath $constitutionPath -Raw
    $output = Invoke-Install -Repo $repo
    $after = Get-Content -LiteralPath $constitutionPath -Raw

    Assert-That 'an existing constitution is left byte-identical' `
        ($before -ceq $after) `
        'the project''s own law was overwritten by a template'

    # ── Constitution: no .specify ────────────────────────────────────────────
    $repo = New-TargetRepo
    $repos += $repo
    $output = Invoke-Install -Repo $repo

    Assert-That 'no constitution is invented without .specify' `
        (-not (Test-Path (Join-Path $repo '.specify/memory/constitution.md'))) `
        'specify init would overwrite a directory created here'
    Assert-That 'the missing .specify is reported as PENDING' `
        ($output -match 'PENDING')

    # ── Offered templates ────────────────────────────────────────────────────
    Assert-That 'shipped-but-not-installed templates are surfaced' `
        (($output -match 'codeql\.yml') -and ($output -match 'AVAILABLE')) `
        'a template nothing mentions is a template nobody finds'
    # Anchored to the new sentence, not a bare '-All': the reconcile footer has
    # always printed an -All command, so a loose match would pass against an
    # installer that never gained this hint at all.
    Assert-That 'the baseline hint is printed' `
        ($output -match 'Run them once with -All to get a baseline') `
        'the first no-arg gate run passes having checked nothing; say so'
}
finally {
    foreach ($r in $repos) {
        Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ''
if ($failures -gt 0) {
    Write-Host "$failures of $checks checks FAILED." -ForegroundColor Red
    exit 1
}

Write-Host "All $checks checks passed."
exit 0
