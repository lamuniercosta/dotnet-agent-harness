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
$skillsSource = Join-Path $harnessRoot 'skills'

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
    param([string[]]$ClaudeMd, [switch]$WithSpecify, [string[]]$Csproj, [string[]]$AgentsMd)

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
    if ($null -ne $AgentsMd) {
        Set-Content -LiteralPath (Join-Path $repo 'AGENTS.md') -Value $AgentsMd -Encoding UTF8
    }
    return $repo
}

function Invoke-Install {
    param([string]$Repo, [string]$Platform)
    if ($Platform) {
        & pwsh -NoProfile -File $installer $Repo -Platform $Platform *>&1 | Out-String
    }
    else {
        & pwsh -NoProfile -File $installer $Repo *>&1 | Out-String
    }
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

    # ── Codex adapter: AGENTS.md absent ──────────────────────────────────────
    # AGENTS.md is a self-contained distillation, not a pointer list: Codex has no
    # @import, so if the file does not arrive intact the conventions do not arrive
    # at all - and, as with CLAUDE.md, nothing reports it.
    $repo = New-TargetRepo
    $repos += $repo
    $output = Invoke-Install -Repo $repo
    $agentsPath = Join-Path $repo 'AGENTS.md'

    Assert-That 'absent AGENTS.md is created by the default platform' `
        (Test-Path $agentsPath) `
        'the default is -Platform all; a Codex user gets no conventions without this'

    if (Test-Path $agentsPath) {
        $agents = Get-Content -LiteralPath $agentsPath -Raw
        # Hooks are present, but Codex requires review and trust before they run
        # and exposes no lifecycle event for scanning file reads.
        Assert-That 'AGENTS.md carries the Codex hook trust and file-read limitation' `
            (($agents -match 'reviewed and trusted') -and ($agents -match 'no file-read lifecycle event')) `
            'the user must know both when hooks run and the gap they cannot cover'
        Assert-That 'AGENTS.md carries the gate exit contract' `
            ($agents -match 'Exit 0 = pass, 1 = fail, 2 = SKIPPED')
    }

    Assert-That '.codex/config.toml registers both documentation servers' `
        ((Test-Path (Join-Path $repo '.codex/config.toml')) -and
         ((Get-Content -LiteralPath (Join-Path $repo '.codex/config.toml') -Raw) -match 'mcp_servers\.microsoft-learn') -and
         ((Get-Content -LiteralPath (Join-Path $repo '.codex/config.toml') -Raw) -match 'mcp_servers\.context7'))

    $codexHooksPath = Join-Path $repo '.codex/hooks.json'
    $codexHooks = if (Test-Path $codexHooksPath) { Get-Content -LiteralPath $codexHooksPath -Raw } else { '' }
    Assert-That 'the default (-Platform all) installs the Codex hook events and scripts' `
        (($codexHooks -match 'UserPromptSubmit') -and
         ($codexHooks -match 'PreToolUse') -and
         ($codexHooks -match 'PostToolUse') -and
         ($codexHooks -match 'secret-scan\.ps1') -and
         ($codexHooks -match 'guard\.ps1') -and
         ($codexHooks -match 'format-on-edit\.ps1') -and
         ($codexHooks -match 'gate-nudge\.ps1')) `
        'the Codex adapter must wire every shared prompt and tool-use hook'

    # ── Codex skills: generated from the canonical tree ─────────────────────
    $sourceSkillNames = @(Get-ChildItem -LiteralPath $skillsSource -Directory | ForEach-Object { $_.Name })
    $codexSkillsPath = Join-Path $repo '.agents/skills'
    $installedSkillNames = if (Test-Path $codexSkillsPath) {
        @(Get-ChildItem -LiteralPath $codexSkillsPath -Directory | ForEach-Object { $_.Name })
    } else { @() }

    Assert-That 'the default installs every canonical skill for Codex' `
        (($sourceSkillNames.Count -eq 25) -and
         (@($sourceSkillNames | Where-Object { $_ -notin $installedSkillNames }).Count -eq 0)) `
        'a missing .agents/skills directory silently removes part of the workflow'
    Assert-That 'the four pipeline entry skills are present for Codex' `
        (@(@('task', 'grill-with-docs', 'verify', 'ship-review') |
             Where-Object { $_ -notin $installedSkillNames }).Count -eq 0)

    $codexTask = Get-Content -LiteralPath (Join-Path $codexSkillsPath 'task/SKILL.md') -Raw
    $claudeTask = Get-Content -LiteralPath (Join-Path $repo '.claude/skills/task/SKILL.md') -Raw
    $codexPipeline = Get-Content -LiteralPath (Join-Path $codexSkillsPath 'pipeline/SKILL.md') -Raw
    Assert-That 'Codex skill handoffs use $name syntax' `
        (($codexTask -match '\$grill-with-docs') -and ($codexTask -notmatch '/grill-with-docs')) `
        'copying slash commands verbatim names commands Codex does not expose'
    Assert-That 'Spec Kit handoffs use the Codex skill syntax too' `
        (($codexPipeline -match '\$speckit-specify') -and ($codexPipeline -notmatch '/speckit-specify'))
    $skillPattern = @($sourceSkillNames | ForEach-Object { [regex]::Escape($_) }) -join '|'
    $legacyCodexRefs = @(Get-ChildItem -LiteralPath $codexSkillsPath -File -Recurse -Filter '*.md' |
        Select-String -Pattern ('(?<![A-Za-z0-9._-])/(?:' + $skillPattern + '|speckit-[A-Za-z0-9-]+)(?=$|[^A-Za-z0-9_-])'))
    Assert-That 'no slash-style harness or Spec Kit invocation survives in Codex skills' `
        ($legacyCodexRefs.Count -eq 0) `
        (($legacyCodexRefs | ForEach-Object { "$($_.Path):$($_.LineNumber)" }) -join ', ')
    Assert-That 'the canonical Claude/Cursor skill copy keeps slash syntax' `
        (($claudeTask -match '/grill-with-docs') -and ($claudeTask -notmatch '\$grill-with-docs')) `
        'Codex adaptation must never rewrite the shared Claude/Cursor delivery'
    Assert-That 'the default install reports both host invocation syntaxes' `
        (($output -match '(?m)^\s+/task <issue>') -and
         ($output -match '(?m)^\s+\$task <issue>') -and
         ($output -match 'specify integration install codex')) `
        'the default serves all hosts and must not hide either next command'

    # Copy-Tree refreshes harness-owned skill names but does not delete foreign
    # project skills. Re-installation must preserve both properties.
    $repo = New-TargetRepo
    $repos += $repo
    $foreignSkill = Join-Path $repo '.agents/skills/house-style/SKILL.md'
    $ownedSkill = Join-Path $repo '.agents/skills/task/SKILL.md'
    New-Item -ItemType Directory -Path (Split-Path $foreignSkill -Parent) -Force | Out-Null
    New-Item -ItemType Directory -Path (Split-Path $ownedSkill -Parent) -Force | Out-Null
    Set-Content -LiteralPath $foreignSkill -Value @(
        '---'
        'name: house-style'
        'description: keep me'
        '---'
        'Our own /task and /speckit-plan wording must not be rewritten.'
    ) -Encoding UTF8
    Set-Content -LiteralPath $ownedSkill -Value 'stale harness task skill' -Encoding UTF8
    $foreignBefore = [System.IO.File]::ReadAllBytes($foreignSkill)
    Invoke-Install -Repo $repo -Platform 'codex' | Out-Null
    $ownedAfterFirst = (Get-FileHash -LiteralPath $ownedSkill -Algorithm SHA256).Hash
    Invoke-Install -Repo $repo -Platform 'codex' | Out-Null
    $ownedAfterSecond = (Get-FileHash -LiteralPath $ownedSkill -Algorithm SHA256).Hash
    $foreignAfter = [System.IO.File]::ReadAllBytes($foreignSkill)

    Assert-That 'foreign .agents skills survive a Codex install byte-identical' `
        ([System.Linq.Enumerable]::SequenceEqual($foreignBefore, $foreignAfter))
    Assert-That 'a same-name harness skill is refreshed and re-installs deterministically' `
        (($ownedAfterFirst -eq $ownedAfterSecond) -and
         ((Get-Content -LiteralPath $ownedSkill -Raw) -match '\$grill-with-docs'))

    # ── Codex adapter: consumer-owned files already exist ────────────────────
    # Deliberately NOT the append treatment CLAUDE.md gets. Ten @import lines are a
    # small reversible addition; a whole ruleset dumped under a repo's own agent
    # instructions is neither, and would contradict them silently.
    $repo = New-TargetRepo -AgentsMd @('# House rules', '', 'Our own agent instructions.')
    $repos += $repo
    # Read from disk rather than rebuilt from the array passed in: Set-Content
    # writes CRLF on Windows and LF elsewhere, so an expectation that hardcodes
    # either one fails on the other platform for a reason that has nothing to do
    # with what install.ps1 did. Compare the file against itself instead.
    $agentsPath = Join-Path $repo 'AGENTS.md'
    $before = Get-Content -LiteralPath $agentsPath -Raw
    $output = Invoke-Install -Repo $repo
    $after = Get-Content -LiteralPath $agentsPath -Raw

    Assert-That 'an existing AGENTS.md is left byte-identical' `
        ($before -ceq $after) `
        'the repo''s own agent instructions were overwritten or appended to'
    Assert-That 'the untouched AGENTS.md is reported for a hand merge' `
        ($output -match 'AGENTS\.md' -and $output -match 'SKIPPED')

    # config.toml remains consumer-owned, while hooks.json remains harness-owned.
    # This also proves .codex is created for hooks even when config.toml prevented
    # the config-install branch from creating that directory.
    $repo = New-TargetRepo
    $repos += $repo
    $codexDir = Join-Path $repo '.codex'
    New-Item -ItemType Directory -Path $codexDir -Force | Out-Null
    $codexConfigPath = Join-Path $codexDir 'config.toml'
    Set-Content -LiteralPath $codexConfigPath -Value @('[mcp_servers.house-rules]', 'command = "keep-me"') -Encoding UTF8
    $before = [System.IO.File]::ReadAllBytes($codexConfigPath)
    $output = Invoke-Install -Repo $repo -Platform 'all'
    $after = [System.IO.File]::ReadAllBytes($codexConfigPath)

    Assert-That 'an existing Codex config.toml is byte-identical while hooks install' `
        (([System.Linq.Enumerable]::SequenceEqual($before, $after)) -and
         (Test-Path (Join-Path $codexDir 'hooks.json'))) `
        'config.toml is consumer-owned; hooks.json must still be synchronized'
    Assert-That 'the existing Codex config is reported as SKIPPED' `
        ($output -match 'config\.toml' -and $output -match 'SKIPPED')

    # ── -Platform both keeps its original meaning ────────────────────────────
    # `both` predates Codex. It must still mean cursor + claude, or every pinned
    # invocation silently changes what it installs.
    $repo = New-TargetRepo
    $repos += $repo
    $output = Invoke-Install -Repo $repo -Platform 'both'

    Assert-That '-Platform both writes no Codex skills, hooks, config, or AGENTS.md' `
        ((-not (Test-Path (Join-Path $repo 'AGENTS.md'))) -and
         (-not (Test-Path (Join-Path $repo '.agents/skills'))) -and
         (-not (Test-Path (Join-Path $repo '.codex/hooks.json'))) -and
         (-not (Test-Path (Join-Path $repo '.codex/config.toml')))) `
        'both means cursor + claude; widening it would change what a pinned flag does'
    Assert-That '-Platform both still writes the Claude adapter' `
        (Test-Path (Join-Path $repo 'CLAUDE.md'))
    Assert-That '-Platform both reports slash syntax and no Codex next step' `
        (($output -match '(?m)^\s+/task <issue>') -and
         ($output -notmatch '(?m)^\s+\$task <issue>') -and
         ($output -notmatch 'integration install codex'))
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
