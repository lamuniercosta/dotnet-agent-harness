#!/usr/bin/env pwsh
# Proves how install.ps1 treats an existing .specify/extensions.yml.
#
# That file is shared territory: `specify init` writes it and every registered
# Spec Kit extension records its hooks in it. Overwriting it unconditionally
# disables them silently - the failure mode is a stage that stops running, with
# no error anywhere. So the three branches are asserted here, end to end.
#
# This runs the REAL install.ps1 against throwaway repos rather than testing an
# extracted helper. The bug this guards against lives in the seam between the
# decision and the write, which a unit test of the decision alone cannot see.
#
# Every case asserts the resulting file CONTENT, never the exit code. install.ps1
# exits 0 whether it wrote, refreshed, or refused, so an exit-code assertion
# would pass in all three and prove nothing - the same trap as a gate that
# reports success because it never ran.

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$harnessRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$installer = Join-Path $harnessRoot 'install.ps1'
$template = Join-Path $harnessRoot 'speckit/extensions.yml'

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

# A throwaway target repo with a .specify directory and the given extensions.yml.
function New-TargetRepo {
    # [string[]], not [string]: an array bound to a [string] parameter is
    # silently joined into one space-separated line, which produces a malformed
    # document that reads as foreign and makes every case pass for the wrong
    # reason.
    param([string[]]$ExtensionsContent)

    $repo = Join-Path ([System.IO.Path]::GetTempPath()) ("harness-speckit-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path (Join-Path $repo '.specify') -Force | Out-Null

    if ($null -ne $ExtensionsContent) {
        Set-Content -LiteralPath (Join-Path $repo '.specify/extensions.yml') -Value $ExtensionsContent -Encoding UTF8
    }
    return $repo
}

function Invoke-Install {
    param([string]$Repo)
    & pwsh -NoProfile -File $installer $Repo *>&1 | Out-String
}

function Get-Extensions {
    param([string]$Repo)
    Get-Content -LiteralPath (Join-Path $Repo '.specify/extensions.yml') -Raw
}

Write-Host ''
Write-Host 'Spec Kit extensions.yml install behaviour'
Write-Host ''

$repos = @()

try {
    # ── The template itself ──────────────────────────────────────────────────
    # after_refactor is not a Spec Kit event. No core command reads it, so a hook
    # registered against it is dead config that reads as active.
    $templateText = Get-Content -LiteralPath $template -Raw
    Assert-That 'template registers no after_refactor hook' `
        ($templateText -notmatch '(?m)^\s*after_refactor\s*:') `
        'Spec Kit emits no after_refactor event; /architect chains from the refactor skill'

    foreach ($event in @('before_specify', 'after_tasks', 'after_implement')) {
        Assert-That "template registers $event" ($templateText -match "(?m)^\s*${event}\s*:")
    }

    Assert-That 'template carries Spec Kit''s own installed/settings keys' `
        (($templateText -match '(?m)^installed\s*:') -and ($templateText -match '(?m)^settings\s*:'))

    # ── Case 1: pristine ─────────────────────────────────────────────────────
    # What `specify init` leaves behind. Nothing to lose, so it is written.
    $pristine = @(
        'installed: []'
        'settings:'
        '  auto_execute_hooks: true'
        'hooks: {}'
    )
    $repo = New-TargetRepo -ExtensionsContent $pristine
    $repos += $repo
    Invoke-Install -Repo $repo | Out-Null
    $result = Get-Extensions -Repo $repo

    Assert-That 'pristine file is overwritten with the harness hooks' `
        ($result -match 'harness-pipeline') `
        'a pristine extensions.yml has nothing to preserve, so the coupling must install'
    Assert-That 'pristine overwrite keeps hooks: {} from becoming the only content' `
        ($result -match 'before_specify')

    # ── Case 2: pristine with a non-default setting ──────────────────────────
    # auto_execute_hooks is Spec Kit's switch, not ours. Writing our hooks must
    # not quietly flip it back on.
    $customised = @(
        'installed: []'
        'settings:'
        '  auto_execute_hooks: false'
        'hooks: {}'
    )
    $repo = New-TargetRepo -ExtensionsContent $customised
    $repos += $repo
    Invoke-Install -Repo $repo | Out-Null
    $result = Get-Extensions -Repo $repo

    Assert-That 'existing settings block survives the overwrite' `
        ($result -match 'auto_execute_hooks:\s*false') `
        'the user turned mandatory hook execution off; install must not turn it back on'
    Assert-That 'hooks are still installed alongside the preserved setting' `
        ($result -match 'harness-pipeline')

    # ── Case 3: ours ─────────────────────────────────────────────────────────
    # The upgrade path. A second install must refresh its own file, or the
    # harness could never ship a change to it.
    $repo = New-TargetRepo -ExtensionsContent $pristine
    $repos += $repo
    Invoke-Install -Repo $repo | Out-Null

    # Simulate an older harness file: ours, but carrying the dead hook.
    $stale = (Get-Extensions -Repo $repo).TrimEnd() + @"

  after_refactor:
    - extension: harness-pipeline
      command: architect
      optional: false
      description: stale
"@
    Set-Content -LiteralPath (Join-Path $repo '.specify/extensions.yml') -Value $stale -Encoding UTF8
    Invoke-Install -Repo $repo | Out-Null
    $result = Get-Extensions -Repo $repo

    # Anchored to a key, not the bare word: the refreshed template explains in a
    # comment why no after_refactor hook exists, so a substring match would fail
    # on correct output.
    Assert-That 'a harness-owned file is refreshed on re-install' `
        ($result -notmatch '(?m)^\s*after_refactor\s*:') `
        'the dead hook survived; install.ps1 cannot upgrade its own file'
    Assert-That 'refresh leaves the live hooks in place' `
        (($result -match 'before_specify') -and ($result -match 'after_implement'))

    # ── Case 4: foreign ──────────────────────────────────────────────────────
    # The bundled `git` extension registers six hooks here. Clobbering them
    # disables feature-branch creation with no error.
    $foreign = @(
        'installed:'
        '  - git'
        'settings:'
        '  auto_execute_hooks: true'
        'hooks:'
        '  before_specify:'
        '    - extension: git'
        '      command: speckit.git.feature'
        '      optional: false'
        '      description: Create feature branch before specification'
    )
    $repo = New-TargetRepo -ExtensionsContent $foreign
    $repos += $repo
    $before = Get-Extensions -Repo $repo
    $output = Invoke-Install -Repo $repo
    $after = Get-Extensions -Repo $repo

    Assert-That 'a file carrying another extension''s hooks is left byte-identical' `
        ($before -ceq $after) `
        'the git extension''s hooks were overwritten; its branch creation is now silently dead'
    Assert-That 'refusing to overwrite is reported, not silent' `
        ($output -match 'MANUAL') `
        'a file the installer declined to write must say so, or the coupling appears installed'

    # ── Case 5: no .specify at all ───────────────────────────────────────────
    $repo = Join-Path ([System.IO.Path]::GetTempPath()) ("harness-speckit-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $repo -Force | Out-Null
    $repos += $repo
    $output = Invoke-Install -Repo $repo

    Assert-That 'a repo without .specify is told to run specify init' `
        ($output -match 'PENDING') `
        'creating .specify here would be overwritten by specify init later'
    Assert-That 'no extensions.yml is invented when .specify is absent' `
        (-not (Test-Path (Join-Path $repo '.specify/extensions.yml')))
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
