#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Installs dotnet-agent-harness into an existing repository.

.DESCRIPTION
  Adopt-first: this adds the harness to a repo that already exists. `new-project.sh`
  scaffolds a solution and then calls this same script, so there is one code path.

  Nothing is clobbered. Files the harness owns (skills, marked generated agents,
  rules, hooks, gate scripts) are refreshed on every run. Unmarked agent collisions
  are preserved and reported. Files the REPO owns (Directory.Build.props,
  .editorconfig, harness.yml) are created if absent and otherwise left alone and
  reported, so you can merge by hand.

  Thresholds are rendered from harness.yml into the tool configs that consume them,
  so a threshold lives in exactly one place.

.PARAMETER TargetRepo
  Repository to install into. Defaults to the current directory.

.PARAMETER Platform
  Which agent platform(s) to wire: cursor, claude, codex, both, or all (default).
  `both` predates the Codex adapter and still means cursor + claude, so a pinned
  -Platform both keeps exactly the behaviour it always had.
  Shared assets are always installed. The selected hosts receive generated named
  agents in their native discovery format. `codex` and `all` additionally generate
  the `.agents/skills` discovery copy with Codex `$name` syntax.

.EXAMPLE
  pwsh ./install.ps1 F:\Dev\MyApi -WhatIf
  pwsh ./install.ps1 F:\Dev\MyApi -Platform claude
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Position = 0)]
    [string]$TargetRepo = '.',

    [ValidateSet('cursor', 'claude', 'codex', 'both', 'all')]
    [string]$Platform = 'all',

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
. (Join-Path $harnessRoot 'scripts/_skill-rendering.ps1')

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

function Read-CanonicalAgentProfile {
    param([Parameter(Mandatory)][string]$Path)

    $raw = (Get-Content -LiteralPath $Path -Raw) -replace "`r`n", "`n"
    $lines = @($raw -split "`n", 0, 'SimpleMatch')
    if ($lines.Count -lt 4 -or $lines[0] -ne '---') {
        throw "${Path}: agent profile must start with YAML frontmatter."
    }

    $closing = -1
    for ($i = 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -eq '---') { $closing = $i; break }
    }
    if ($closing -lt 0) { throw "${Path}: agent profile frontmatter is not closed." }

    $metadata = @{}
    for ($i = 1; $i -lt $closing; $i++) {
        if ($lines[$i] -notmatch '^([A-Za-z][A-Za-z0-9]*):\s*(.*)$') {
            throw "${Path}: unsupported agent frontmatter line '$($lines[$i])'."
        }
        $metadata[$Matches[1]] = $Matches[2]
    }

    foreach ($required in @('name', 'description', 'tier', 'readonly', 'tools')) {
        if (-not $metadata.ContainsKey($required) -or -not $metadata[$required]) {
            throw "${Path}: agent profile is missing '$required'."
        }
    }
    if ($metadata['tier'] -notin @('fast', 'balanced', 'deep')) {
        throw "${Path}: tier must be fast, balanced, or deep; got '$($metadata['tier'])'."
    }
    if ($metadata['readonly'] -notin @('true', 'false')) {
        throw "${Path}: readonly must be true or false; got '$($metadata['readonly'])'."
    }

    $body = if ($closing + 1 -lt $lines.Count) {
        ($lines[($closing + 1)..($lines.Count - 1)] -join "`n")
    }
    else { '' }

    return [PSCustomObject]@{
        Name        = $metadata['name']
        Description = $metadata['description']
        Tier        = $metadata['tier']
        ReadOnly    = $metadata['readonly'] -eq 'true'
        Tools       = $metadata['tools']
        Body        = $body
        SourcePath  = $Path
    }
}

function Get-AgentTierSetting {
    param(
        [Parameter(Mandatory)]$Profile,
        [Parameter(Mandatory)][ValidateSet('claude', 'cursor', 'codex')][string]$AgentHost,
        [Parameter(Mandatory)][ValidateSet('model', 'effort')][string]$Setting
    )

    return $config["agents.tiers.$($Profile.Tier).$AgentHost.$Setting"]
}

function ConvertTo-TomlString {
    param([AllowEmptyString()][string]$Value)
    return ($Value | ConvertTo-Json -Compress)
}

function Render-MarkdownAgentProfile {
    param(
        [Parameter(Mandatory)]$Profile,
        [Parameter(Mandatory)][ValidateSet('claude', 'cursor')][string]$AgentHost
    )

    $model = Get-AgentTierSetting -Profile $Profile -AgentHost $AgentHost -Setting model
    $effort = Get-AgentTierSetting -Profile $Profile -AgentHost $AgentHost -Setting effort
    $frontmatter = @(
        '---'
        'harnessGenerated: true'
        "name: $($Profile.Name)"
        "description: $($Profile.Description)"
        "tier: $($Profile.Tier)"
    )

    if ($AgentHost -eq 'claude') {
        if ($model -ne 'inherit') { $frontmatter += "model: $model" }
        if ($effort -ne 'inherit') { $frontmatter += "effort: $effort" }
        if ($Profile.ReadOnly) { $frontmatter += 'permissionMode: plan' }
    }
    else {
        if ($model -eq 'inherit') {
            if ($effort -ne 'inherit') {
                throw "Cursor tier '$($Profile.Tier)' cannot set effort '$effort' while model is inherit."
            }
            $frontmatter += 'model: inherit'
        }
        elseif ($effort -eq 'inherit') {
            $frontmatter += "model: $model"
        }
        else {
            $frontmatter += "model: $model[effort=$effort]"
        }
        $frontmatter += "readonly: $($Profile.ReadOnly.ToString().ToLowerInvariant())"
    }

    $frontmatter += "tools: $($Profile.Tools)"
    $frontmatter += '---'
    return (($frontmatter + $Profile.Body) -join "`n").TrimEnd("`r", "`n") + "`n"
}

function Render-CodexAgentProfile {
    param([Parameter(Mandatory)]$Profile)

    $model = Get-AgentTierSetting -Profile $Profile -AgentHost codex -Setting model
    $effort = Get-AgentTierSetting -Profile $Profile -AgentHost codex -Setting effort
    $description = ConvertTo-CodexSkillReferences -Content $Profile.Description `
        -SkillsSource (Join-Path $harnessRoot 'skills')
    $instructions = ConvertTo-CodexSkillReferences -Content $Profile.Body.Trim() `
        -SkillsSource (Join-Path $harnessRoot 'skills')
    $toml = @(
        '# dotnet-agent-harness: generated agent'
        "name = $(ConvertTo-TomlString $Profile.Name)"
        "description = $(ConvertTo-TomlString $description)"
        "developer_instructions = $(ConvertTo-TomlString $instructions)"
    )
    if ($model -ne 'inherit') { $toml += "model = $(ConvertTo-TomlString $model)" }
    if ($effort -ne 'inherit') { $toml += "model_reasoning_effort = $(ConvertTo-TomlString $effort)" }
    if ($Profile.ReadOnly) { $toml += 'sandbox_mode = "read-only"' }
    return ($toml -join "`n") + "`n"
}

function Test-HarnessOwnedAgent {
    param([Parameter(Mandatory)][string]$Path)

    $lines = @(Get-Content -LiteralPath $Path)
    if ($lines.Count -eq 0) { return $false }
    if ($lines[0] -eq '# dotnet-agent-harness: generated agent') { return $true }
    if ($lines[0] -ne '---') { return $false }

    for ($i = 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -eq '---') { return $false }
        if ($lines[$i] -match '^harnessGenerated:\s*true\s*$') { return $true }
    }
    return $false
}

function Test-ExactLegacyClaudeAgent {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name)

    # SHA-256 of the five v0.2.0 canonical files after normalizing CRLF to LF.
    # This permits only the promised exact legacy copies while remaining stable
    # across Git's platform-specific checkout line endings.
    $legacyHashes = @{
        'code-reviewer'     = 'bb8122fba5ee688f5afe3fb9bf277eddf83c1864a6582e6f3790bd46b9785970'
        'gate-runner'       = '2df8284b218888d69b2cbcf8f9255c23a91440676e5a2d3b8d7d04f70a22987a'
        'mutation-analyst'  = '212d7c1b3bc8869d24c6ce3aa6f1eb4ec6192cacaadfa0948a42d9b8b75c59fd'
        'security-reviewer' = '5fecdbeabfe0e31a8e027fac310a4f76b5b80f9163a49ce8f38cb7588db20dc0'
        'test-writer'       = '8228e564544dbab747737457096bff6de1a8e59956eb7a2a56f2bd88112f0e23'
    }
    if (-not $legacyHashes.ContainsKey($Name)) { return $false }
    $normalized = ([IO.File]::ReadAllText($Path) -replace "`r`n", "`n")
    $bytes = [Text.Encoding]::UTF8.GetBytes($normalized)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $actual = [Convert]::ToHexString($sha.ComputeHash($bytes)).ToLowerInvariant()
    }
    finally { $sha.Dispose() }
    return $actual -eq $legacyHashes[$Name]
}

function Install-GeneratedAgentProfile {
    param(
        [Parameter(Mandatory)]$Profile,
        [Parameter(Mandatory)][ValidateSet('claude', 'cursor', 'codex')][string]$AgentHost,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$Content
    )

    $item = "$AgentHost agent: $($Profile.Name)"
    $status = 'ADDED'
    $note = "$($Profile.Tier) tier"
    if (Test-Path $Destination) {
        if (Test-HarnessOwnedAgent -Path $Destination) {
            $status = 'SYNCED'
        }
        elseif ($AgentHost -eq 'claude' -and
                (Test-ExactLegacyClaudeAgent -Path $Destination -Name $Profile.Name)) {
            $status = 'ADOPTED'
            $note += '; exact v0.2.0 profile'
        }
        else {
            Add-Result $item 'COLLISION' 'unmarked file preserved; rename it or add the harness ownership marker to adopt it'
            return
        }
    }

    if ($PSCmdlet.ShouldProcess($Destination, "render $AgentHost agent '$($Profile.Name)'")) {
        New-Item -ItemType Directory -Force -Path (Split-Path $Destination -Parent) | Out-Null
        Set-Content -LiteralPath $Destination -Value $Content -NoNewline -Encoding UTF8
    }
    Add-Result $item $status $note
}

function Install-AgentProfiles {
    $source = Join-Path $harnessRoot '.claude/agents'
    $profiles = @(Get-ChildItem -LiteralPath $source -File -Filter '*.md' | Sort-Object Name |
        ForEach-Object { Read-CanonicalAgentProfile -Path $_.FullName })

    foreach ($profile in $profiles) {
        if ($Platform -in @('claude', 'both', 'all')) {
            $destination = Join-Path $TargetRepo ".claude/agents/$($profile.Name).md"
            Install-GeneratedAgentProfile -Profile $profile -AgentHost claude -Destination $destination `
                -Content (Render-MarkdownAgentProfile -Profile $profile -AgentHost claude)
        }
        if ($Platform -in @('cursor', 'both', 'all')) {
            $destination = Join-Path $TargetRepo ".cursor/agents/$($profile.Name).md"
            Install-GeneratedAgentProfile -Profile $profile -AgentHost cursor -Destination $destination `
                -Content (Render-MarkdownAgentProfile -Profile $profile -AgentHost cursor)
        }
        if ($Platform -in @('codex', 'all')) {
            $destination = Join-Path $TargetRepo ".codex/agents/$($profile.Name).toml"
            Install-GeneratedAgentProfile -Profile $profile -AgentHost codex -Destination $destination `
                -Content (Render-CodexAgentProfile -Profile $profile)
        }
    }
}

# ── 1. harness.yml — the repo owns its settings, the harness owns the version ─
$harnessVersion = (Get-Content -LiteralPath (Join-Path $harnessRoot 'VERSION') -Raw).Trim()
$harnessFile = Join-Path $TargetRepo 'harness.yml'
$config = $null

# Preflight an existing consumer config before stamping its version. A 0.2.0
# scalar agent-tier shape must fail with migration guidance without leaving a
# misleading 0.3.0 stamp behind.
if (Test-Path $harnessFile) {
    $config = Get-HarnessConfig -RepoRoot $TargetRepo
}

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

# Read newly created config from the TARGET repo. Defaults apply when -WhatIf
# skipped the copy; existing config was already parsed during preflight.
if ($null -eq $config) {
    $config = Get-HarnessConfig -RepoRoot $TargetRepo
}

# ── 2. Shared sources, delivered where each host discovers them ─────────────
#
# Each asset has one authored source in this harness. Most can also have one
# installed home. Skills are the exception: Codex scans .agents/skills and uses
# `$name`, while Cursor and Claude Code share .claude/skills and use `/name`.
# Both installed trees are refreshed from skills/; .agents is then adapted
# deterministically, so neither installed copy becomes an authored source.
#
# Skills live under .claude/ because Cursor reads BOTH natively -
# its docs: "For compatibility, Cursor also loads skills from Claude and Codex
# directories: .claude/skills/, .codex/skills/". Rules live under .cursor/
# because only Cursor can auto-load them by glob; Claude reaches them through
# CLAUDE.md @imports pointing at the same path.
#
# So a Claude-only install still has a .cursor/rules/ directory, and a
# Cursor-only install still has .claude/skills/. Codex requires a generated
# .agents/skills copy because it uses `$name` rather than `/name` commands.
# Agent profiles are the other exception: one canonical Markdown source is
# rendered into each selected host's native discovery directory and syntax.

Copy-Tree (Join-Path $harnessRoot 'skills') (Join-Path $TargetRepo '.claude/skills') 'skills -> .claude/skills (both platforms read this)'
Install-AgentProfiles
Copy-Tree (Join-Path $harnessRoot 'hooks') (Join-Path $TargetRepo 'scripts/hooks') 'hooks -> scripts/hooks'

if ($Platform -in @('codex', 'all')) {
    $codexSkills = Join-Path $TargetRepo '.agents/skills'
    Copy-Tree (Join-Path $harnessRoot 'skills') $codexSkills 'skills -> .agents/skills (Codex `$name`)'
    if ($PSCmdlet.ShouldProcess($codexSkills, 'adapt skill references for Codex')) {
        Convert-CodexSkillReferences -SkillsSource (Join-Path $harnessRoot 'skills') -CodexSkills $codexSkills
    }
}

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
if ($Platform -in @('cursor', 'both', 'all')) {
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

if ($Platform -in @('claude', 'both', 'all')) {
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

if ($Platform -in @('codex', 'all')) {
    # Codex keeps its hook wiring beside its project config. Hooks are harness-
    # owned and therefore refreshed on every install; config.toml is the repo's
    # own integration point and remains a skip-if-present file below.
    $codexDir = Join-Path $TargetRepo '.codex'
    $codexHooks = Join-Path $codexDir 'hooks.json'
    if ($PSCmdlet.ShouldProcess($codexHooks, 'install Codex hook wiring')) {
        New-Item -ItemType Directory -Force -Path $codexDir | Out-Null
        Copy-Item (Join-Path $harnessRoot 'adapters/codex/hooks.json') $codexHooks -Force
    }
    Add-Result '.codex/hooks.json' 'SYNCED' 'hook wiring'

    # Codex reads AGENTS.md from the repo ROOT and has no @import, so unlike
    # CLAUDE.md this adapter is a self-contained distillation of the same ten
    # rules rather than a list of pointers.
    #
    # That is exactly why the append trick used for CLAUDE.md is wrong here.
    # Appending ten lines of @imports under a repo's own instructions is small and
    # reversible; appending a whole ruleset is neither, and it would sit in silent
    # contradiction with whatever the repo already told its agents. An existing
    # AGENTS.md is reported for a hand merge - the same call already made for the
    # two MCP configs.
    $agentsMd = Join-Path $TargetRepo 'AGENTS.md'
    if (Test-Path $agentsMd) {
        Add-Result 'AGENTS.md' 'SKIPPED' 'already exists - merge the conventions from adapters/codex/AGENTS.md by hand'
    }
    else {
        if ($PSCmdlet.ShouldProcess($agentsMd, 'install AGENTS.md')) {
            Copy-Item (Join-Path $harnessRoot 'adapters/codex/AGENTS.md') $agentsMd -Force
        }
        Add-Result 'AGENTS.md' 'ADDED' 'distilled rules - Codex cannot @import them'
    }

    # TOML rather than JSON, and project-scoped rather than ~/.codex/config.toml:
    # the global file holds the user's own plugins, marketplaces and auth, and the
    # harness has no business writing there. Codex loads project config only for a
    # TRUSTED project, which AGENTS.md says out loud - an untrusted repo silently
    # registers no servers.
    $codexConfig = Join-Path $TargetRepo '.codex/config.toml'
    if (Test-Path $codexConfig) {
        Add-Result '.codex/config.toml' 'SKIPPED' 'already exists - merge the two documentation servers by hand'
    }
    else {
        if ($PSCmdlet.ShouldProcess($codexConfig, 'install MCP config')) {
            # Do not rely on the separate hooks operation having been approved;
            # ShouldProcess can be answered independently under -Confirm.
            New-Item -ItemType Directory -Force -Path $codexDir | Out-Null
            Copy-Item (Join-Path $harnessRoot 'adapters/codex/config.toml') $codexConfig -Force
        }
        Add-Result '.codex/config.toml' 'ADDED' 'microsoft-learn + context7'
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
if ($Platform -eq 'codex') {
    Write-Output '  specify init --here --integration codex    # create Spec Kit commands for Codex'
}
elseif ($Platform -eq 'all') {
    Write-Output '  specify init --here --integration claude   # or --integration cursor-agent'
    Write-Output '  specify integration install codex          # add Codex Spec Kit skills too'
}
else {
    Write-Output '  specify init --here --integration claude   # or --integration cursor-agent'
}
Write-Output '  ./scripts/run-roslyn-analyzers.ps1 -All    # audit the code you already have'
if ($Platform -eq 'codex') {
    Write-Output '  $task <issue>                             # start the pipeline in Codex'
}
elseif ($Platform -eq 'all') {
    Write-Output '  /task <issue>                             # Cursor / Claude Code'
    Write-Output '  $task <issue>                             # Codex'
}
else {
    Write-Output '  /task <issue>                             # start the pipeline'
}
Write-Output ''
if ($Platform -in @('codex', 'all')) {
    Write-Output 'On Codex: harness skills are available from .agents/skills; use `$task` to'
    Write-Output 'start the pipeline. Named agents are available from .codex/agents. Trust the project'
    Write-Output 'on first open or .codex/config.toml registers no MCP servers. .codex/hooks.json'
    Write-Output 'wires prompt and tool-use checks after you review and trust the harness. Codex'
    Write-Output 'has no file-read hook event, so a secret scan cannot run before file context loads.'
    Write-Output ''
}
# The gates analyse files changed against the base branch. Installing changes no
# .cs file, so the first no-arg run has nothing to look at and reports SKIPPED
# (exit 2) rather than a pass it did not earn. That is the right answer and still
# not the one someone wants on day one, so point them at the baseline run.
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
