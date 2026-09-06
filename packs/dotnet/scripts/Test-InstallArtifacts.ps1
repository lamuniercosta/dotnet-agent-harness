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

    # ── Generated named agents: all hosts, native syntax ────────────────────
    $expectedAgentNames = @(Get-ChildItem -LiteralPath (Join-Path $harnessRoot '.claude/agents') `
        -File -Filter '*.md' | ForEach-Object { $_.BaseName } | Sort-Object)
    $claudeAgentNames = @(Get-ChildItem -LiteralPath (Join-Path $repo '.claude/agents') `
        -File -Filter '*.md' | ForEach-Object { $_.BaseName } | Sort-Object)
    $cursorAgentNames = @(Get-ChildItem -LiteralPath (Join-Path $repo '.cursor/agents') `
        -File -Filter '*.md' | ForEach-Object { $_.BaseName } | Sort-Object)
    $codexAgentNames = @(Get-ChildItem -LiteralPath (Join-Path $repo '.codex/agents') `
        -File -Filter '*.toml' | ForEach-Object { $_.BaseName } | Sort-Object)

    Assert-That 'all seven canonical agent names reach Claude Code' `
        (($expectedAgentNames -join ',') -eq ($claudeAgentNames -join ','))
    Assert-That 'all seven canonical agent names reach Cursor' `
        (($expectedAgentNames -join ',') -eq ($cursorAgentNames -join ','))
    Assert-That 'all seven canonical agent names reach Codex' `
        (($expectedAgentNames -join ',') -eq ($codexAgentNames -join ','))

    foreach ($agentName in $expectedAgentNames) {
        $sourceAgent = Get-Content -LiteralPath (Join-Path $harnessRoot ".claude/agents/$agentName.md")
        $tier = (($sourceAgent | Where-Object { $_ -match '^tier: ' } | Select-Object -First 1) -replace '^tier:\s*', '')
        $claudeRendered = Get-Content -LiteralPath (Join-Path $repo ".claude/agents/$agentName.md") -Raw
        $cursorRendered = Get-Content -LiteralPath (Join-Path $repo ".cursor/agents/$agentName.md") -Raw
        $codexRendered = Get-Content -LiteralPath (Join-Path $repo ".codex/agents/$agentName.toml") -Raw
        $matchesTier = if ($tier -eq 'fast') {
            ($claudeRendered -match '(?m)^model: claude-haiku-4-5-20251001$') -and
            ($cursorRendered -match '(?m)^model: gpt-5\.6-luna\[effort=low\]$') -and
            ($codexRendered -match '(?m)^model = "gpt-5\.6-terra"$')
        }
        else {
            ($claudeRendered -notmatch '(?m)^model:') -and
            ($cursorRendered -match '(?m)^model: inherit$') -and
            ($codexRendered -notmatch '(?m)^model =')
        }
        Assert-That "tier '$tier' renders on every host for $agentName" $matchesTier
    }

    $claudeFast = Get-Content -LiteralPath (Join-Path $repo '.claude/agents/gate-runner.md') -Raw
    $cursorFast = Get-Content -LiteralPath (Join-Path $repo '.cursor/agents/gate-runner.md') -Raw
    $codexFast = Get-Content -LiteralPath (Join-Path $repo '.codex/agents/gate-runner.toml') -Raw
    Assert-That 'fast tier renders Claude model, effort, and plan permission' `
        (($claudeFast -match '(?m)^model: claude-haiku-4-5-20251001$') -and
         ($claudeFast -match '(?m)^effort: low$') -and
         ($claudeFast -match '(?m)^permissionMode: plan$'))
    Assert-That 'fast tier renders Cursor combined model syntax and readonly' `
        (($cursorFast -match '(?m)^model: gpt-5\.6-luna\[effort=low\]$') -and
         ($cursorFast -match '(?m)^readonly: true$'))
    Assert-That 'fast tier renders Codex model, effort, and sandbox' `
        (($codexFast -match '(?m)^model = "gpt-5\.6-terra"$') -and
         ($codexFast -match '(?m)^model_reasoning_effort = "low"$') -and
         ($codexFast -match '(?m)^sandbox_mode = "read-only"$'))

    $claudeBalanced = Get-Content -LiteralPath (Join-Path $repo '.claude/agents/code-reviewer.md') -Raw
    $cursorBalanced = Get-Content -LiteralPath (Join-Path $repo '.cursor/agents/code-reviewer.md') -Raw
    $codexBalanced = Get-Content -LiteralPath (Join-Path $repo '.codex/agents/code-reviewer.toml') -Raw
    Assert-That 'balanced Claude profile omits inherited model and effort' `
        (($claudeBalanced -notmatch '(?m)^(?:model|effort):') -and
         ($claudeBalanced -match '(?m)^permissionMode: plan$'))
    Assert-That 'balanced Cursor profile renders model inherit without effort' `
        (($cursorBalanced -match '(?m)^model: inherit$') -and
         ($cursorBalanced -notmatch '\[effort='))
    Assert-That 'balanced Codex profile omits inherited model and effort' `
        (($codexBalanced -notmatch '(?m)^model =') -and
         ($codexBalanced -notmatch '(?m)^model_reasoning_effort ='))

    $claudeWritable = Get-Content -LiteralPath (Join-Path $repo '.claude/agents/edit-applier.md') -Raw
    $cursorWritable = Get-Content -LiteralPath (Join-Path $repo '.cursor/agents/edit-applier.md') -Raw
    $codexWritable = Get-Content -LiteralPath (Join-Path $repo '.codex/agents/edit-applier.toml') -Raw
    Assert-That 'writable agents do not receive read-only host controls' `
        (($claudeWritable -notmatch '(?m)^permissionMode:') -and
         ($cursorWritable -match '(?m)^readonly: false$') -and
         ($codexWritable -notmatch '(?m)^sandbox_mode ='))
    Assert-That 'every generated profile carries a harness ownership marker' `
        (($claudeFast -match '(?m)^harnessGenerated: true$') -and
         ($cursorFast -match '(?m)^harnessGenerated: true$') -and
         ($codexFast -match '(?m)^# dotnet-agent-harness: generated agent$'))

    $codexTestWriter = Get-Content -LiteralPath (Join-Path $repo '.codex/agents/test-writer.toml') -Raw
    Assert-That 'Codex agent instructions adapt slash-style skill references' `
        (($codexTestWriter -match '\$convention-learner') -and
         ($codexTestWriter -notmatch '/convention-learner'))
    $agentSkillNames = @(Get-ChildItem -LiteralPath $skillsSource -Directory | ForEach-Object { [regex]::Escape($_.Name) })
    $agentSkillPattern = $agentSkillNames -join '|'
    $legacyCodexAgentRefs = @(Get-ChildItem -LiteralPath (Join-Path $repo '.codex/agents') -File -Filter '*.toml' |
        Select-String -Pattern ('(?<![A-Za-z0-9._-])/(?:' + $agentSkillPattern + '|speckit-[A-Za-z0-9-]+)(?=$|[^A-Za-z0-9_-])'))
    Assert-That 'no slash-style skill invocation survives in any Codex agent field' `
        ($legacyCodexAgentRefs.Count -eq 0) `
        (($legacyCodexAgentRefs | ForEach-Object { "$($_.Path):$($_.LineNumber)" }) -join ', ')

    $claudePipelineDir = Join-Path $repo '.claude/rules/pipeline'
    $claudePipelineFiles = @()
    if (Test-Path -LiteralPath $claudePipelineDir) {
        $claudePipelineFiles = @(Get-ChildItem -LiteralPath $claudePipelineDir -File -Force)
    }
    Assert-That '.claude/rules/pipeline contains exactly 8 scoped rules' `
        ($claudePipelineFiles.Count -eq 8) `
        "found $($claudePipelineFiles.Count) files"
    $allAlwaysApplyFalse = $true
    $pathsFrontmatterCount = 0
    foreach ($pipelineFile in $claudePipelineFiles) {
        $pipelineRaw = Get-Content -LiteralPath $pipelineFile.FullName -Raw
        if ($pipelineRaw -notmatch '(?m)^alwaysApply:\s*false\s*$') {
            $allAlwaysApplyFalse = $false
        }
        if ($pipelineRaw -match '(?m)^paths:\s*$') {
            $pathsFrontmatterCount++
        }
    }
    Assert-That 'every .claude/rules/pipeline file is alwaysApply: false' `
        (($claudePipelineFiles.Count -eq 8) -and $allAlwaysApplyFalse) `
        'copied files must be the alwaysApply: false pipeline rules'
    Assert-That 'five .claude/rules/pipeline files carry paths: frontmatter' `
        ($pathsFrontmatterCount -eq 5) `
        "found $pathsFrontmatterCount files with paths:"

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
        Assert-That 'AGENTS.md distils the cost-aware delegation rule in full' `
            (($agents -match 'delegate\s+conclusions; keep required content inline') -and
             ($agents -match 'edit-applier') -and
             ($agents -match 'do not\s+re-brief the cheap agent')) `
            'Codex cannot import delegation.mdc, so a pointer would silently omit the rule'
        Assert-That 'AGENTS.md documents generated Codex named agents' `
            (($agents -match '\.codex/agents/') -and ($agents -match 'seven named profiles'))
        Assert-That 'AGENTS.md freezes loop terms after start and keeps deferred Critical/High as NEEDS FIXES' `
            (($agents -match '(?is)amendment.+?(closing bar|scope).+?new issue') -and
             ($agents -match '(?is)(Critical|High).+?NEEDS FIXES') -and
             ($agents -match '(?is)(READY|PR suggestion)')) `
            'Codex cannot import agent-pipeline.mdc; deferred Critical/High must still block READY'
        Assert-That 'AGENTS.md routes non-bar items to follow-up issues' `
            ($agents -match '(?is)anything else is a follow-up issue, not a finding in this round\.')
        Assert-That 'AGENTS.md uses unqualified Critical/High readiness wording' `
            (($agents -match '(?is)A Critical or High finding') -and
             ($agents -notmatch '(?is)A confirmed Critical or High finding'))
        Assert-That 'rendered AGENTS.md numbers /address-pr-review as list ordinal 9' `
            (($agents -match '(?m)^9\..+/address-pr-review') -and
             ($agents -notmatch '(?m)^11\..+/address-pr-review')) `
            'workflow list is sequential 1..10; /address-pr-review is ordinal 9 (conditional stage 11) and must not remain numbered 11 in the Codex adapter copy'
    }

    $renderedClaude = Get-Content -LiteralPath (Join-Path $repo 'CLAUDE.md') -Raw
    Assert-That 'rendered CLAUDE.md numbers /address-pr-review as list ordinal 9' `
        (($renderedClaude -match '(?m)^9\..+/address-pr-review') -and
         ($renderedClaude -notmatch '(?m)^11\..+/address-pr-review')) `
        'workflow list is sequential 1..10; /address-pr-review is ordinal 9 (conditional stage 11) and must not remain numbered 11 in the Claude adapter copy'

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
        (($sourceSkillNames.Count -eq 28) -and
         (@($sourceSkillNames | Where-Object { $_ -notin $installedSkillNames }).Count -eq 0)) `
        'a missing .agents/skills directory silently removes part of the workflow'
    Assert-That 'pipeline entry skills including address-pr-review are present for Codex' `
        (@(@('task', 'grill-with-docs', 'verify', 'ship-review', 'address-pr-review') |
             Where-Object { $_ -notin $installedSkillNames }).Count -eq 0)

    # Supporting skill, not a pipeline entry: do not append 'pr-review' to the
    # list above. The installed copies must carry the DEV-114 workflow section.
    $codexPrReviewPath = Join-Path $codexSkillsPath 'pr-review/SKILL.md'
    $claudePrReviewPath = Join-Path $repo '.claude/skills/pr-review/SKILL.md'
    Assert-That 'installed Claude and Codex trees include the pr-review skill' `
        ((Test-Path -LiteralPath $claudePrReviewPath) -and (Test-Path -LiteralPath $codexPrReviewPath)) `
        'pr-review ships as a supporting skill; a missing install copy is invisible at runtime'
    $codexPrReview = ''
    $claudePrReview = ''
    if ((Test-Path -LiteralPath $codexPrReviewPath) -and (Test-Path -LiteralPath $claudePrReviewPath)) {
        $codexPrReview = Get-Content -LiteralPath $codexPrReviewPath -Raw
        $claudePrReview = Get-Content -LiteralPath $claudePrReviewPath -Raw
    }
    Assert-That 'installed Claude pr-review skill includes the user-facing workflow' `
        (($claudePrReview -match '(?s)-Validate.{0,80}-Dedupe.{0,80}-BuildPayload.{0,80}-Preflight.{0,80}-Post') -and
         ($claudePrReview -match 'before any GitHub write') -and
         ($claudePrReview -match 'decline field')) `
        'the Claude/Cursor copy must keep the publish chain, head-move abort, and decline-field check'
    Assert-That 'installed Codex pr-review skill includes the user-facing workflow' `
        (($codexPrReview -match '(?s)-Validate.{0,80}-Dedupe.{0,80}-BuildPayload.{0,80}-Preflight.{0,80}-Post') -and
         ($codexPrReview -match 'before any GitHub write') -and
         ($codexPrReview -match 'decline field')) `
        'the Codex copy must keep the publish chain, head-move abort, and decline-field check'
    $claudePrReviewCommon = Join-Path $repo '.claude/skills/pr-review/scripts/_pr-review-common.ps1'
    $claudePrReviewWorkspace = Join-Path $repo '.claude/skills/pr-review/scripts/_pr-review-workspace.ps1'
    $codexPrReviewCommon = Join-Path $codexSkillsPath 'pr-review/scripts/_pr-review-common.ps1'
    $codexPrReviewWorkspace = Join-Path $codexSkillsPath 'pr-review/scripts/_pr-review-workspace.ps1'
    Assert-That 'installed Claude and Codex trees include _pr-review-common.ps1' `
        ((Test-Path -LiteralPath $claudePrReviewCommon) -and (Test-Path -LiteralPath $codexPrReviewCommon)) `
        'Copy-Tree must land the common library on both host skill paths; a missing file is invisible until runtime'
    Assert-That 'installed Claude and Codex trees include _pr-review-workspace.ps1' `
        ((Test-Path -LiteralPath $claudePrReviewWorkspace) -and (Test-Path -LiteralPath $codexPrReviewWorkspace)) `
        'Copy-Tree must land the workspace library on both host skill paths; a missing file is invisible until runtime'

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
    $codexSkillFiles = @(Get-ChildItem -LiteralPath $codexSkillsPath -File -Recurse -Filter '*.md')
    $hostControlPlaneRefs = @($codexSkillFiles |
        Select-String -Pattern '\b(?:ToolSearch|ReportFindings)\b|`?Task`?\s+(?:tool|calls?)\b')
    Assert-That 'generated Codex skills contain no host-specific control-plane APIs' `
        ($hostControlPlaneRefs.Count -eq 0) `
        (($hostControlPlaneRefs | ForEach-Object { "$($_.Path):$($_.LineNumber)" }) -join ', ')
    $codexCodeReview = Get-Content -LiteralPath (Join-Path $codexSkillsPath 'code-review/SKILL.md') -Raw
    $claudeCodeReview = Get-Content -LiteralPath (Join-Path $repo '.claude/skills/code-review/SKILL.md') -Raw
    $codexGrill = Get-Content -LiteralPath (Join-Path $codexSkillsPath 'grill-with-docs/SKILL.md') -Raw
    $codexShipReview = Get-Content -LiteralPath (Join-Path $codexSkillsPath 'ship-review/SKILL.md') -Raw
    $claudeShipReview = Get-Content -LiteralPath (Join-Path $repo '.claude/skills/ship-review/SKILL.md') -Raw
    $codexAddressPrReview = Get-Content -LiteralPath (Join-Path $codexSkillsPath 'address-pr-review/SKILL.md') -Raw
    $claudeAddressPrReview = Get-Content -LiteralPath (Join-Path $repo '.claude/skills/address-pr-review/SKILL.md') -Raw
    Assert-That 'Codex grill-with-docs routes non-bar items to follow-up issues' `
        ($codexGrill -match '(?is)anything else is a follow-up issue, not a finding in this round\.')
    Assert-That 'Codex ship-review fails closed when loop terms are missing' `
        (($codexShipReview -match '(?is)FEATURE_DIR') -and
         ($codexShipReview -match '(?is)check-prerequisites\.ps1') -and
         ($codexShipReview -match '(?is)<FEATURE_DIR>/brief\.md') -and
         ($codexShipReview -match '(?is)closing bar') -and
         ($codexShipReview -match '(?is)frozen scope') -and
         ($codexShipReview -match '(?is)round cap') -and
         ($codexShipReview -match '(?is)Could not run') -and
         ($codexShipReview -match 'NEEDS FIXES') -and
         ($codexShipReview -match '(?is)before Step 1')) `
        'missing closing bar, frozen scope, or round cap must stop before fan-out'
    Assert-That 'Codex ship-review routes below-bar and out-of-scope items to Follow-ups' `
        (($codexShipReview -match '(?is)(does not meet the closing bar|below the bar)') -and
         ($codexShipReview -match '(?is)(outside the frozen scope|outside scope)') -and
         ($codexShipReview -match '(?is)Follow-ups') -and
         ($codexShipReview -match '(?is)never silently relabelled `?Non-blocking') -and
         ($codexShipReview -match '(?is)original source and severity')) `
        'below-bar items must keep source and severity, not become Non-blocking'
    Assert-That 'Codex ship-review uses one round counter and stops fix commits past the cap' `
        (($codexShipReview -match '(?is)one round counter') -and
         ($codexShipReview -match '(?is)Blocking') -and
         ($codexShipReview -match '(?is)coverage gaps') -and
         ($codexShipReview -match '(?is)mutation survivors') -and
         ($codexShipReview -match '(?is)no further fix commits')) `
        'Blocking and coverage/mutation routes share the cap; past it, no more fix commits'
    Assert-That 'Codex ship-review READY requires verify, three reviewers, empty Blocking, and no unresolved Critical/High' `
        (($codexShipReview -match '(?is)READY requires') -and
         ($codexShipReview -match '(?is)verify') -and
         ($codexShipReview -match '(?is)all three reviewers') -and
         ($codexShipReview -match '(?is)`?Blocking`? empty') -and
         ($codexShipReview -match '(?is)no unresolved Critical/?High') -and
         ($codexShipReview -notmatch '(?is)no unresolved confirmed Critical/?High') -and
         ($codexShipReview -match '(?is)regardless of bucket') -and
         ($codexShipReview -match '(?is)missing reviewer') -and
         ($codexShipReview -match 'NEEDS FIXES')) `
        'a missing reviewer or deferred Critical/High must keep NEEDS FIXES'
    Assert-That 'Codex ship-review correctness lane invokes $code-review over the rebase delta' `
        (($codexShipReview -match '(?is)Correctness & design') -and
         ($codexShipReview -match '(?is)\$code-review') -and
         ($codexShipReview -match '(?is)explicit diff range') -and
         ($codexShipReview -match '(?is)stage-9-cleared commit') -and
         ($codexShipReview -match '(?is)rebased head') -and
         ($codexShipReview -notmatch '(?is)Correctness & design \| `code-reviewer`')) `
        'the Codex copy must call $code-review, not a bare code-reviewer correctness row'
    Assert-That 'Claude ship-review correctness lane invokes /code-review over the rebase delta' `
        (($claudeShipReview -match '(?is)Correctness & design') -and
         ($claudeShipReview -match '(?is)/code-review') -and
         ($claudeShipReview -match '(?is)explicit diff range') -and
         ($claudeShipReview -match '(?is)stage-9-cleared commit') -and
         ($claudeShipReview -match '(?is)rebased head') -and
         ($claudeShipReview -notmatch '(?is)Correctness & design \| `code-reviewer`')) `
        'the Claude copy must call /code-review, not a bare code-reviewer correctness row'
    Assert-That 'ship-review records an empty rebase delta as a named confirmation' `
        (($codexShipReview -match '(?is)empty rebase delta') -and
         ($codexShipReview -match '(?is)confirmation') -and
         ($codexShipReview -match '(?is)not a skipped lane') -and
         ($claudeShipReview -match '(?is)empty rebase delta') -and
         ($claudeShipReview -match '(?is)confirmation') -and
         ($claudeShipReview -match '(?is)not a skipped lane')) `
        'an empty delta must still appear as a correctness confirmation, not a missing lane'
    Assert-That 'Codex ship-review does not invoke $code-review on an empty rebase delta' `
        (($codexShipReview -match '(?is)Determine whether the rebase delta') -and
         ($codexShipReview -match '(?is)do not invoke `?\$code-review') -and
         ($codexShipReview -match '(?is)non-empty') -and
         ($codexShipReview -match '(?is)explicit diff range')) `
        'an empty delta must short-circuit before $code-review, whose empty diff fails closed'
    Assert-That 'Claude ship-review does not invoke /code-review on an empty rebase delta' `
        (($claudeShipReview -match '(?is)Determine whether the rebase delta') -and
         ($claudeShipReview -match '(?is)do not invoke `?/code-review') -and
         ($claudeShipReview -match '(?is)non-empty') -and
         ($claudeShipReview -match '(?is)explicit diff range')) `
        'an empty delta must short-circuit before /code-review, whose empty diff fails closed'
    Assert-That 'ship-review short-circuits an empty rebase delta without invoking code-review' `
        (($codexShipReview -match '(?is)First determine whether the rebase delta is empty') -and
         ($codexShipReview -match '(?is)do not invoke `\$code-review`') -and
         ($codexShipReview -match '(?is)If non-empty') -and
         ($claudeShipReview -match '(?is)First determine whether the rebase delta is empty') -and
         ($claudeShipReview -match '(?is)do not invoke `/code-review`') -and
         ($claudeShipReview -match '(?is)If non-empty')) `
        'an empty delta must not be handed to /code-review, whose empty-diff pin fails'
    Assert-That 'ship-review keeps the stage-9-cleared commit in-session' `
        (($codexShipReview -match '(?is)in-session') -and
         ($codexShipReview -match '(?is)working tree') -and
         ($codexShipReview -match '(?is)receipt') -and
         ($claudeShipReview -match '(?is)in-session') -and
         ($claudeShipReview -match '(?is)working tree') -and
         ($claudeShipReview -match '(?is)receipt')) `
        'the fixed point must not be recovered from state written outside the working tree'
    Assert-That 'ship-review fails closed when the stage-9-cleared commit is missing or ambiguous' `
        (($codexShipReview -match '(?is)missing or ambiguous') -and
         ($codexShipReview -match '(?is)Could not run') -and
         ($codexShipReview -match 'NEEDS FIXES') -and
         ($claudeShipReview -match '(?is)missing or ambiguous') -and
         ($claudeShipReview -match '(?is)Could not run') -and
         ($claudeShipReview -match 'NEEDS FIXES')) `
        'a missing rebase-delta fixed point must be Could not run, not an unscoped review'
    $codexTestEngineer = Get-Content -LiteralPath (Join-Path $codexSkillsPath 'test-engineer/SKILL.md') -Raw
    $claudeTestEngineer = Get-Content -LiteralPath (Join-Path $repo '.claude/skills/test-engineer/SKILL.md') -Raw
    Assert-That 'Codex test-engineer names ship-review fan-out alongside $code-review' `
        (($codexTestEngineer -match '(?is)Invoked by') -and
         ($codexTestEngineer -match '(?is)\$ship-review') -and
         ($codexTestEngineer -match '(?is)alongside `\$code-review`') -and
         ($codexTestEngineer -notmatch '(?is)alongside `code-reviewer`')) `
        'the Codex copy must not keep a bare code-reviewer as a ship-review fan-out peer'
    Assert-That 'Claude test-engineer names ship-review fan-out alongside /code-review' `
        (($claudeTestEngineer -match '(?is)Invoked by') -and
         ($claudeTestEngineer -match '(?is)/ship-review') -and
         ($claudeTestEngineer -match '(?is)alongside `/code-review`') -and
         ($claudeTestEngineer -notmatch '(?is)alongside `code-reviewer`')) `
        'the Claude copy must not keep a bare code-reviewer as a ship-review fan-out peer'
    Assert-That 'Codex code-review fails closed when loop terms are missing' `
        (($codexCodeReview -match '(?is)FEATURE_DIR') -and
         ($codexCodeReview -match '(?is)check-prerequisites\.ps1') -and
         ($codexCodeReview -match '(?is)<FEATURE_DIR>/brief\.md') -and
         ($codexCodeReview -match '(?is)closing bar') -and
         ($codexCodeReview -match '(?is)frozen scope') -and
         ($codexCodeReview -match '(?is)round cap') -and
         ($codexCodeReview -match '(?is)Could not run') -and
         ($codexCodeReview -match 'NEEDS FIXES') -and
         ($codexCodeReview -match '(?is)before Step 1') -and
         ($codexCodeReview -match '(?is)fail closed') -and
         ($codexCodeReview -match '(?is)Do not infer defaults')) `
        'missing closing bar, frozen scope, or round cap must stop before fan-out'
    Assert-That 'Codex code-review accepts an explicit diff range' `
        (($codexCodeReview -match '(?is)explicit diff range') -and
         ($codexCodeReview -match '(?is)review only that range')) `
        'an explicit caller-supplied range must override the default fixed-point diff'
    Assert-That 'Codex code-review routes above-bar findings to $remediate and below-bar to Follow-ups' `
        (($codexCodeReview -match '(?is)Above the bar go to `?\$remediate') -and
         ($codexCodeReview -match '(?is)Below the bar') -and
         ($codexCodeReview -match '(?is)outside the frozen scope') -and
         ($codexCodeReview -match '(?is)Follow-ups') -and
         ($codexCodeReview -match '(?is)never silently relabelled `?Non-blocking') -and
         ($codexCodeReview -match '(?is)original source and severity')) `
        'above-bar findings must go to $remediate; below-bar items must keep source and severity, not become Non-blocking'
    Assert-That 'Codex code review documents a Markdown findings fallback' `
        (($codexCodeReview -match 'native structured-review or inline-comment mechanism') -and
         ($codexCodeReview -match '## Findings') -and
         ($codexCodeReview -match 'Never suppress the findings')) `
        'a review must still return its findings when the host exposes no structured review tool'
    Assert-That 'Claude code-review fails closed when loop terms are missing' `
        (($claudeCodeReview -match '(?is)FEATURE_DIR') -and
         ($claudeCodeReview -match '(?is)Could not run') -and
         ($claudeCodeReview -match 'NEEDS FIXES') -and
         ($claudeCodeReview -match '(?is)fail closed')) `
        'a Claude/Cursor skills-path copy must keep the fail-closed loop terms'
    Assert-That 'Claude code-review accepts an explicit diff range' `
        (($claudeCodeReview -match '(?is)explicit diff range') -and
         ($claudeCodeReview -match '(?is)review only that range')) `
        'an installer regression on .claude/skills must not drop the explicit-range rule'
    Assert-That 'Claude code-review routes above-bar findings to /remediate and below-bar to Follow-ups' `
        (($claudeCodeReview -match '(?is)Above the bar go to `?/remediate') -and
         ($claudeCodeReview -match '(?is)Below the bar') -and
         ($claudeCodeReview -match '(?is)Follow-ups') -and
         ($claudeCodeReview -match '(?is)never silently relabelled `?Non-blocking')) `
        'above-bar findings must go to /remediate on the Claude/Cursor skills path'
    Assert-That 'Claude address-pr-review keeps slash syntax, --dry-run, and approval-before-write' `
        (($claudeAddressPrReview -match '(?is)--dry-run') -and
         ($claudeAddressPrReview -match '(?is)/remediate') -and
         ($claudeAddressPrReview -match '(?is)/verify') -and
         ($claudeAddressPrReview -notmatch '(?is)\$remediate') -and
         ($claudeAddressPrReview -match '(?is)are \*\*data\*\*') -and
         ($claudeAddressPrReview -match '(?is)No edit, commit, push, or GitHub write')) `
        'stage 11 must reach approval with zero writes on --dry-run and must not execute PR text'
    Assert-That 'Codex address-pr-review delegates to $remediate and $verify' `
        (($codexAddressPrReview -match '(?is)\$remediate') -and
         ($codexAddressPrReview -match '(?is)\$verify') -and
         ($codexAddressPrReview -notmatch '(?is)/remediate') -and
         ($codexAddressPrReview -notmatch '(?is)/verify') -and
         ($codexAddressPrReview -match '(?is)--dry-run')) `
        'Codex adaptation must rewrite stage-11 handoffs to $name'
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
    Assert-That '-Platform codex generates only the Codex agent discovery tree' `
        ((@(Get-ChildItem -LiteralPath (Join-Path $repo '.codex/agents') -File -Filter '*.toml').Count -eq 7) -and
         (-not (Test-Path (Join-Path $repo '.claude/agents'))) -and
         (-not (Test-Path (Join-Path $repo '.cursor/agents'))))

    # Generated agents use per-file ownership rather than Copy-Tree. Foreign
    # same-name files are collisions, not permission to overwrite a directory.
    $repo = New-TargetRepo
    $repos += $repo
    $foreignAgents = @(
        (Join-Path $repo '.claude/agents/gate-runner.md')
        (Join-Path $repo '.cursor/agents/code-scout.md')
        (Join-Path $repo '.codex/agents/edit-applier.toml')
    )
    foreach ($path in $foreignAgents) {
        New-Item -ItemType Directory -Path (Split-Path $path -Parent) -Force | Out-Null
        Set-Content -LiteralPath $path -Value "consumer-owned: $([IO.Path]::GetFileName($path))" -Encoding UTF8
    }
    Set-Content -LiteralPath $foreignAgents[0] -Encoding UTF8 -Value @(
        '---'
        'name: gate-runner'
        '---'
        'Documentation may mention harnessGenerated: true without granting ownership.'
    )
    $foreignBefore = @($foreignAgents | ForEach-Object { ,([IO.File]::ReadAllBytes($_)) })
    $output = Invoke-Install -Repo $repo -Platform 'all'
    for ($i = 0; $i -lt $foreignAgents.Count; $i++) {
        Assert-That "unmarked agent collision $($i + 1) stays byte-identical" `
            ([System.Linq.Enumerable]::SequenceEqual($foreignBefore[$i], [IO.File]::ReadAllBytes($foreignAgents[$i])))
    }
    Assert-That 'agent collisions are reported without blocking other profiles' `
        (($output -match 'COLLISION') -and
         (Test-Path (Join-Path $repo '.claude/agents/code-scout.md')) -and
         (Test-Path (Join-Path $repo '.cursor/agents/gate-runner.md')) -and
         (Test-Path (Join-Path $repo '.codex/agents/code-scout.toml')))

    # An exact 0.2.0 profile is the sole unmarked migration exception.
    $repo = New-TargetRepo
    $repos += $repo
    $legacyPath = Join-Path $repo '.claude/agents/code-reviewer.md'
    New-Item -ItemType Directory -Path (Split-Path $legacyPath -Parent) -Force | Out-Null
    $legacy = Get-Content -LiteralPath (Join-Path $harnessRoot '.claude/agents/code-reviewer.md') -Raw
    $legacy = $legacy -replace '(?m)^tier: balanced\r?$', 'model: inherit'
    [IO.File]::WriteAllText($legacyPath, $legacy, [Text.UTF8Encoding]::new($false))
    $output = Invoke-Install -Repo $repo -Platform 'claude'
    $adopted = Get-Content -LiteralPath $legacyPath -Raw
    Assert-That 'exact v0.2.0 Claude profile is adopted and marked' `
        (($output -match 'ADOPTED') -and ($adopted -match '(?m)^harnessGenerated: true$'))

    $repo = New-TargetRepo
    $repos += $repo
    $modifiedLegacyPath = Join-Path $repo '.claude/agents/code-reviewer.md'
    New-Item -ItemType Directory -Path (Split-Path $modifiedLegacyPath -Parent) -Force | Out-Null
    [IO.File]::WriteAllText($modifiedLegacyPath, $legacy + "`nconsumer change`n", [Text.UTF8Encoding]::new($false))
    $before = [IO.File]::ReadAllBytes($modifiedLegacyPath)
    $output = Invoke-Install -Repo $repo -Platform 'claude'
    Assert-That 'modified v0.2.0 profile remains consumer-owned' `
        (($output -match 'COLLISION') -and
         [System.Linq.Enumerable]::SequenceEqual($before, [IO.File]::ReadAllBytes($modifiedLegacyPath)))

    # Consumer tier overrides render through every selected host.
    $repo = New-TargetRepo
    $repos += $repo
    Set-Content -LiteralPath (Join-Path $repo 'harness.yml') -Encoding UTF8 -Value @(
        'agents:'
        '  tiers:'
        '    fast:'
        '      claude:'
        '        model: custom-claude'
        '        effort: high'
        '      cursor:'
        '        model: custom-cursor'
        '        effort: medium'
        '      codex:'
        '        model: custom-codex'
        '        effort: xhigh'
    )
    Invoke-Install -Repo $repo -Platform 'all' | Out-Null
    Assert-That 'configured fast tier renders into all host copies' `
        (((Get-Content -LiteralPath (Join-Path $repo '.claude/agents/gate-runner.md') -Raw) -match '(?m)^model: custom-claude$') -and
         ((Get-Content -LiteralPath (Join-Path $repo '.cursor/agents/gate-runner.md') -Raw) -match '(?m)^model: custom-cursor\[effort=medium\]$') -and
         ((Get-Content -LiteralPath (Join-Path $repo '.codex/agents/gate-runner.toml') -Raw) -match '(?m)^model = "custom-codex"$'))

    $repo = New-TargetRepo
    $repos += $repo
    $legacyConfigPath = Join-Path $repo 'harness.yml'
    Set-Content -LiteralPath $legacyConfigPath -Encoding UTF8 -Value @(
        'harnessVersion: 0.2.0'
        'agents:'
        '  tiers:'
        '    fast:'
        '      claude: inherit'
    )
    $output = Invoke-Install -Repo $repo -Platform 'claude'
    $installExit = $LASTEXITCODE
    $legacyConfig = Get-Content -LiteralPath $legacyConfigPath -Raw
    $normalizedOutput = [regex]::Replace($output, '[\r\n]+(?:\s+\|)?\s*', ' ')
    $c1Exit = $installExit -eq 1
    $c1Phrase = [bool]($normalizedOutput -match 'legacy scalar agent tier')
    $c2Guidance = [bool]($normalizedOutput -match "nest 'model:' and 'effort:'")
    $c3Preserved = [bool]($legacyConfig -match '(?m)^harnessVersion: 0\.2\.0\r?$')
    $c4Unstamped = [bool]($legacyConfig -notmatch '(?m)^harnessVersion: 0\.3\.0\r?$')
    Assert-That 'legacy scalar config is rejected by the parser (exit 1 and phrase)' `
        ($c1Exit -and $c1Phrase) `
        ("exit=$installExit expected=1; phrase-match=$c1Phrase")
    Assert-That 'legacy scalar error includes migration guidance after normalisation' `
        $c2Guidance `
        "normalised output did not contain nest 'model:' and 'effort:'"
    Assert-That 'legacy scalar config keeps harnessVersion 0.2.0' `
        $c3Preserved `
        'harness.yml no longer has harnessVersion: 0.2.0'
    Assert-That 'legacy scalar config is not stamped to harnessVersion 0.3.0' `
        $c4Unstamped `
        'harness.yml was stamped with harnessVersion: 0.3.0'

    # ── Codex adapter: consumer-owned files already exist ────────────────────
    # Deliberately NOT the append treatment CLAUDE.md gets. Eleven @import lines are a
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
         (-not (Test-Path (Join-Path $repo '.codex/agents'))) -and
         (-not (Test-Path (Join-Path $repo '.codex/hooks.json'))) -and
         (-not (Test-Path (Join-Path $repo '.codex/config.toml')))) `
        'both means cursor + claude; widening it would change what a pinned flag does'
    Assert-That '-Platform both generates Claude and Cursor agent profiles' `
        ((@(Get-ChildItem -LiteralPath (Join-Path $repo '.claude/agents') -File -Filter '*.md').Count -eq 7) -and
         (@(Get-ChildItem -LiteralPath (Join-Path $repo '.cursor/agents') -File -Filter '*.md').Count -eq 7))
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
