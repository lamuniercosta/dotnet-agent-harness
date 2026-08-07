#!/usr/bin/env pwsh
<#
  PostToolUse hook: format the file that was just edited.

  Keeps the working tree formatted as the agent works, so `dotnet format
  --verify-no-changes` (verify phase 8) does not fail at the end of a session
  over whitespace nobody chose.

  Non-blocking by design: always exits 0. A formatter that can fail a turn is a
  formatter that gets disabled.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'SilentlyContinue'

$raw = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }

try { $payload = ConvertFrom-Json -InputObject $raw } catch { exit 0 }
if (-not $payload) { exit 0 }

function Get-Prop {
    param($Object, [string[]]$Names)
    if (-not $Object) { return $null }
    $available = @($Object.PSObject.Properties.Name)
    foreach ($name in $Names) {
        if ($available -contains $name) { return $Object.$name }
    }
    return $null
}

function Get-EditedFiles {
    param($Payload, $ToolInput)
    $direct = Get-Prop $ToolInput @('file_path', 'filePath', 'path', 'target_file')
    if (-not [string]::IsNullOrWhiteSpace($direct)) { return @($direct) }

    $command = Get-Prop $ToolInput @('command', 'cmd')
    if ([string]::IsNullOrWhiteSpace($command)) { return @() }

    $paths = [System.Collections.Generic.List[string]]::new()
    foreach ($line in ($command -split "`r?`n")) {
        if ($line -match '^\*\*\*\s+(?:Add|Update|Delete) File:\s*(.+?)\s*$' -or
            $line -match '^\*\*\*\s+Move to:\s*(.+?)\s*$') {
            [void]$paths.Add($Matches[1])
        }
    }
    return $paths
}

function Resolve-HookPath {
    param([string]$Path, $Payload, $ToolInput)
    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    $cwd = Get-Prop $Payload @('cwd', 'working_directory', 'workingDirectory')
    if (-not $cwd) { $cwd = Get-Prop $ToolInput @('cwd', 'working_directory', 'workingDirectory') }
    if (-not $cwd) { return $Path }
    return [System.IO.Path]::GetFullPath($Path, $cwd)
}

$toolInput = Get-Prop $payload @('tool_input', 'toolInput', 'input', 'arguments')
foreach ($candidate in (Get-EditedFiles $payload $toolInput)) {
    $file = Resolve-HookPath $candidate $payload $toolInput
    if (-not (Test-Path -LiteralPath $file)) { continue }
    if ([System.IO.Path]::GetExtension($file) -ne '.cs') { continue }

    # Never format generated or vendored output.
    if (($file -replace '\\', '/') -match '/(bin|obj|node_modules)/') { continue }
    if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) { continue }

    # `dotnet format` needs a project or solution; find the nearest one upward.
    $dir = Split-Path -LiteralPath $file -Parent
    $project = $null
    while ($dir -and -not $project) {
        $found = @(Get-ChildItem -LiteralPath $dir -Filter '*.csproj' -File -ErrorAction SilentlyContinue)
        if ($found.Count -gt 0) { $project = $found[0].FullName; break }
        $parent = Split-Path -LiteralPath $dir -Parent
        if ($parent -eq $dir) { break }
        $dir = $parent
    }
    if (-not $project) { continue }

    # --include scopes the run to the single edited file; formatting the whole
    # project on every keystroke would be unusably slow on a large solution.
    & dotnet format $project --include $file --verbosity quiet 2>&1 | Out-Null
}

exit 0
