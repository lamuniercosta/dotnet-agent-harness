#!/usr/bin/env pwsh
<#
  Regenerates the `paths:` frontmatter in rules/vendor/*.md from their `globs:`.

  The two platforms both have native glob-scoped rules, but with different keys
  and - crucially - different semantics:

    Cursor   `globs: *.cs`   matches any .cs file anywhere
    Claude   `paths: *.cs`   matches .cs files in the project ROOT only
                             (`**/*.cs` is what matches everywhere)

  A naive copy of the glob list would therefore silently narrow every vendored
  rule to root-level files, and it would look like it worked. This script does
  the translation, so `paths:` is derived rather than hand-maintained.

  Run after editing any vendored rule's globs. lint-harness.yml checks the
  output is current.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    # scripts -> dotnet -> packs -> repo root
    [string]$VendorDir = (Join-Path (Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent) 'rules/vendor'),
    [switch]$Check
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Upstream ships these two with no globs at all. An empty `paths:` is invalid
# YAML and would make the rule unconditionally always-on, so they get the files
# they actually concern.
$fallback = @{
    'aaron-dotnet-tools-consuming.md'  = @('**/.config/dotnet-tools.json', '**/dotnet-tools.json')
    'aaron-dotnet-tools-publishing.md' = @('**/*.csproj', '**/*.nuspec')
}

function ConvertTo-ClaudePath {
    param([string]$Glob)

    $g = $Glob.Trim()
    if (-not $g) { return $null }
    if ($g.StartsWith('**') -or $g.StartsWith('/')) { return $g }
    return "**/$g"
}

$drift = 0

foreach ($file in Get-ChildItem -LiteralPath $VendorDir -Filter 'aaron-*.md' | Sort-Object Name) {
    $lines = [System.Collections.Generic.List[string]](Get-Content -LiteralPath $file.FullName)

    # Strip any existing paths block so the script is idempotent.
    $cleaned = [System.Collections.Generic.List[string]]::new()
    $inBlock = $false
    foreach ($line in $lines) {
        if ($line -match '^paths:') { $inBlock = $true; continue }
        if ($inBlock) {
            if ($line -match '^\s*-\s' -or $line.Trim() -eq '') { continue }
            $inBlock = $false
        }
        [void]$cleaned.Add($line)
    }

    $globsIndex = $cleaned.FindIndex({ param($l) $l -match '^globs:' })
    if ($globsIndex -lt 0) {
        Write-Warning "$($file.Name): no globs: line, skipping."
        continue
    }

    $raw = ($cleaned[$globsIndex] -replace '^globs:\s*', '').Trim()
    $patterns = @()
    if ($raw) {
        $patterns = @($raw -split ',' | ForEach-Object { ConvertTo-ClaudePath $_ } | Where-Object { $_ })
    }
    if ($patterns.Count -eq 0) {
        $patterns = $fallback[$file.Name]
        if (-not $patterns) {
            Write-Warning "$($file.Name): no globs and no fallback, skipping."
            continue
        }
    }

    $block = @('paths:') + ($patterns | ForEach-Object { "  - `"$_`"" })
    $cleaned.InsertRange($globsIndex + 1, [string[]]$block)

    $new = ($cleaned -join "`n")
    $old = Get-Content -LiteralPath $file.FullName -Raw

    if ($new.TrimEnd() -ne $old.TrimEnd()) {
        $drift++
        if ($Check) {
            Write-Host "  DRIFT  $($file.Name) - paths: is stale" -ForegroundColor Red
        }
        elseif ($PSCmdlet.ShouldProcess($file.Name, 'regenerate paths:')) {
            Set-Content -LiteralPath $file.FullName -Value $new -Encoding UTF8
            Write-Host ("  updated  {0,-45} {1} paths" -f $file.Name, $patterns.Count)
        }
    }
    else {
        Write-Host ("  ok       {0,-45} {1} paths" -f $file.Name, $patterns.Count)
    }
}

if ($Check -and $drift -gt 0) {
    Write-Host ''
    Write-Host "$drift vendored rule(s) have stale paths:. Run Sync-VendorRulePaths.ps1." -ForegroundColor Red
    exit 1
}
exit 0
