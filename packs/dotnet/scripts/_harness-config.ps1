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
        'solution'                                   = $null   # declared only; discovery is in Resolve-Solution
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

$script:AllowedTrackers = @('github', 'youtrack', 'none')

function Assert-HarnessTracker {
    param([AllowNull()][string]$Tracker)

    if ($script:AllowedTrackers -contains $Tracker) { return }
    $shown = if ([string]::IsNullOrWhiteSpace($Tracker)) { '<empty>' } else { $Tracker }
    throw "harness.yml tracker '$shown' is unsupported. Expected github, youtrack, or none."
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
      Loads harness.yml from the repo root layered over the defaults. Validates
      declared values (baseBranch, solution) but does NOT discover undeclared
      ones — discovery belongs in the caller that needs it (Resolve-Solution,
      Resolve-BaseRef). Returns a flat hashtable keyed by dotted path.
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

    Assert-HarnessTracker -Tracker $config['tracker']

    if (-not $config['baseBranch']) {
        $config['baseBranch'] = (Resolve-BaseRef -RepoRoot $RepoRoot -Explicit '') -replace '^origin/', ''
    }

    if ($config['solution']) {
        $p = if ([System.IO.Path]::IsPathRooted($config['solution'])) { $config['solution'] } else { Join-Path $RepoRoot $config['solution'] }
        if (-not (Test-Path $p)) {
            throw "harness.yml names a solution that does not exist: $($config['solution'])"
        }
        $config['solution'] = (Resolve-Path $p).Path
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

# Paths that are never part of the repo under analysis: build output, vendored
# packages, and NESTED CHECKOUTS. An in-repo git worktree (.claude/worktrees/<name>/
# from Claude Code's agent isolation, or any *.worktrees/ root) is a different
# branch's working tree; recursive discovery must not mix its projects and configs
# into this repo's gate results. new-task-branch.ps1 refuses to CREATE one in-repo,
# but other tools still do, so the gates exclude them defensively. See #79.
$script:HarnessExcludedPathPattern =
    '[\\/](bin|obj|node_modules|artifacts)[\\/]' +
    '|[\\/]\.claude[\\/]worktrees[\\/]' +
    '|[\\/][^\\/]+\.worktrees[\\/]'

function Test-HarnessExcludedPath {
    <#
      True when a discovered path lies in build output, vendored packages, or a
      nested checkout, and must not be treated as part of this repo.

      Matching is done on the portion of the path BELOW RepoRoot. Ancestors of the
      repo must never exclude it: the harness's own default task layout is
      <repo>.worktrees/<task>, so an absolute match would exclude a task worktree's
      own files. The same applies to a repo living under a directory named obj, bin,
      or artifacts. See #79.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory)][string]$RepoRoot
    )

    if ([string]::IsNullOrEmpty($Path)) { return $false }

    $rootFull = [System.IO.Path]::GetFullPath($RepoRoot).TrimEnd('\', '/')
    try { $pathFull = [System.IO.Path]::GetFullPath($Path) } catch { $pathFull = $Path }

    $comparison = [System.StringComparison]::OrdinalIgnoreCase
    $subject =
        if ($pathFull.Equals($rootFull, $comparison)) {
            ''
        }
        elseif ($pathFull.StartsWith($rootFull + [System.IO.Path]::DirectorySeparatorChar, $comparison) -or
                $pathFull.StartsWith($rootFull + '/', $comparison)) {
            # Keeps a leading separator, so a top-level 'bin/' still matches.
            $pathFull.Substring($rootFull.Length)
        }
        else {
            # Defensive: discovery always passes paths under RepoRoot. For anything
            # else there is no meaningful relative form, so fall back to the whole path.
            $pathFull
        }

    return $subject -match $script:HarnessExcludedPathPattern
}

function Resolve-Solution {
    <#
      The single entry point for solution resolution.
      Precedence: declared (Explicit param, then harness.yml solution:),
      else the sole candidate, else the unique repo-root candidate, else throw.
      Returns $null when the repo has no solution at all.
    #>
    param(
        [string]$RepoRoot,
        [string]$Explicit
    )

    if (-not $RepoRoot) { $RepoRoot = Get-RepoRoot }

    if ($Explicit) {
        $path = if ([System.IO.Path]::IsPathRooted($Explicit)) { $Explicit } else { Join-Path $RepoRoot $Explicit }
        if (-not (Test-Path $path)) {
            throw "Solution not found: $Explicit"
        }
        return (Resolve-Path $path).Path
    }

    $declared = $null
    try { $declared = Get-HarnessValue 'solution' -RepoRoot $RepoRoot } catch { throw }
    if ($declared) { return $declared }

    $candidates = @(
        Get-ChildItem -Path $RepoRoot -Include '*.slnx', '*.sln' -File -Depth 2 -Recurse -ErrorAction SilentlyContinue |
            Where-Object { -not (Test-HarnessExcludedPath -Path $_.FullName -RepoRoot $RepoRoot) }
    )

    if ($candidates.Count -eq 0) { return $null }

    if ($candidates.Count -eq 1) { return $candidates[0].FullName }

    $atRoot = @($candidates | Where-Object { $_.DirectoryName -eq $RepoRoot })

    if ($atRoot.Count -eq 1) { return $atRoot[0].FullName }

    $list = ($candidates | ForEach-Object { '  ' + [System.IO.Path]::GetRelativePath($RepoRoot, $_.FullName) }) -join "`n"
    throw "Multiple candidate solutions found. Set 'solution:' in harness.yml to pick one:`n$list"
}
