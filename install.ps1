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

function Get-MarkdownSection {
    <#
    Returns the lines of one `## Heading` section, heading included, up to the
    next heading at the same level or above. Used to lift the always-on rule
    imports out of the Claude adapter so that list lives in exactly one place.
    Returns an empty array when the heading is absent - callers must treat that
    as a failure rather than as an empty section.
    #>
    param([string]$Path, [string]$Heading)

    if (-not (Test-Path $Path)) { return @() }

    $lines = @(Get-Content -LiteralPath $Path)
    $start = -1

    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim() -eq $Heading) { $start = $i; break }
    }
    if ($start -lt 0) { return @() }

    $section = @($lines[$start])
    for ($j = $start + 1; $j -lt $lines.Count; $j++) {
        if ($lines[$j] -match '^#{1,2} ') { break }
        $section += $lines[$j]
    }

    while ($section.Count -gt 1 -and $section[-1] -match '^\s*$') {
        $section = @($section[0..($section.Count - 2)])
    }
    return $section
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
        # -Force on the source glob: on Linux a `*` wildcard skips dot-prefixed
        # files, which PowerShell classes as hidden there. Without it a dotfile
        # inside any synced tree would be silently dropped on non-Windows.
        Copy-Item (Join-Path $Source '*') $Dest -Recurse -Force
        Get-ChildItem $Source -Force -File -Recurse |
            Where-Object { $_.Name.StartsWith('.') } |
            ForEach-Object {
                $rel = $_.FullName.Substring($Source.Length).TrimStart('\', '/')
                $target = Join-Path $Dest $rel
                New-Item -ItemType Directory -Force -Path (Split-Path $target -Parent) | Out-Null
                Copy-Item $_.FullName $target -Force
            }
    }
    $count = @(Get-ChildItem $Source -Recurse -File -Force).Count
    Add-Result $Label 'SYNCED' "$count files"
}

# ── 1. harness.yml — the repo owns its settings, the harness owns the version ─
$harnessVersion = (Get-Content -LiteralPath (Join-Path $harnessRoot 'VERSION') -Raw).Trim()
$harnessFile = Join-Path $TargetRepo 'harness.yml'

if (Test-Path $harnessFile) {
    # Settings are the repo's; the version stamp is ours. Rewriting only that
    # one line means an upgrade is visible without touching anyone's thresholds.
    $existing = Get-Content -LiteralPath $harnessFile
    # A harness.yml predating version stamping has no harnessVersion line at all,
    # so Select-String returns nothing and reading .Matches on it throws under
    # Set-StrictMode. The branch below already handles the absent line - this just
    # has to reach it, with $previous left null so the versions compare unequal.
    $stamp = $existing | Select-String -Pattern '^harnessVersion:\s*(.+)$' | Select-Object -First 1
    $previous = if ($stamp) { $stamp.Matches.Groups[1].Value } else { $null }

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

    # CLAUDE.md is the repo's own front page - never clobber it. But skipping it
    # entirely is not harmless either: rules live in .cursor/rules because only
    # Cursor auto-loads them by glob, and Claude Code reaches them ONLY through
    # these @imports. A repo that already had a CLAUDE.md therefore loaded no
    # harness rules at all on Claude Code, silently - the manual note this used to
    # print was never acted on in either repo that adopted the harness.
    #
    # So the import block is appended rather than reported. Their content is
    # untouched and the addition is reversible, which is the same trade-off
    # already made for .editorconfig in install-gates.ps1.
    $claudeMd = Join-Path $TargetRepo 'CLAUDE.md'
    $adapterClaudeMd = Join-Path $harnessRoot 'adapters/claude/CLAUDE.md'

    if (-not (Test-Path $claudeMd)) {
        if ($PSCmdlet.ShouldProcess($claudeMd, 'install CLAUDE.md')) {
            Copy-Item $adapterClaudeMd $claudeMd -Force
        }
        Add-Result 'CLAUDE.md' 'ADDED' 'imports the rules from .cursor/rules'
    }
    elseif ((Get-Content -LiteralPath $claudeMd -Raw) -match '(?m)^@\.cursor/rules/') {
        Add-Result 'CLAUDE.md' 'SKIPPED' 'imports already present - your instructions untouched'
    }
    else {
        # Parsed out of the adapter rather than hardcoded here, so the list of
        # rules exists in one place. lint-harness already verifies every import in
        # that file resolves, which now guards the appended copy too.
        $block = Get-MarkdownSection -Path $adapterClaudeMd -Heading '## Always-on rules'
        $importCount = @($block | Where-Object { $_ -match '^@\.cursor/rules/' }).Count

        if ($importCount -eq 0) {
            Add-Result 'CLAUDE.md' 'MANUAL' "could not read the import block from $adapterClaudeMd - add it by hand"
        }
        else {
            if ($PSCmdlet.ShouldProcess($claudeMd, 'append the always-on rule imports')) {
                Add-Content -LiteralPath $claudeMd -Value (@('') + $block) -Encoding UTF8
            }
            Add-Result 'CLAUDE.md' 'APPENDED' "$importCount rule imports - existing content untouched"
        }
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
# This file is the entire coupling between this harness and Spec Kit. Without it
# the pipeline chaining (grill-with-docs -> analyze -> refactor) never fires, and
# nothing would report that: the stages simply would not run. The final stage,
# /architect, is chained by the refactor skill's own handoff, because Spec Kit
# emits no `after_refactor` event - see the note in speckit/extensions.yml.
#
# .specify/ only exists after `specify init`, so when it is absent this reports
# the exact command rather than creating a directory Spec Kit will overwrite.
$specifyDir = Join-Path $TargetRepo '.specify'
$extensionsSrc = Join-Path $harnessRoot 'speckit/extensions.yml'

# This file is shared territory. `specify init` writes it, and every registered
# Spec Kit extension records its hooks in it - the bundled `git` extension alone
# registers six. Overwriting it unconditionally would silently disable them, so
# the file is only written when there is demonstrably nothing to lose:
#
#   pristine  - `installed` and `hooks` both empty, as `specify init` leaves it
#   ours      - every hook entry carries `extension: harness-pipeline`
#   otherwise - reported for manual merge, left untouched
#
# Detection is textual, using the same minimal-YAML approach as the rest of the
# harness. It is deliberately biased towards reporting MANUAL: an unusual but
# valid formulation reads as foreign and is left alone, which is the safe way to
# be wrong about someone else's file.

# Returns the body lines of a top-level `key:` block, or $null if absent.
function Get-YamlTopLevelBlock {
    param([string[]]$Lines, [string]$Key)

    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -notmatch "^$Key\s*:") { continue }

        $block = @($Lines[$i])
        for ($j = $i + 1; $j -lt $Lines.Count; $j++) {
            # A non-indented, non-blank line ends the block.
            if ($Lines[$j] -match '^\S') { break }
            $block += $Lines[$j]
        }
        # Trailing blank lines belong to the gap, not the block.
        while ($block.Count -gt 1 -and $block[-1] -match '^\s*$') {
            $block = @($block[0..($block.Count - 2)])
        }
        # Returned bare: a one-line block unrolls to a string, which every caller
        # restores with @(). Wrapping HERE as well would nest it one level deep -
        # verified: @(f) where f returns `, $arr` yields a single element that is
        # itself an array, and `-match` against an array silently becomes a filter
        # that never populates $Matches.
        return $block
    }
    return $null
}

# True when `key:` is present-but-empty (`[]`, `{}`) or absent entirely.
function Test-YamlKeyEmpty {
    param([string[]]$Lines, [string]$Key)

    $block = @(Get-YamlTopLevelBlock -Lines $Lines -Key $Key)
    if ($block.Count -eq 0 -or $null -eq $block[0]) { return $true }

    if ($block[0] -match "^$Key\s*:\s*(.*)$") {
        $inline = $Matches[1].Trim()
        if ($inline -eq '[]' -or $inline -eq '{}') { return $true }
        if ($inline) { return $false }
    }
    # No inline value: empty only if nothing but blanks and comments follow.
    # A one-line block has no body at all, so it is empty by definition - and
    # indexing 1..0 would silently walk backwards rather than yield nothing.
    if ($block.Count -le 1) { return $true }
    foreach ($line in $block[1..($block.Count - 1)]) {
        if ($line -notmatch '^\s*$' -and $line -notmatch '^\s*#') { return $false }
    }
    return $true
}

if (Test-Path $specifyDir) {
    $extensionsDest = Join-Path $specifyDir 'extensions.yml'

    if (-not (Test-Path $extensionsDest)) {
        if ($PSCmdlet.ShouldProcess($extensionsDest, 'install Spec Kit extension')) {
            Copy-Item $extensionsSrc $extensionsDest -Force
        }
        Add-Result '.specify/extensions.yml' 'ADDED' 'pipeline chaining into Spec Kit'
    }
    else {
        $existing = @(Get-Content -LiteralPath $extensionsDest)

        $declared = @($existing |
            ForEach-Object { if ($_ -match '^\s*-?\s*extension\s*:\s*(\S+)') { $Matches[1] } })
        $isOurs = $declared.Count -gt 0 -and
                  @($declared | Where-Object { $_ -ne 'harness-pipeline' }).Count -eq 0

        $isPristine = (Test-YamlKeyEmpty -Lines $existing -Key 'installed') -and
                      (Test-YamlKeyEmpty -Lines $existing -Key 'hooks')

        if ($isOurs -or $isPristine) {
            # Carry the repo's own `installed` and `settings` across. They are
            # Spec Kit's to manage, not ours: `installed` is the extension
            # lifecycle list, and `settings.auto_execute_hooks` is a switch the
            # user may have deliberately turned off.
            $rendered = @(Get-Content -LiteralPath $extensionsSrc)
            foreach ($key in @('installed', 'settings')) {
                $theirs = @(Get-YamlTopLevelBlock -Lines $existing -Key $key)
                $ours = @(Get-YamlTopLevelBlock -Lines $rendered -Key $key)
                if ($theirs.Count -eq 0 -or $ours.Count -eq 0) { continue }
                if ($null -eq $theirs[0] -or $null -eq $ours[0]) { continue }

                $at = [Array]::IndexOf($rendered, $ours[0])
                if ($at -lt 0) { continue }
                $before = if ($at -gt 0) { $rendered[0..($at - 1)] } else { @() }
                $afterAt = $at + $ours.Count
                $after = if ($afterAt -lt $rendered.Count) { $rendered[$afterAt..($rendered.Count - 1)] } else { @() }
                $rendered = @($before) + @($theirs) + @($after)
            }

            if ($PSCmdlet.ShouldProcess($extensionsDest, 'install Spec Kit extension')) {
                Set-Content -LiteralPath $extensionsDest -Value $rendered -Encoding UTF8
            }
            $why = if ($isOurs) { 'refreshed' } else { 'was pristine' }
            Add-Result '.specify/extensions.yml' 'SYNCED' "pipeline chaining into Spec Kit ($why)"
        }
        else {
            $foreign = @($declared | Where-Object { $_ -ne 'harness-pipeline' } | Select-Object -Unique) -join ', '
            $whose = if ($foreign) { "hooks from: $foreign" } else { 'hooks or extensions this harness does not own' }
            Add-Result '.specify/extensions.yml' 'MANUAL' "left alone - it carries $whose; merge speckit/extensions.yml by hand"
        }
    }
}
else {
    Add-Result '.specify/extensions.yml' 'PENDING' 'run `specify init` first, then re-run install.ps1'
}

# ── 5e. Constitution — the project's non-negotiables ─────────────────────────
# Read by /implement and referenced by the pipeline, so a repo without one has a
# dangling pointer. Rendered only when ABSENT: a real constitution is the
# project's own law and outranks anything shipped here.
#
# The template is stack-neutral by CI contract (lint-harness rejects hardcoded
# stack names), so only three substitutions are needed. STACK_CONSTRAINTS is
# dropped rather than filled - the same treatment the lint gives it - because
# the stack is the project's to declare, not the installer's to guess.
function Get-TargetFrameworkLabel {
    <#
    Most common TargetFramework across the repo, ties broken by the highest.
    Returns $null when nothing declares one, so the caller can say so rather
    than writing a guess into a governance document.
    #>
    param([string]$Repo)

    $files = @(Join-Path $Repo 'Directory.Build.props') +
             @(Get-ChildItem -LiteralPath $Repo -Recurse -File -Filter *.csproj -ErrorAction SilentlyContinue |
                 Where-Object { $_.FullName -notmatch '\\(bin|obj)\\' } |
                 Select-Object -ExpandProperty FullName)

    $found = @()
    foreach ($f in $files) {
        if (-not (Test-Path $f)) { continue }
        foreach ($m in [regex]::Matches((Get-Content -LiteralPath $f -Raw), '<TargetFrameworks?>([^<]+)</')) {
            $found += ($m.Groups[1].Value -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        }
    }
    if ($found.Count -eq 0) { return $null }

    $tfm = $found |
        Group-Object |
        Sort-Object @{ Expression = 'Count'; Descending = $true }, @{ Expression = 'Name'; Descending = $true } |
        Select-Object -First 1 -ExpandProperty Name

    if ($tfm -match '^net(\d+)\.(\d+)$') { return ".NET $($Matches[1])" }
    return $tfm
}

if (Test-Path $specifyDir) {
    $constitution = Join-Path $specifyDir 'memory/constitution.md'
    $constitutionSrc = Join-Path $harnessRoot 'packs/dotnet/templates/constitution.md'

    if (Test-Path $constitution) {
        Add-Result '.specify/memory/constitution.md' 'SKIPPED' 'exists - your constitution is the project law, not ours'
    }
    elseif (-not (Test-Path $constitutionSrc)) {
        Add-Result '.specify/memory/constitution.md' 'MISSING' "template not found: $constitutionSrc"
    }
    else {
        $solution = Get-ChildItem -LiteralPath $TargetRepo -File -Filter *.sln* -ErrorAction SilentlyContinue |
            Select-Object -First 1
        $projectName = if ($solution) { [IO.Path]::GetFileNameWithoutExtension($solution.Name) } else { Split-Path $TargetRepo -Leaf }

        $tfmLabel = Get-TargetFrameworkLabel -Repo $TargetRepo
        $tfmNote = if ($tfmLabel) { $tfmLabel } else { 'unknown TFM - set it by hand' }
        if (-not $tfmLabel) { $tfmLabel = 'the target framework' }

        $rendered = @(Get-Content -LiteralPath $constitutionSrc) |
            Where-Object { $_ -notmatch '\{\{STACK_CONSTRAINTS\}\}' } |
            ForEach-Object { $_ -replace '\{\{PROJECT_NAME\}\}', $projectName -replace '\{\{TFM_LABEL\}\}', $tfmLabel }

        if ($PSCmdlet.ShouldProcess($constitution, 'render constitution')) {
            New-Item -ItemType Directory -Force -Path (Split-Path $constitution -Parent) | Out-Null
            Set-Content -LiteralPath $constitution -Value $rendered -Encoding UTF8
        }
        Add-Result '.specify/memory/constitution.md' 'RENDERED' "$projectName, $tfmNote"
    }
}
else {
    Add-Result '.specify/memory/constitution.md' 'PENDING' 'run `specify init` first, then re-run install.ps1'
}

# ── 5f. CONTEXT.md — the project's ubiquitous language ───────────────────────
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

# ── 5g. Templates offered but not installed ──────────────────────────────────
# Shipped, useful, and deliberately not copied: a CI workflow spends the
# adopter's Actions minutes, and a compose file depends on a stack the harness
# does not know. Reported so they are discoverable - previously they existed
# only for a reader who got to the end of the README.
#
# AVAILABLE is deliberately outside the SKIPPED/MANUAL/MISSING set below. These
# need no action, and a footer telling every adopter they have unfinished work
# is how a real warning gets ignored.
foreach ($offer in @(
        @{ Item = 'packs/dotnet/templates/workflows/codeql.yml'; Note = 'optional post-PR dataflow analysis; free on public repos' },
        @{ Item = 'packs/dotnet/templates/compose/'; Note = 'mongodb, postgres, redis, sqlserver - for Testcontainers-backed integration tests' }
    )) {
    if (Test-Path (Join-Path $harnessRoot $offer.Item)) {
        Add-Result $offer.Item 'AVAILABLE' $offer.Note
    }
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
Write-Output '  ./scripts/run-roslyn-analyzers.ps1 -All    # audit the code you already have'
Write-Output '  /task <issue>                             # start the pipeline'
Write-Output ''
# The gates analyse files changed against the base branch. Installing changes no
# .cs file, so the first no-arg run passes having checked nothing - correct, and
# misleading at the one moment it matters most. Say so here rather than letting a
# green light on an unaudited codebase be someone's first impression.
Write-Output 'The gates check CHANGED files by default, and installing changed none of yours.'
Write-Output 'Run them once with -All to get a baseline on the code that is already here.'

# Explicit, and load-bearing.
#
# Config resolution probes with `git rev-parse --verify --quiet`, which exits 1
# by design when a ref does not exist. PowerShell keeps that in $LASTEXITCODE,
# and a script with no explicit exit inherits it - so a completely successful
# install reported failure to its caller. It printed every success line first,
# which made it look like a CI flake rather than an exit-code bug.
exit 0
