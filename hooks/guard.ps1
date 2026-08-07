#!/usr/bin/env pwsh
<#
  PreToolUse hook: block genuinely destructive, hard-to-undo actions BEFORE they run.

  This is the only hook in the harness that PREVENTS something. The other two
  warn and fix after the fact. Keep the list tight - it is not a style checker
  and not a substitute for the host's own permission prompts.

  Blocks:
    Bash        - rm -rf of a root/home/glob target, deletion of a build output
                  directory, force-push to a protected branch, git reset --hard
                  to a remote ref, and `git checkout -- .` over a dirty tree.
    Edit/Write  - writes inside node_modules, bin, obj, or .git.

  IMPLEMENTATION NOTE - this is the whole reason the hook is PowerShell rather
  than a shell script. The version this was ported from extracted the command
  with grep and sed:

      grep -o '"command"[[:space:]]*:[[:space:]]*"[^"]*"'

  That regex stops at the first quote character, so any command containing an
  escaped quote - which a destructive command can trivially include - truncates
  the extracted string and slips past every pattern below. A guard that can be
  bypassed by quoting is worse than no guard, because it is trusted.
  ConvertFrom-Json parses the payload properly and has no such hole.

  Exit 2 blocks the action and returns the reason to the agent. Exit 0 allows.
  Anything unparseable exits 0: this hook must never wedge the session.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Deny {
    param([string]$Reason)
    # Write-Host, not Write-Error: with $ErrorActionPreference = 'Stop' a
    # Write-Error throws, unwinding before `exit 2` and returning 1 instead -
    # which most hosts read as "hook crashed", not "action blocked".
    [Console]::Error.WriteLine("guard: BLOCKED - $Reason")
    exit 2
}

$raw = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }

# -InputObject, not a pipeline: under Set-StrictMode the piped form binds the
# automatic $input enumerator and property access on the result then throws.
try { $payload = ConvertFrom-Json -InputObject $raw } catch { exit 0 }
if (-not $payload) { exit 0 }

function Get-Prop {
    <# Property access that yields $null instead of throwing under StrictMode. #>
    param($Object, [string[]]$Names)
    if (-not $Object) { return $null }
    $available = @($Object.PSObject.Properties.Name)
    foreach ($name in $Names) {
        if ($available -contains $name) { return $Object.$name }
    }
    return $null
}

function Deny-ProtectedPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }

    $normalized = $Path.Trim() -replace '\\', '/'
    if ($normalized -match '(^|/)(node_modules|bin|obj)(/|$)') {
        Deny "writing into a build output or dependency directory ($Path). Edit the source instead."
    }
    if ($normalized -match '(^|/)\.git(/|$)') {
        Deny 'writing inside .git. Use git commands rather than editing repository internals.'
    }
}

function Get-ApplyPatchPaths {
    param([string]$Command)
    if ([string]::IsNullOrWhiteSpace($Command)) { return @() }

    $paths = [System.Collections.Generic.List[string]]::new()
    foreach ($line in ($Command -split "`r?`n")) {
        if ($line -match '^\*\*\*\s+(?:Add|Update|Delete) File:\s*(.+?)\s*$' -or
            $line -match '^\*\*\*\s+Move to:\s*(.+?)\s*$') {
            [void]$paths.Add($Matches[1])
        }
    }
    return $paths
}

# Host schemas differ slightly between Cursor and Claude Code; accept either.
$tool = Get-Prop $payload @('tool_name', 'toolName', 'name')
if (-not $tool) { exit 0 }

# NB: not $input - that is a reserved automatic variable, and assigning to it
# silently yields the pipeline enumerator rather than the value assigned.
$toolInput = Get-Prop $payload @('tool_input', 'toolInput', 'input', 'arguments')

switch -Regex ($tool) {

    '^Bash$|^Shell$|^run_terminal_cmd$' {
        $cmd = Get-Prop $toolInput @('command', 'cmd')
        if ([string]::IsNullOrWhiteSpace($cmd)) { exit 0 }

        # rm -rf aimed at filesystem root, home, or a bare glob.
        if ($cmd -match 'rm\s+(-[a-zA-Z]*[rf][a-zA-Z]*\s+)+(-[a-zA-Z]+\s+)*(/\s*$|/\*|~|\$HOME|\*\s*$)') {
            Deny 'recursive force-delete of a root, home, or glob target. Delete a specific subpath instead.'
        }

        # Recursively deleting dependency or build output. These are often
        # partly root-owned in containers, so a half-finished rm leaves a
        # workspace that neither rebuilds nor cleans.
        if ($cmd -match 'rm\s+-[a-zA-Z]*r[a-zA-Z]*\s+.*(node_modules|[\\/](bin|obj)([\\/]|\s|$))') {
            Deny 'recursive delete of node_modules/bin/obj. Use `dotnet clean` or a fresh restore instead.'
        }

        # Force-push to an integration branch.
        if ($cmd -match 'git\s+push\b' -and
            $cmd -match '(--force(?!-with-lease)|\s-f\b)' -and
            $cmd -match '\b(main|master|develop|development|qa|release|production)\b') {
            Deny 'force-push to a protected branch. Push a task branch and open a PR instead.'
        }

        # Hard reset to a remote ref silently discards local commits.
        if ($cmd -match 'git\s+reset\s+--hard\s+(origin|upstream)/') {
            Deny 'git reset --hard to a remote ref discards local commits irreversibly. Confirm intent and run it yourself.'
        }

        # Wholesale discard of working-tree changes.
        if ($cmd -match 'git\s+checkout\s+--\s+\.\s*$' -or $cmd -match 'git\s+restore\s+(--\s+)?\.\s*$') {
            Deny 'discarding all working-tree changes. Restore specific paths instead.'
        }

        exit 0
    }

    '^(Edit|Write|MultiEdit|create_file|edit_file|search_replace)$' {
        $file = Get-Prop $toolInput @('file_path', 'filePath', 'path', 'target_file')
        if ([string]::IsNullOrWhiteSpace($file)) { exit 0 }
        Deny-ProtectedPath $file
        exit 0
    }

    '^apply_patch$' {
        $cmd = Get-Prop $toolInput @('command', 'cmd')
        foreach ($file in (Get-ApplyPatchPaths $cmd)) {
            Deny-ProtectedPath $file
        }
        exit 0
    }

    default { exit 0 }
}
