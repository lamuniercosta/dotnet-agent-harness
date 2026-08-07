#!/usr/bin/env pwsh
# harness.yml - the single configuration surface.
#
# PowerShell ships no YAML parser, and requiring one (powershell-yaml) would
# break the harness's zero-setup promise. The schema here is fixed and small,
# so a strict subset reader is enough: 2-space indent, `key: value` scalars,
# nested maps, and `#` comments. No lists, anchors, or multi-line strings.
#
# Unknown keys are a HARD ERROR. A silently-ignored typo would revert a
# threshold to its default and let a gate report a pass the repo never earned -
# the exact failure mode the gates exist to prevent.
#
# Dot-sourced by _gate-common.ps1; not intended to be run directly.

Set-StrictMode -Version Latest

# Dotted key -> value type. This doubles as the allow-list: anything not here
# is rejected by the parser.
$script:HarnessSchema = @{
    'harnessVersion'                             = 'scalar'
    'pack'                                       = 'scalar'
    'baseBranch'                                 = 'scalar'
    'tracker'                                    = 'scalar'
    'solution'                                   = 'scalar'
    'task.worktree'                              = 'bool'
    'task.worktreeRoot'                          = 'scalar'
    'gates.complexity.implement'                 = 'int'
    'gates.complexity.refactor'                  = 'int'
    'gates.mutation.threshold'                   = 'int'
    'gates.analyzers.mode'                       = 'scalar'
    'gates.analyzers.warningsAsErrors'           = 'bool'
    'gates.vulnerablePackages.fail'              = 'bool'
    'gates.vulnerablePackages.includeTransitive' = 'bool'
    'gates.inspectCode.enabled'                  = 'bool'
    'gates.propertyTests.enabled'                = 'bool'
    'agents.tiers.fast.claude.model'             = 'scalar'
    'agents.tiers.fast.claude.effort'            = 'scalar'
    'agents.tiers.fast.cursor.model'             = 'scalar'
    'agents.tiers.fast.cursor.effort'            = 'scalar'
    'agents.tiers.fast.codex.model'              = 'scalar'
    'agents.tiers.fast.codex.effort'             = 'scalar'
    'agents.tiers.balanced.claude.model'         = 'scalar'
    'agents.tiers.balanced.claude.effort'        = 'scalar'
    'agents.tiers.balanced.cursor.model'         = 'scalar'
    'agents.tiers.balanced.cursor.effort'        = 'scalar'
    'agents.tiers.balanced.codex.model'          = 'scalar'
    'agents.tiers.balanced.codex.effort'         = 'scalar'
    'agents.tiers.deep.claude.model'             = 'scalar'
    'agents.tiers.deep.claude.effort'            = 'scalar'
    'agents.tiers.deep.cursor.model'             = 'scalar'
    'agents.tiers.deep.cursor.effort'            = 'scalar'
    'agents.tiers.deep.codex.model'              = 'scalar'
    'agents.tiers.deep.codex.effort'             = 'scalar'
}

function Get-HarnessDefaults {
    return @{
        # Written by install.ps1. Absent means the harness predates versioning
        # or was copied in by hand.
        'harnessVersion'                             = $null
        'pack'                                       = 'dotnet'
        'baseBranch'                                 = $null   # resolved from git
        'tracker'                                    = 'github'
        'solution'                                   = $null   # globbed
        'task.worktree'                              = $true
        'task.worktreeRoot'                          = $null   # derived: <repo>.worktrees beside the repo
        'gates.complexity.implement'                 = 15
        'gates.complexity.refactor'                  = 6
        'gates.mutation.threshold'                   = 80
        'gates.analyzers.mode'                       = 'All'
        'gates.analyzers.warningsAsErrors'           = $false
        'gates.vulnerablePackages.fail'              = $true
        'gates.vulnerablePackages.includeTransitive' = $true
        'gates.inspectCode.enabled'                  = $true
        'gates.propertyTests.enabled'                = $true
        'agents.tiers.fast.claude.model'             = 'claude-haiku-4-5-20251001'
        'agents.tiers.fast.claude.effort'            = 'low'
        'agents.tiers.fast.cursor.model'             = 'gpt-5.6-luna'
        'agents.tiers.fast.cursor.effort'            = 'low'
        'agents.tiers.fast.codex.model'              = 'gpt-5.6-terra'
        'agents.tiers.fast.codex.effort'             = 'low'
        'agents.tiers.balanced.claude.model'         = 'inherit'
        'agents.tiers.balanced.claude.effort'        = 'inherit'
        'agents.tiers.balanced.cursor.model'         = 'inherit'
        'agents.tiers.balanced.cursor.effort'        = 'inherit'
        'agents.tiers.balanced.codex.model'          = 'inherit'
        'agents.tiers.balanced.codex.effort'         = 'inherit'
        'agents.tiers.deep.claude.model'             = 'inherit'
        'agents.tiers.deep.claude.effort'            = 'inherit'
        'agents.tiers.deep.cursor.model'             = 'inherit'
        'agents.tiers.deep.cursor.effort'            = 'inherit'
        'agents.tiers.deep.codex.model'              = 'inherit'
        'agents.tiers.deep.codex.effort'             = 'inherit'
    }
}

function ConvertFrom-HarnessYaml {
    <#
      Parses the harness.yml subset into a flat hashtable keyed by dotted path.
      Throws on malformed indentation, lists, duplicate keys, or unknown keys.
    #>
    param(
        [string[]]$Lines,
        [string]$Path = 'harness.yml'
    )

    $result = @{}
    $stack = [System.Collections.ArrayList]::new()   # open key path
    $indents = [System.Collections.ArrayList]::new() # indent that opened each level
    $lineNo = 0

    foreach ($raw in $Lines) {
        $lineNo++

        # Strip comments only where '#' begins a token, so a value like a#b survives.
        $line = $raw -replace '(^|\s)#.*$', ''
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        if ($line -match '^\s*-\s') {
            throw "${Path}:${lineNo}: lists are not supported by the harness.yml subset."
        }
        if ($line -match "`t") {
            throw "${Path}:${lineNo}: tabs are not supported; use 2 spaces per level."
        }
        if ($line -notmatch '^(\s*)([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(.*)$') {
            throw "${Path}:${lineNo}: expected 'key: value', got '$($raw.Trim())'."
        }

        $indent = $Matches[1].Length
        $key = $Matches[2]
        $value = $Matches[3].Trim()

        if ($indent % 2 -ne 0) {
            throw "${Path}:${lineNo}: indent must be a multiple of 2 spaces (got $indent)."
        }

        # Close every level at or deeper than this one.
        while ($indents.Count -gt 0 -and $indent -le $indents[$indents.Count - 1]) {
            $stack.RemoveAt($stack.Count - 1)
            $indents.RemoveAt($indents.Count - 1)
        }

        if ($value -eq '') {
            [void]$stack.Add($key)
            [void]$indents.Add($indent)
            continue
        }

        $dotted = (@($stack.ToArray()) + $key) -join '.'

        if ($result.ContainsKey($dotted)) {
            throw "${Path}:${lineNo}: duplicate key '$dotted'."
        }
        if (-not $script:HarnessSchema.ContainsKey($dotted)) {
            if ($dotted -match '^agents\.tiers\.(fast|balanced|deep)\.(claude|cursor|codex)$') {
                throw "${Path}:${lineNo}: legacy scalar agent tier '$dotted' is unsupported in 0.3.0; nest 'model:' and 'effort:' below the host. See CHANGELOG.md."
            }
            $known = ($script:HarnessSchema.Keys | Sort-Object) -join ', '
            throw "${Path}:${lineNo}: unknown key '$dotted'.`n  Known keys: $known"
        }

        $result[$dotted] = switch ($script:HarnessSchema[$dotted]) {
            'int' {
                $parsed = 0
                if (-not [int]::TryParse($value, [ref]$parsed)) {
                    throw "${Path}:${lineNo}: '$dotted' must be an integer, got '$value'."
                }
                $parsed
            }
            'bool' {
                switch ($value.ToLowerInvariant()) {
                    'true' { $true }
                    'false' { $false }
                    default { throw "${Path}:${lineNo}: '$dotted' must be true or false, got '$value'." }
                }
            }
            default {
                if ($value -eq 'null') { $null } else { $value.Trim('"').Trim("'") }
            }
        }
    }

    return $result
}

function Get-HarnessConfig {
    <#
      Loads harness.yml from the repo root layered over the defaults, resolving
      the discoverable values (base branch, solution) once so every caller
      agrees. Returns a flat hashtable keyed by dotted path.
    #>
    param([string]$RepoRoot)

    if (-not $RepoRoot) { $RepoRoot = Get-RepoRoot }

    if ((Test-Path variable:script:HarnessConfigCache) -and
        $script:HarnessConfigCache -and
        $script:HarnessConfigRoot -eq $RepoRoot) {
        return $script:HarnessConfigCache
    }

    $config = Get-HarnessDefaults
    $file = Join-Path $RepoRoot 'harness.yml'

    if (Test-Path $file) {
        $parsed = ConvertFrom-HarnessYaml -Lines (Get-Content -LiteralPath $file) -Path $file
        foreach ($key in $parsed.Keys) {
            if ($null -ne $parsed[$key]) { $config[$key] = $parsed[$key] }
        }
    }

    if (-not $config['baseBranch']) {
        $config['baseBranch'] = (Resolve-BaseRef -RepoRoot $RepoRoot -Explicit '') -replace '^origin/', ''
    }

    if (-not $config['solution']) {
        $found = @(Get-ChildItem -LiteralPath $RepoRoot -Recurse -Depth 2 -Include '*.sln', '*.slnx' -File -ErrorAction SilentlyContinue)
        if ($found.Count -eq 1) {
            $config['solution'] = $found[0].FullName
        }
        elseif ($found.Count -gt 1) {
            $names = ($found | ForEach-Object { $_.Name }) -join ', '
            throw "Found $($found.Count) solutions ($names). Set 'solution:' in harness.yml to disambiguate."
        }
    }

    $script:HarnessConfigCache = $config
    $script:HarnessConfigRoot = $RepoRoot
    return $config
}

function Get-HarnessValue {
    <#
      Reads one dotted key, e.g. Get-HarnessValue 'gates.mutation.threshold'.
      Throws on an unknown key so a typo in a script fails loudly too.
    #>
    param(
        [Parameter(Mandatory)][string]$Key,
        [string]$RepoRoot
    )

    if (-not $script:HarnessSchema.ContainsKey($Key)) {
        throw "Unknown harness key '$Key'. See harness.yml.example."
    }

    return (Get-HarnessConfig -RepoRoot $RepoRoot)[$Key]
}
