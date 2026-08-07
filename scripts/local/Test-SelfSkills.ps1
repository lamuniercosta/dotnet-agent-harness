#!/usr/bin/env pwsh
# Proves the repo-local self-development bootstrap generates the same skill
# projections as consumer installation while preserving every unowned entry.
# Uses isolated temporary checkouts; it never writes discovery copies here.

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$harnessRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$syncScript = Join-Path $PSScriptRoot 'Sync-SelfSkills.ps1'
$installer = Join-Path $harnessRoot 'install.ps1'
$canonicalSkills = Join-Path $harnessRoot 'skills'

$checks = 0
$failures = 0
$temporaryRoots = @()

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

function New-TemporaryRoot {
    $path = Join-Path ([System.IO.Path]::GetTempPath()) ('harness-self-skills-test-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    $script:temporaryRoots += $path
    return $path
}

function Write-Bytes {
    param([string]$Path, [string]$Content)

    New-Item -ItemType Directory -Path (Split-Path $Path -Parent) -Force | Out-Null
    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

function New-SelfDevelopmentFixture {
    $root = New-TemporaryRoot
    Copy-Item -LiteralPath $canonicalSkills -Destination (Join-Path $root 'skills') -Recurse -Force
    New-Item -ItemType Directory -Path (Join-Path $root 'scripts/local') -Force | Out-Null
    Write-Bytes -Path (Join-Path $root '.claude/skills/start-issue/SKILL.md') -Content "authored claude override`n"
    Write-Bytes -Path (Join-Path $root '.agents/skills/start-issue/SKILL.md') -Content "authored codex override`n"
    return $root
}

function Invoke-SelfSync {
    param([string]$Root, [switch]$Clean)

    $arguments = @('-NoProfile', '-File', $syncScript, '-RepoRoot', $Root)
    if ($Clean) { $arguments += '-Clean' }
    $output = & pwsh @arguments *>&1 | Out-String
    return [PSCustomObject]@{
        ExitCode = $LASTEXITCODE
        Output = $output
    }
}

function Get-RelativeFiles {
    param([string]$Root)

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return @() }
    return @(Get-ChildItem -LiteralPath $Root -File -Recurse -Force |
            ForEach-Object { $_.FullName.Substring($Root.Length).TrimStart('\', '/') } |
            Sort-Object)
}

function Test-TreeEqual {
    param([string]$Left, [string]$Right)

    $leftFiles = @(Get-RelativeFiles -Root $Left)
    $rightFiles = @(Get-RelativeFiles -Root $Right)
    if (($leftFiles -join "`n") -cne ($rightFiles -join "`n")) { return $false }

    foreach ($relativePath in $leftFiles) {
        $leftBytes = [System.IO.File]::ReadAllBytes((Join-Path $Left $relativePath))
        $rightBytes = [System.IO.File]::ReadAllBytes((Join-Path $Right $relativePath))
        if (-not [System.Linq.Enumerable]::SequenceEqual($leftBytes, $rightBytes)) {
            return $false
        }
    }
    return $true
}

function Get-TreeFingerprint {
    param([string]$Root)

    $parts = foreach ($relativePath in @(Get-RelativeFiles -Root $Root)) {
        $hash = (Get-FileHash -LiteralPath (Join-Path $Root $relativePath) -Algorithm SHA256).Hash
        "$relativePath=$hash"
    }
    return ($parts -join "`n")
}

Write-Host ''
Write-Host 'self-development skill bootstrap'
Write-Host ''

try {
    & git -C $harnessRoot check-ignore -q --no-index -- '.claude/skills/task/SKILL.md'
    $claudeGeneratedIgnored = $LASTEXITCODE -eq 0
    & git -C $harnessRoot check-ignore -q --no-index -- '.agents/skills/task/SKILL.md'
    $codexGeneratedIgnored = $LASTEXITCODE -eq 0
    & git -C $harnessRoot check-ignore -q --no-index -- 'scripts/local/.self-skills-manifest.json'
    $manifestIgnored = $LASTEXITCODE -eq 0
    & git -C $harnessRoot check-ignore -q --no-index -- '.claude/skills/start-issue/SKILL.md'
    $claudeOverrideIgnored = $LASTEXITCODE -eq 0
    & git -C $harnessRoot check-ignore -q --no-index -- '.agents/skills/start-issue/SKILL.md'
    $codexOverrideIgnored = $LASTEXITCODE -eq 0

    Assert-That 'generated discovery copies and the ownership manifest are gitignored' `
        ($claudeGeneratedIgnored -and $codexGeneratedIgnored -and $manifestIgnored)
    Assert-That 'both authored start-issue overrides remain unignored' `
        ((-not $claudeOverrideIgnored) -and (-not $codexOverrideIgnored))

    $fixture = New-SelfDevelopmentFixture
    $foreignClaude = Join-Path $fixture '.claude/skills/house-style/SKILL.md'
    $foreignCodex = Join-Path $fixture '.agents/skills/house-style/SKILL.md'
    Write-Bytes -Path $foreignClaude -Content "foreign claude /task`n"
    Write-Bytes -Path $foreignCodex -Content "foreign codex /task`n"

    $claudeOverride = Join-Path $fixture '.claude/skills/start-issue/SKILL.md'
    $codexOverride = Join-Path $fixture '.agents/skills/start-issue/SKILL.md'
    $protectedBefore = @{
        ClaudeOverride = [System.IO.File]::ReadAllBytes($claudeOverride)
        CodexOverride = [System.IO.File]::ReadAllBytes($codexOverride)
        ForeignClaude = [System.IO.File]::ReadAllBytes($foreignClaude)
        ForeignCodex = [System.IO.File]::ReadAllBytes($foreignCodex)
    }

    $first = Invoke-SelfSync -Root $fixture
    Assert-That 'a clean fixture sync succeeds' ($first.ExitCode -eq 0) $first.Output
    Assert-That 'the first sync reports a required host reload' `
        ($first.Output -match 'Reload Codex and Claude Code') $first.Output

    $consumer = New-TemporaryRoot
    $installOutput = & pwsh -NoProfile -File $installer $consumer -Platform all *>&1 | Out-String
    $installExit = $LASTEXITCODE
    Assert-That 'the consumer reference install succeeds' ($installExit -eq 0) $installOutput

    $skillNames = @(Get-ChildItem -LiteralPath (Join-Path $fixture 'skills') -Directory |
            ForEach-Object { $_.Name } | Sort-Object)
    $claudeMismatches = @($skillNames | Where-Object {
            -not (Test-TreeEqual `
                    -Left (Join-Path $fixture ".claude/skills/$_") `
                    -Right (Join-Path $consumer ".claude/skills/$_"))
        })
    $codexMismatches = @($skillNames | Where-Object {
            -not (Test-TreeEqual `
                    -Left (Join-Path $fixture ".agents/skills/$_") `
                    -Right (Join-Path $consumer ".agents/skills/$_"))
        })
    Assert-That 'every Claude discovery copy matches consumer installation' `
        ($claudeMismatches.Count -eq 0) ($claudeMismatches -join ', ')
    Assert-That 'every Codex discovery copy matches consumer installation' `
        ($codexMismatches.Count -eq 0) ($codexMismatches -join ', ')

    $manifestPath = Join-Path $fixture 'scripts/local/.self-skills-manifest.json'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    Assert-That 'the manifest owns every canonical name for both hosts' `
        ((@($manifest.hosts.claude).Count -eq $skillNames.Count) -and
         (@($manifest.hosts.codex).Count -eq $skillNames.Count) -and
         (@($skillNames | Where-Object { $_ -notin @($manifest.hosts.claude) }).Count -eq 0) -and
         (@($skillNames | Where-Object { $_ -notin @($manifest.hosts.codex) }).Count -eq 0))
    Assert-That 'the manifest never owns authored or foreign skills' `
        (('start-issue' -notin @($manifest.hosts.claude)) -and
         ('start-issue' -notin @($manifest.hosts.codex)) -and
         ('house-style' -notin @($manifest.hosts.claude)) -and
         ('house-style' -notin @($manifest.hosts.codex)))

    $sampleSkill = Join-Path $fixture '.agents/skills/task/SKILL.md'
    $sampleWriteTime = (Get-Item -LiteralPath $sampleSkill).LastWriteTimeUtc.Ticks
    $manifestWriteTime = (Get-Item -LiteralPath $manifestPath).LastWriteTimeUtc.Ticks
    $treeBeforeSecondRun = Get-TreeFingerprint -Root $fixture
    $second = Invoke-SelfSync -Root $fixture
    Assert-That 'an unchanged second sync succeeds and reports no semantic changes' `
        (($second.ExitCode -eq 0) -and ($second.Output -match 'no semantic changes')) $second.Output
    Assert-That 'an unchanged second sync rewrites neither skills nor manifest' `
        (((Get-Item -LiteralPath $sampleSkill).LastWriteTimeUtc.Ticks -eq $sampleWriteTime) -and
         ((Get-Item -LiteralPath $manifestPath).LastWriteTimeUtc.Ticks -eq $manifestWriteTime) -and
         ((Get-TreeFingerprint -Root $fixture) -ceq $treeBeforeSecondRun))

    Assert-That 'authored overrides and foreign skills survive repeated refresh byte-identical' `
        ([System.Linq.Enumerable]::SequenceEqual($protectedBefore.ClaudeOverride, [System.IO.File]::ReadAllBytes($claudeOverride)) -and
         [System.Linq.Enumerable]::SequenceEqual($protectedBefore.CodexOverride, [System.IO.File]::ReadAllBytes($codexOverride)) -and
         [System.Linq.Enumerable]::SequenceEqual($protectedBefore.ForeignClaude, [System.IO.File]::ReadAllBytes($foreignClaude)) -and
         [System.Linq.Enumerable]::SequenceEqual($protectedBefore.ForeignCodex, [System.IO.File]::ReadAllBytes($foreignCodex)))

    $removedName = $skillNames[0]
    Remove-Item -LiteralPath (Join-Path $fixture "skills/$removedName") -Recurse -Force
    $refresh = Invoke-SelfSync -Root $fixture
    Assert-That 'refresh removes a deleted canonical skill from both owned trees' `
        (($refresh.ExitCode -eq 0) -and
         (-not (Test-Path -LiteralPath (Join-Path $fixture ".claude/skills/$removedName"))) -and
         (-not (Test-Path -LiteralPath (Join-Path $fixture ".agents/skills/$removedName"))) -and
         ($refresh.Output -match '2 removed')) $refresh.Output
    Assert-That 'canonical removal does not alter foreign skills' `
        ([System.Linq.Enumerable]::SequenceEqual($protectedBefore.ForeignClaude, [System.IO.File]::ReadAllBytes($foreignClaude)) -and
         [System.Linq.Enumerable]::SequenceEqual($protectedBefore.ForeignCodex, [System.IO.File]::ReadAllBytes($foreignCodex)))

    $collisionFixture = New-SelfDevelopmentFixture
    $collisionPath = Join-Path $collisionFixture '.agents/skills/task/SKILL.md'
    Write-Bytes -Path $collisionPath -Content "foreign same-name task`n"
    $collisionBefore = Get-TreeFingerprint -Root $collisionFixture
    $collision = Invoke-SelfSync -Root $collisionFixture
    Assert-That 'an unowned same-name collision fails with a clear diagnostic' `
        (($collision.ExitCode -ne 0) -and
         ($collision.Output -match 'exists but is not manifest-owned') -and
         ($collision.Output -match 'No files were changed')) $collision.Output
    Assert-That 'collision preflight leaves the entire fixture byte-identical' `
        (((Get-TreeFingerprint -Root $collisionFixture) -ceq $collisionBefore) -and
         (-not (Test-Path -LiteralPath (Join-Path $collisionFixture 'scripts/local/.self-skills-manifest.json'))))

    $clean = Invoke-SelfSync -Root $fixture -Clean
    $remainingOwned = @()
    foreach ($hostPath in @('.claude/skills', '.agents/skills')) {
        $remainingOwned += @(Get-ChildItem -LiteralPath (Join-Path $fixture $hostPath) -Directory |
                Where-Object { $_.Name -notin @('start-issue', 'house-style') })
    }
    Assert-That '-Clean removes only manifest-owned discovery copies and the manifest' `
        (($clean.ExitCode -eq 0) -and
         ($remainingOwned.Count -eq 0) -and
         (-not (Test-Path -LiteralPath $manifestPath)) -and
         ($clean.Output -match 'Reload Codex and Claude Code')) $clean.Output
    Assert-That '-Clean preserves authored overrides and foreign skills byte-identical' `
        ([System.Linq.Enumerable]::SequenceEqual($protectedBefore.ClaudeOverride, [System.IO.File]::ReadAllBytes($claudeOverride)) -and
         [System.Linq.Enumerable]::SequenceEqual($protectedBefore.CodexOverride, [System.IO.File]::ReadAllBytes($codexOverride)) -and
         [System.Linq.Enumerable]::SequenceEqual($protectedBefore.ForeignClaude, [System.IO.File]::ReadAllBytes($foreignClaude)) -and
         [System.Linq.Enumerable]::SequenceEqual($protectedBefore.ForeignCodex, [System.IO.File]::ReadAllBytes($foreignCodex)))
}
finally {
    foreach ($root in $temporaryRoots) {
        if (Test-Path -LiteralPath $root) {
            Remove-Item -LiteralPath $root -Recurse -Force
        }
    }
}

Write-Host ''
if ($failures -eq 0) {
    Write-Host "$checks self-development skill checks passed." -ForegroundColor Green
    exit 0
}

Write-Host "$failures of $checks self-development skill checks failed." -ForegroundColor Red
exit 1
