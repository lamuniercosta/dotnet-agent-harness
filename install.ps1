#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Installs dotnet-agent-harness into an existing repository.

.DESCRIPTION
  Adopt-first: this adds the harness to a repo that already exists. `new-project.sh`
  scaffolds a solution and then calls this same script, so there is one code path.

  Nothing is clobbered. Files the harness owns (skills, agents, rules, hooks, gate
  scripts) are refreshed on every run. Files the REPO owns (Directory.Build.props,
  .editorconfig, harness.yml) are created if absent and otherwise left alone and
  reported, so you can merge by hand.

  Thresholds are rendered from harness.yml into the tool configs that consume them,
  so a threshold lives in exactly one place.

.PARAMETER TargetRepo
  Repository to install into. Defaults to the current directory.

.PARAMETER Platform
  Which agent platform(s) to wire: cursor, claude, or both (default).
  Skills and agents are shared regardless; this only affects the adapters.

.EXAMPLE
  pwsh ./install.ps1 F:\Dev\MyApi -WhatIf
  pwsh ./install.ps1 F:\Dev\MyApi -Platform claude
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Position = 0)]
    [string]$TargetRepo = '.',

    [ValidateSet('cursor', 'claude', 'both')]
    [string]$Platform = 'both',

    [switch]$Help
)

$ErrorActionPreference = 'Stop'

if ($Help) {
    Get-Help $PSCommandPath -Detailed
    exit 0
}

$harnessRoot = $PSScriptRoot
$packScripts = Join-Path $harnessRoot 'packs/dotnet/scripts'
$packTemplates = Join-Path $harnessRoot 'packs/dotnet/templates'

# _gate-common.ps1, not _harness-config.ps1 directly: config resolution falls
# back to Resolve-BaseRef when harness.yml omits baseBranch, and that lives in
# gate-common. Sourcing only the config reader leaves that path undefined - it
# stays hidden on a normal install (the copied harness.yml sets baseBranch) and
# fails under -WhatIf, where the copy is skipped.
. (Join-Path $packScripts '_gate-common.ps1')

if (-not (Test-Path $TargetRepo)) { throw "Target repo not found: $TargetRepo" }
$TargetRepo = (Resolve-Path $TargetRepo).Path

if ($TargetRepo -eq $harnessRoot) {
    throw 'Refusing to install the harness into itself. Pass a target repository.'
}

$results = @()
function Add-Result {
    param([string]$Item, [string]$Status, [string]$Note = '')
    $script:results += [PSCustomObject]@{ Item = $Item; Status = $Status; Note = $Note }
}

function Copy-Tree {
    <# Mirrors a directory the harness owns. Refreshed every run. #>
    param([string]$Source, [string]$Dest, [string]$Label)

    if (-not (Test-Path $Source)) {
        Add-Result $Label 'MISSING' "not found: $Source"
        return
    }
    if ($PSCmdlet.ShouldProcess($Dest, "sync $Label")) {
        New-Item -ItemType Directory -Force -Path $Dest | Out-Null
        Copy-Item (Join-Path $Source '*') $Dest -Recurse -Force
    }
    $count = @(Get-ChildItem $Source -Recurse -File).Count
    Add-Result $Label 'SYNCED' "$count files"
}

# ── 1. harness.yml — the repo owns its settings, the harness owns the version ─
$harnessVersion = (Get-Content -LiteralPath (Join-Path $harnessRoot 'VERSION') -Raw).Trim()
$harnessFile = Join-Path $TargetRepo 'harness.yml'

if (Test-Path $harnessFile) {
    # Settings are the repo's; the version stamp is ours. Rewriting only that
    # one line means an upgrade is visible without touching anyone's thresholds.
    $existing = Get-Content -LiteralPath $harnessFile
    $previous = ($existing | Select-String -Pattern '^harnessVersion:\s*(.+)$').Matches.Groups[1].Value

    if ($previous -eq $harnessVersion) {
        Add-Result 'harness.yml' 'OK' "already at $harnessVersion - your settings untouched"
    }
    else {
        if ($existing -match '^harnessVersion:') {
            $updated = $existing -replace '^harnessVersion:.*$', "harnessVersion: $harnessVersion"
        }
        else {
            $updated = @("harnessVersion: $harnessVersion") + $existing
        }
        if ($PSCmdlet.ShouldProcess($harnessFile, 'stamp harness version')) {
            Set-Content -LiteralPath $harnessFile -Value $updated -Encoding UTF8
        }
        $from = if ($previous) { $previous } else { 'unversioned' }
        Add-Result 'harness.yml' 'UPGRADED' "$from -> $harnessVersion (settings untouched)"
    }
}
else {
    if ($PSCmdlet.ShouldProcess($harnessFile, 'create from example')) {
        Copy-Item (Join-Path $harnessRoot 'harness.yml.example') $harnessFile
    }
    Add-Result 'harness.yml' 'ADDED' "v$harnessVersion - edit thresholds here, not the tool configs"
}

# Read config from the TARGET repo (defaults apply when -WhatIf skipped the copy).
$config = Get-HarnessConfig -RepoRoot $TargetRepo

# ── 2. Shared assets — ONE copy of everything ────────────────────────────────
#
# Nothing here is written twice. Two copies of a file inside a consumer repo is
# the same drift this harness exists to end, just one level down: nothing stops
# an edit to one from silently diverging from the other.
#
# Skills and agents live under .claude/ because Cursor reads BOTH natively -
# its docs: "For compatibility, Cursor also loads skills from Claude and Codex
# directories: .claude/skills/, .codex/skills/". Rules live under .cursor/
# because only Cursor can auto-load them by glob; Claude reaches them through
# CLAUDE.md @imports pointing at the same path.
#
# So a Claude-only install still has a .cursor/rules/ directory, and a
# Cursor-only install still has .claude/skills/. Cosmetically odd, structurally
# correct: one file, one home, no generated duplicates.

Copy-Tree (Join-Path $harnessRoot 'skills') (Join-Path $TargetRepo '.claude/skills') 'skills -> .claude/skills (both platforms read this)'
Copy-Tree (Join-Path $harnessRoot '.claude/agents') (Join-Path $TargetRepo '.claude/agents') 'agents -> .claude/agents (both platforms read this)'
Copy-Tree (Join-Path $harnessRoot 'hooks') (Join-Path $TargetRepo 'scripts/hooks') 'hooks -> scripts/hooks'

Copy-Tree (Join-Path $harnessRoot 'rules/pipeline') (Join-Path $TargetRepo '.cursor/rules') 'rules -> .cursor/rules (Claude @imports these)'

# The vendored glob-scoped rules are the ONE thing written twice, and only
# because both platforms have native glob loading from DIFFERENT directories
# with DIFFERENT keys:
#
#   Cursor        .cursor/rules/vendor/*.md   `globs:`
#   Claude Code   .claude/rules/vendor/*.md   `paths:`
#
# Cursor does not read .claude/rules, so a single copy cannot serve both. Each
# file carries both keys and each platform reads its own. Both copies are
# regenerated from rules/vendor/ on every install, so they cannot drift apart
# here - only in a consumer who hand-edits one, which the header warns against.
#
# The alternative was wrapper skills relying on description matching, which is
# strictly weaker than a glob guarantee.
Copy-Tree (Join-Path $harnessRoot 'rules/vendor') (Join-Path $TargetRepo '.cursor/rules/vendor') 'vendor rules -> .cursor/rules/vendor (globs:)'
Copy-Tree (Join-Path $harnessRoot 'rules/vendor') (Join-Path $TargetRepo '.claude/rules/vendor') 'vendor rules -> .claude/rules/vendor (paths:)'

# A Claude-only user has every reason to assume .cursor/ is another editor's
# config and delete it - which silently breaks all ten CLAUDE.md imports with no
# error, just rules that stop arriving. Leave a note in the directory itself.
if ($PSCmdlet.ShouldProcess((Join-Path $TargetRepo '.cursor/rules/README.md'), 'explain the shared rules directory')) {
    Copy-Item (Join-Path $harnessRoot 'adapters/cursor/rules-README.md') (Join-Path $TargetRepo '.cursor/rules/README.md') -Force
}

# ── 3. Per-platform adapters — the only genuinely divergent files ────────────
if ($Platform -in @('cursor', 'both')) {
    if ($PSCmdlet.ShouldProcess((Join-Path $TargetRepo '.cursor'), 'install cursor adapter')) {
        New-Item -ItemType Directory -Force -Path (Join-Path $TargetRepo '.cursor') | Out-Null
        Copy-Item (Join-Path $harnessRoot 'adapters/cursor/hooks.json') (Join-Path $TargetRepo '.cursor/hooks.json') -Force
    }
    Add-Result '.cursor/hooks.json' 'SYNCED' 'hook wiring'

    $cursorMcp = Join-Path $TargetRepo '.cursor/mcp.json'
    if (Test-Path $cursorMcp) {
        Add-Result '.cursor/mcp.json' 'SKIPPED' 'already exists - merge the two documentation servers by hand'
    }
    else {
        if ($PSCmdlet.ShouldProcess($cursorMcp, 'install MCP config')) {
            Copy-Item (Join-Path $harnessRoot 'adapters/cursor/mcp.json') $cursorMcp -Force
        }
        Add-Result '.cursor/mcp.json' 'ADDED' 'microsoft-learn + context7'
    }
}

if ($Platform -in @('claude', 'both')) {
    if ($PSCmdlet.ShouldProcess((Join-Path $TargetRepo '.claude/settings.json'), 'install claude settings')) {
        New-Item -ItemType Directory -Force -Path (Join-Path $TargetRepo '.claude') | Out-Null
        Copy-Item (Join-Path $harnessRoot 'adapters/claude/settings.json') (Join-Path $TargetRepo '.claude/settings.json') -Force
    }
    Add-Result '.claude/settings.json' 'SYNCED' 'permissions + hook wiring'

    # CLAUDE.md is the repo's own front page - never clobber it. When one exists,
    # report what to add rather than overwriting someone's instructions.
    $claudeMd = Join-Path $TargetRepo 'CLAUDE.md'
    if (Test-Path $claudeMd) {
        Add-Result 'CLAUDE.md' 'SKIPPED' 'exists - add the @imports from adapters/claude/CLAUDE.md by hand'
    }
    else {
        if ($PSCmdlet.ShouldProcess($claudeMd, 'install CLAUDE.md')) {
            Copy-Item (Join-Path $harnessRoot 'adapters/claude/CLAUDE.md') $claudeMd -Force
        }
        Add-Result 'CLAUDE.md' 'ADDED' 'imports the rules from .cursor/rules'
    }

    # Claude Code reads MCP config from .mcp.json at the REPO ROOT, not .claude/.
    $mcpDest = Join-Path $TargetRepo '.mcp.json'
    if (Test-Path $mcpDest) {
        Add-Result '.mcp.json' 'SKIPPED' 'already exists - merge the two documentation servers by hand'
    }
    else {
        if ($PSCmdlet.ShouldProcess($mcpDest, 'install MCP config')) {
            Copy-Item (Join-Path $harnessRoot 'adapters/claude/mcp.json') $mcpDest -Force
        }
        Add-Result '.mcp.json' 'ADDED' 'microsoft-learn + context7'
    }
}

# ── 4. Gate scripts + analyzer wiring (delegates to the pack installer) ──────
if ($PSCmdlet.ShouldProcess($TargetRepo, 'install gate scripts')) {
    & (Join-Path $packScripts 'install-gates.ps1') $TargetRepo | Out-Null
}
Add-Result 'gate scripts + analyzer wiring' 'SYNCED' 'via packs/dotnet/scripts/install-gates.ps1'

# Ship the harness.yml reader alongside the gate scripts it serves.
if ($PSCmdlet.ShouldProcess($TargetRepo, 'install harness config reader')) {
    Copy-Item (Join-Path $packScripts '_harness-config.ps1') (Join-Path $TargetRepo 'scripts/_harness-config.ps1') -Force
    Copy-Item (Join-Path $packScripts 'run-vulnerable-packages.ps1') (Join-Path $TargetRepo 'scripts/') -Force -ErrorAction SilentlyContinue
    Copy-Item (Join-Path $packScripts 'new-task-branch.ps1') (Join-Path $TargetRepo 'scripts/') -Force
    Copy-Item (Join-Path $packScripts 'rebase-task-branch.ps1') (Join-Path $TargetRepo 'scripts/') -Force
}

# ── 5. Render thresholds from harness.yml into the configs that consume them ─
# This is the point of the manifest: one edit, several consumers, no drift.

# 5a. CodeMetricsConfig.txt — CA1502 ceiling
$metricsFile = Join-Path $TargetRepo 'CodeMetricsConfig.txt'
$metricsBody = "CA1502: $($config['gates.complexity.implement'])"
if ($PSCmdlet.ShouldProcess($metricsFile, 'render CA1502 threshold')) {
    Set-Content -LiteralPath $metricsFile -Value $metricsBody -Encoding UTF8 -NoNewline
}
Add-Result 'CodeMetricsConfig.txt' 'RENDERED' "CA1502: $($config['gates.complexity.implement'])"

# 5b. stryker-config.json — mutation threshold
$strykerFile = Join-Path $TargetRepo 'stryker-config.json'
$breakAt = $config['gates.mutation.threshold']
$stryker = [ordered]@{
    'stryker-config' = [ordered]@{
        'mutation-level' = 'Standard'
        'since'          = [ordered]@{ 'target' = $config['baseBranch'] }
        'thresholds'     = [ordered]@{
            'high'  = [Math]::Min(100, $breakAt + 10)
            'low'   = $breakAt
            'break' = $breakAt
        }
        'reporters'      = @('progress', 'html', 'json')
    }
}
if ($config['solution']) {
    $rel = [System.IO.Path]::GetRelativePath($TargetRepo, $config['solution']).Replace('\', '/')
    $stryker['stryker-config']['solution'] = $rel
}
if ($PSCmdlet.ShouldProcess($strykerFile, 'render mutation threshold')) {
    $stryker | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $strykerFile -Encoding UTF8
}
Add-Result 'stryker-config.json' 'RENDERED' "break at $breakAt%"

# 5c. Directory.Build.props — AnalysisMode gates the security CA families
$propsFile = Join-Path $TargetRepo 'Directory.Build.props'
if (Test-Path $propsFile) {
    $props = Get-Content -LiteralPath $propsFile -Raw
    $mode = $config['gates.analyzers.mode']
    $waeValue = if ($config['gates.analyzers.warningsAsErrors']) { 'true' } else { 'false' }
    $updated = $props

    if ($updated -match '<AnalysisMode>') {
        $updated = $updated -replace '<AnalysisMode>.*?</AnalysisMode>', "<AnalysisMode>$mode</AnalysisMode>"
    }
    if ($updated -match '<TreatWarningsAsErrors>') {
        $updated = $updated -replace '<TreatWarningsAsErrors>.*?</TreatWarningsAsErrors>', "<TreatWarningsAsErrors>$waeValue</TreatWarningsAsErrors>"
    }

    if ($props -notmatch '<AnalysisMode>') {
        Add-Result 'Directory.Build.props' 'MANUAL' "add <AnalysisMode>$mode</AnalysisMode> - the security CA rules are off without it"
    }
    elseif ($updated -ne $props) {
        if ($PSCmdlet.ShouldProcess($propsFile, 'render analyzer settings')) {
            Set-Content -LiteralPath $propsFile -Value $updated -Encoding UTF8 -NoNewline
        }
        Add-Result 'Directory.Build.props' 'RENDERED' "AnalysisMode=$mode, TreatWarningsAsErrors=$waeValue"
    }
    else {
        Add-Result 'Directory.Build.props' 'OK' "AnalysisMode=$mode, TreatWarningsAsErrors=$waeValue"
    }
}

# ── 5d. Spec Kit extension ───────────────────────────────────────────────────
# The 15-line file is the entire coupling between this harness and Spec Kit.
# Without it the pipeline chaining (analyze -> refactor -> architect) never
# fires, and nothing would report that: the stages simply would not run.
#
# .specify/ only exists after `specify init`, so when it is absent this reports
# the exact command rather than creating a directory Spec Kit will overwrite.
$specifyDir = Join-Path $TargetRepo '.specify'
$extensionsSrc = Join-Path $harnessRoot 'speckit/extensions.yml'

if (Test-Path $specifyDir) {
    $extensionsDest = Join-Path $specifyDir 'extensions.yml'
    if ($PSCmdlet.ShouldProcess($extensionsDest, 'install Spec Kit extension')) {
        Copy-Item $extensionsSrc $extensionsDest -Force
    }
    Add-Result '.specify/extensions.yml' 'SYNCED' 'pipeline chaining into Spec Kit'
}
else {
    Add-Result '.specify/extensions.yml' 'PENDING' 'run `specify init` first, then re-run install.ps1'
}

# ── 5e. CONTEXT.md — the project's ubiquitous language ───────────────────────
# Referenced by the constitution, CLAUDE.md, and /grill-with-docs. Without it
# those are dangling pointers on day one. Seeded once, never overwritten - a
# real glossary must never be clobbered by a re-install.
$contextFile = Join-Path $TargetRepo 'CONTEXT.md'
if (Test-Path $contextFile) {
    Add-Result 'CONTEXT.md' 'SKIPPED' 'already exists - your glossary is safe'
}
else {
    $contextSeed = @'
# Project vocabulary

The canonical terms for this codebase. Use these words in code, specs, commits,
and conversation; when a term here and the code disagree, one of them is wrong.

`/grill-with-docs` populates this during the alignment stage - it is the output
of settling what things are called, not a form to fill in up front. Add a term
when a discussion reveals two names for one concept, or one name for two.

Format: the term, what it means here, and the names it displaces. The
`_Avoid_:` line matters most - it is what stops the old name creeping back.

---

**Work Item**
A single unit of asynchronous processing, tracked from acceptance through
completion or failure.
_Avoid_: Job, task, message

<!-- Replace the example above with your first real term. -->
'@
    if ($PSCmdlet.ShouldProcess($contextFile, 'seed CONTEXT.md')) {
        Set-Content -LiteralPath $contextFile -Value $contextSeed -Encoding UTF8
    }
    Add-Result 'CONTEXT.md' 'ADDED' 'populated by /grill-with-docs'
}

# ── 6. Report ────────────────────────────────────────────────────────────────
Write-Output ''
Write-Output "dotnet-agent-harness v$harnessVersion -> $TargetRepo   (platform: $Platform)"
Write-Output ''
$results | Format-Table -AutoSize Item, Status, Note | Out-String | Write-Output

$needsAttention = @($results | Where-Object { $_.Status -in @('SKIPPED', 'MANUAL', 'MISSING') })
if ($needsAttention.Count -gt 0) {
    Write-Output 'Some files were left for you to reconcile (listed above).'
    Write-Output 'Confirm the gates are genuinely wired - a gate that is not wired exits 1'
    Write-Output 'rather than reporting a pass it did not earn:'
    Write-Output '  ./scripts/run-cyclomatic-complexity.ps1 -All'
    Write-Output ''
}

Write-Output 'Next:'
Write-Output '  dotnet tool restore                       # provisions jb + stryker'
Write-Output '  specify init --here --integration claude   # or --integration cursor-agent'
Write-Output '  /task <issue>                             # start the pipeline'
