#!/usr/bin/env pwsh
<#
  PreToolUse hook: block genuinely destructive, hard-to-undo actions BEFORE they run.

  This is the only hook in the harness that PREVENTS something. The other two
  warn and fix after the fact. Keep the list tight - it is not a style checker
  and not a substitute for the host's own permission prompts.

  Blocks:
    Bash        - rm -rf of a root/home/glob target, deletion of a build output
                  directory, force-push to a protected or implicit destination,
                  deletion of a protected branch via push (--delete/-d or a
                  `:dst` refspec), git reset --hard to a remote ref, and
                  `git checkout -- .` over a dirty tree.
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

function Split-ShellSegments {
    param([string]$Command)

    $segments = [System.Collections.Generic.List[string]]::new()
    $buffer = [System.Text.StringBuilder]::new()
    $quote = [char]0
    $escaped = $false

    foreach ($character in $Command.ToCharArray()) {
        if ($escaped) {
            [void]$buffer.Append($character)
            $escaped = $false
            continue
        }
        if ($character -eq '\' -and $quote -ne "'") {
            [void]$buffer.Append($character)
            $escaped = $true
            continue
        }
        if ($quote -ne [char]0) {
            [void]$buffer.Append($character)
            if ($character -eq $quote) { $quote = [char]0 }
            continue
        }
        if ($character -in @("'", '"')) {
            $quote = $character
            [void]$buffer.Append($character)
            continue
        }
        if ($character -in @(';', '&', '|', '(', ')', '<', '>', '`', "`r", "`n")) {
            $segment = $buffer.ToString().Trim()
            if ($character -in @('<', '>')) { $segment = $segment -replace '\s+\d+$', '' }
            if ($segment) { $segments.Add($segment) }
            [void]$buffer.Clear()
            continue
        }
        [void]$buffer.Append($character)
    }

    $segment = $buffer.ToString().Trim()
    if ($segment) { $segments.Add($segment) }
    return $segments
}

function Split-ShellWords {
    param([string]$Command)

    $words = [System.Collections.Generic.List[string]]::new()
    $buffer = [System.Text.StringBuilder]::new()
    $quote = [char]0
    $escaped = $false

    foreach ($character in $Command.ToCharArray()) {
        if ($escaped) {
            [void]$buffer.Append($character)
            $escaped = $false
            continue
        }
        if ($character -eq '\' -and $quote -ne "'") {
            $escaped = $true
            continue
        }
        if ($quote -ne [char]0) {
            if ($character -eq $quote) { $quote = [char]0 }
            else { [void]$buffer.Append($character) }
            continue
        }
        if ($character -in @("'", '"')) {
            $quote = $character
            continue
        }
        if ([char]::IsWhiteSpace($character)) {
            if ($buffer.Length -gt 0) {
                $words.Add($buffer.ToString())
                [void]$buffer.Clear()
            }
            continue
        }
        [void]$buffer.Append($character)
    }

    if ($buffer.Length -gt 0) { $words.Add($buffer.ToString()) }
    return $words
}

function Find-GitSubcommandIndex {
    param([string[]]$Words, [int]$GitIndex)

    $globalOptionsWithValues = @('-C', '-c', '--git-dir', '--work-tree', '--namespace', '--config-env', '--exec-path')
    $index = $GitIndex + 1

    while ($index -lt $Words.Count) {
        $word = $Words[$index]
        if ($word -eq '--') {
            $index++
            break
        }
        if ($word -in $globalOptionsWithValues) {
            if (($index + 1) -ge $Words.Count) { return -1 }
            $index += 2
            continue
        }
        if ($word -match '^--(?:git-dir|work-tree|namespace|config-env|exec-path)=') {
            $index++
            continue
        }
        # Any other leading option is a flag. Skipping flags generically keeps
        # this safe when Git adds global flags; only value-taking options need
        # explicit entries above so their argument is not mistaken for a
        # subcommand.
        if ($word.StartsWith('-')) {
            $index++
            continue
        }
        break
    }

    if ($index -ge $Words.Count) { return -1 }
    return $index
}

function Get-UnsafePushReason {
    param([string]$Command)

    $protectedBranches = @('main', 'master', 'develop', 'development', 'qa', 'release', 'production')
    $optionsWithValues = @('--repo', '--receive-pack', '--exec', '--push-option', '-o')

    foreach ($segment in (Split-ShellSegments $Command)) {
        $words = @(Split-ShellWords $segment)
        for ($gitIndex = 0; $gitIndex -lt ($words.Count - 1); $gitIndex++) {
            $gitCommand = ($words[$gitIndex] -replace '\\', '/').Split('/')[-1]
            if ($gitCommand -notin @('git', 'git.exe')) { continue }
            $subcommandIndex = Find-GitSubcommandIndex -Words $words -GitIndex $gitIndex
            if ($subcommandIndex -lt 0 -or $words[$subcommandIndex] -ne 'push') { continue }

            $force = $false
            $delete = $false
            $endOfOptions = $false
            $skipOptionValue = $false
            $repositoryNamed = $false
            $positionals = [System.Collections.Generic.List[string]]::new()

            for ($index = $subcommandIndex + 1; $index -lt $words.Count; $index++) {
                $word = $words[$index]
                if ($skipOptionValue) {
                    $skipOptionValue = $false
                    continue
                }
                if (-not $endOfOptions -and $word -eq '--') {
                    $endOfOptions = $true
                    continue
                }
                if (-not $endOfOptions -and $word.StartsWith('-')) {
                    if ($word -eq '--force' -or $word -match '^--force-with-lease(?:=.*)?$' -or
                        ($word -match '^-[^-]*f[^-]*$' -and $word -notmatch '^-o.+')) {
                        $force = $true
                    }
                    if ($word -eq '--mirror') { $force = $true }
                    # A delete push is as destructive to a protected ref as a
                    # force-push, so it earns the same treatment. Git resolves any
                    # unique prefix of --delete (--de through --delete) to the
                    # option, so match the whole range; --d alone is ambiguous with
                    # --dry-run and rejected by git, and the ^--de... anchor never
                    # matches --dry-run or --no-delete. -d and the clustered short
                    # form (-fd) are matched like -f, with the same -o<value> guard
                    # so `-od` (a push-option) is not mistaken for a delete.
                    if ($word -match '^--de(l(e(t(e)?)?)?)?$' -or
                        ($word -match '^-[^-]*d[^-]*$' -and $word -notmatch '^-o.+')) {
                        $delete = $true
                    }
                    if ($word -eq '--repo') { $repositoryNamed = $true }
                    if ($word -like '--repo=*') { $repositoryNamed = $true }
                    if ($word -in $optionsWithValues) { $skipOptionValue = $true }
                    continue
                }
                $positionals.Add($word)
            }

            $refspecStart = if ($repositoryNamed) { 0 } else { 1 }
            $hasExplicitDestination = $positionals.Count -gt $refspecStart
            $refspecs = if ($hasExplicitDestination) {
                $positionals.GetRange($refspecStart, $positionals.Count - $refspecStart)
            } else {
                [System.Collections.Generic.List[string]]::new()
            }
            if (@($refspecs | Where-Object { $_.StartsWith('+') }).Count -gt 0) { $force = $true }

            # A delete with no explicit ref is rejected by git itself ("--delete
            # doesn't make sense without any refs"), so only the force path - which
            # can still resolve a destination through push.default - needs the
            # implicit-destination guard.
            if ($force -and -not $hasExplicitDestination) {
                return 'force-push has no explicit destination. Name the remote and task ref (for example: origin HEAD:refs/heads/feature/123-fix).'
            }

            foreach ($refspec in $refspecs) {
                $destination = $refspec.TrimStart('+')
                $colon = $destination.LastIndexOf(':')
                $emptySource = $false
                if ($colon -ge 0) {
                    $emptySource = [string]::IsNullOrEmpty($destination.Substring(0, $colon))
                    $destination = $destination.Substring($colon + 1)
                }
                $destination = $destination -replace '^refs/heads/', ''

                # The colon form of a delete (`:main`) has an empty left-hand side,
                # so it is a deletion even with no --delete flag. A --delete flag
                # makes every refspec a deletion regardless of its shape. A refspec
                # that is neither a delete nor a force is a plain (fast-forward)
                # push and stays out of scope, even to a protected branch.
                $refspecIsDelete = $delete -or $emptySource

                if ($destination -in $protectedBranches) {
                    if ($refspecIsDelete) {
                        return 'delete of a protected branch. Delete a merged task branch instead, and let the PR flow retire the ref.'
                    }
                    if ($force) {
                        return 'force-push to a protected branch. Push a task branch and open a PR instead.'
                    }
                }
                if ($destination -in @('HEAD', '@') -or $destination.Contains('*')) {
                    if ($refspecIsDelete) {
                        return 'delete destination is still implicit or spans multiple refs. Name one explicit task branch to delete.'
                    }
                    if ($force) {
                        return 'force-push destination is still implicit or spans multiple refs. Name one explicit task branch destination.'
                    }
                }
            }
        }
    }

    return $null
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

        # Force pushes must expose their destination instead of resolving it
        # through branch upstream + push.default. Lease protection reduces the
        # race window but does not make an implicit or protected ref safe. A
        # delete push to a protected branch is caught by the same parser: it is
        # every bit as destructive to the ref as a force-push.
        $unsafePush = Get-UnsafePushReason $cmd
        if ($unsafePush) { Deny $unsafePush }

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
