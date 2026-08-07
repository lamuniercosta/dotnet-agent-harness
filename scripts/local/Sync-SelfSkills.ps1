#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Generates the harness repository's local Claude and Codex skill discovery copies.

.DESCRIPTION
  This is deliberately narrower than install.ps1: it projects canonical skills
  into this checkout's host discovery trees and records those generated names in
  an ignored ownership manifest. It never installs gates, hooks, templates, or
  consumer configuration.

  Refresh changes only manifest-owned skill names. An unowned directory that
  collides with a canonical name aborts the entire sync before any mutation.

.PARAMETER Clean
  Removes only manifest-owned discovery copies and the ownership manifest.

.PARAMETER RepoRoot
  Harness source checkout to operate on. Defaults to the checkout containing
  this script; exposed so the self-test can exercise an isolated fixture.
#>

[CmdletBinding()]
param(
    [switch]$Clean,

    [string]$RepoRoot = (Join-Path $PSScriptRoot '../..')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '../_skill-rendering.ps1')
. (Join-Path $PSScriptRoot '_json-property.ps1')

if (-not (Test-Path -LiteralPath $RepoRoot -PathType Container)) {
    throw "Harness repository not found: $RepoRoot"
}

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$skillsSource = Join-Path $RepoRoot 'skills'
$manifestPath = Join-Path $RepoRoot 'scripts/local/.self-skills-manifest.json'
$reservedNames = @('start-issue')
$hostDefinitions = @(
    [PSCustomObject]@{
        Name = 'claude'
        Destination = Join-Path $RepoRoot '.claude/skills'
        Codex = $false
    },
    [PSCustomObject]@{
        Name = 'codex'
        Destination = Join-Path $RepoRoot '.agents/skills'
        Codex = $true
    }
)

function Assert-SkillName {
    param([string]$Name, [string]$Source)

    if ([string]::IsNullOrWhiteSpace($Name) -or $Name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
        throw "Invalid skill name '$Name' in $Source."
    }
}

function Get-EmptyOwnership {
    return [ordered]@{
        claude = @()
        codex = @()
    }
}

function Read-OwnershipManifest {
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        return Get-EmptyOwnership
    }

    try {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    }
    catch {
        throw "Ownership manifest is not valid JSON: $manifestPath"
    }

    $version = Get-JsonPath -Object $manifest -Path @('version')
    $hosts = Get-JsonPath -Object $manifest -Path @('hosts')
    if ($version -ne 1 -or $null -eq $hosts) {
        throw "Unsupported ownership manifest format: $manifestPath"
    }

    $ownership = Get-EmptyOwnership
    foreach ($hostDefinition in $hostDefinitions) {
        $values = Get-JsonPath -Object $hosts -Path @($hostDefinition.Name)
        if ($null -eq $values) {
            throw "Ownership manifest is missing hosts.$($hostDefinition.Name): $manifestPath"
        }

        $names = @($values | ForEach-Object { [string]$_ } | Sort-Object -Unique)
        foreach ($name in $names) {
            Assert-SkillName -Name $name -Source $manifestPath
            if ($name -in $reservedNames) {
                throw "Ownership manifest must never own the '$name' authored override."
            }
        }
        $ownership[$hostDefinition.Name] = $names
    }

    return $ownership
}

function Get-ManifestContent {
    param([string[]]$SkillNames)

    $manifest = [ordered]@{
        version = 1
        hosts = [ordered]@{
            claude = @($SkillNames)
            codex = @($SkillNames)
        }
    }

    return ($manifest | ConvertTo-Json -Depth 4) + [Environment]::NewLine
}

function Get-RelativeEntries {
    param([string]$Path, [ValidateSet('File', 'Directory')][string]$Kind)

    $items = if ($Kind -eq 'File') {
        @(Get-ChildItem -LiteralPath $Path -File -Recurse -Force)
    }
    else {
        @(Get-ChildItem -LiteralPath $Path -Directory -Recurse -Force)
    }

    return @($items | ForEach-Object {
            $_.FullName.Substring($Path.Length).TrimStart('\', '/')
        } | Sort-Object)
}

function Test-DirectoryContentEqual {
    param([string]$Left, [string]$Right)

    if (-not (Test-Path -LiteralPath $Left -PathType Container) -or
        -not (Test-Path -LiteralPath $Right -PathType Container)) {
        return $false
    }

    $leftDirectories = @(Get-RelativeEntries -Path $Left -Kind Directory)
    $rightDirectories = @(Get-RelativeEntries -Path $Right -Kind Directory)
    if (($leftDirectories -join "`n") -cne ($rightDirectories -join "`n")) {
        return $false
    }

    $leftFiles = @(Get-RelativeEntries -Path $Left -Kind File)
    $rightFiles = @(Get-RelativeEntries -Path $Right -Kind File)
    if (($leftFiles -join "`n") -cne ($rightFiles -join "`n")) {
        return $false
    }

    foreach ($relativePath in $leftFiles) {
        $leftBytes = [System.IO.File]::ReadAllBytes((Join-Path $Left $relativePath))
        $rightBytes = [System.IO.File]::ReadAllBytes((Join-Path $Right $relativePath))
        if (-not [System.Linq.Enumerable]::SequenceEqual[byte]($leftBytes, $rightBytes)) {
            return $false
        }
    }

    return $true
}

function Get-OwnedSkillPath {
    param([string]$Destination, [string]$Name)

    Assert-SkillName -Name $Name -Source $manifestPath
    return Join-Path $Destination $Name
}

function Write-ReloadNotice {
    Write-Host ''
    Write-Host 'Reload Codex and Claude Code before using the refreshed skill commands.' -ForegroundColor Yellow
}

$ownership = Read-OwnershipManifest

if ($Clean) {
    $removed = 0
    foreach ($hostDefinition in $hostDefinitions) {
        foreach ($name in @($ownership[$hostDefinition.Name])) {
            $ownedPath = Get-OwnedSkillPath -Destination $hostDefinition.Destination -Name $name
            if (Test-Path -LiteralPath $ownedPath) {
                Remove-Item -LiteralPath $ownedPath -Recurse -Force
                $removed++
                Write-Host "  removed  $($hostDefinition.Name)/$name"
            }
        }
    }

    if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
        Remove-Item -LiteralPath $manifestPath -Force
    }

    if ($removed -eq 0) {
        Write-Host 'Self-development skills already clean; no semantic changes.'
    }
    else {
        Write-Host "Removed $removed manifest-owned discovery copies."
    }
    Write-ReloadNotice
    exit 0
}

if (-not (Test-Path -LiteralPath $skillsSource -PathType Container)) {
    throw "Canonical skills directory not found: $skillsSource"
}

$skillNames = @(Get-ChildItem -LiteralPath $skillsSource -Directory |
        ForEach-Object { $_.Name } |
        Sort-Object)
if ($skillNames.Count -eq 0) {
    throw "No canonical skills found in $skillsSource"
}

foreach ($name in $skillNames) {
    Assert-SkillName -Name $name -Source $skillsSource
    if ($name -in $reservedNames) {
        throw "Canonical skill '$name' collides with a reserved authored override."
    }
}

# Preflight every host before staging or mutating anything. The manifest is the
# sole ownership authority; an existing canonical-name directory absent from it
# is foreign and must survive byte-identical.
foreach ($hostDefinition in $hostDefinitions) {
    $ownedNames = @($ownership[$hostDefinition.Name])
    foreach ($name in $skillNames) {
        $destination = Get-OwnedSkillPath -Destination $hostDefinition.Destination -Name $name
        if ((Test-Path -LiteralPath $destination) -and $name -notin $ownedNames) {
            throw "Cannot generate $($hostDefinition.Name) skill '$name': $destination exists but is not manifest-owned. No files were changed."
        }
    }
}

$stagingRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('harness-self-skills-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stagingRoot -Force | Out-Null

try {
    foreach ($hostDefinition in $hostDefinitions) {
        $hostStage = Join-Path $stagingRoot $hostDefinition.Name
        New-Item -ItemType Directory -Path $hostStage -Force | Out-Null
        foreach ($name in $skillNames) {
            Copy-Item -LiteralPath (Join-Path $skillsSource $name) -Destination (Join-Path $hostStage $name) -Recurse -Force
        }
        if ($hostDefinition.Codex) {
            Convert-CodexSkillReferences -SkillsSource $skillsSource -CodexSkills $hostStage
        }
    }

    $added = 0
    $updated = 0
    $removed = 0

    foreach ($hostDefinition in $hostDefinitions) {
        New-Item -ItemType Directory -Path $hostDefinition.Destination -Force | Out-Null
        $hostStage = Join-Path $stagingRoot $hostDefinition.Name
        $ownedNames = @($ownership[$hostDefinition.Name])

        foreach ($obsoleteName in @($ownedNames | Where-Object { $_ -notin $skillNames })) {
            $obsoletePath = Get-OwnedSkillPath -Destination $hostDefinition.Destination -Name $obsoleteName
            if (Test-Path -LiteralPath $obsoletePath) {
                Remove-Item -LiteralPath $obsoletePath -Recurse -Force
                $removed++
                Write-Host "  removed  $($hostDefinition.Name)/$obsoleteName"
            }
        }

        foreach ($name in $skillNames) {
            $renderedPath = Join-Path $hostStage $name
            $destination = Get-OwnedSkillPath -Destination $hostDefinition.Destination -Name $name

            if (Test-DirectoryContentEqual -Left $renderedPath -Right $destination) {
                continue
            }

            $existed = Test-Path -LiteralPath $destination
            if ($existed) {
                Remove-Item -LiteralPath $destination -Recurse -Force
            }
            Copy-Item -LiteralPath $renderedPath -Destination $destination -Recurse -Force

            if ($existed) {
                $updated++
                Write-Host "  updated  $($hostDefinition.Name)/$name"
            }
            else {
                $added++
                Write-Host "  added    $($hostDefinition.Name)/$name"
            }
        }
    }

    $manifestContent = Get-ManifestContent -SkillNames $skillNames
    $existingManifest = if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
        Get-Content -LiteralPath $manifestPath -Raw
    }
    else { $null }

    if ($existingManifest -cne $manifestContent) {
        Set-Content -LiteralPath $manifestPath -Value $manifestContent -Encoding UTF8 -NoNewline
    }

    if (($added + $updated + $removed) -eq 0 -and $existingManifest -ceq $manifestContent) {
        Write-Host 'Self-development skills are current; no semantic changes.'
    }
    else {
        Write-Host "Synced self-development skills: $added added, $updated updated, $removed removed."
    }
    Write-ReloadNotice
}
finally {
    if (Test-Path -LiteralPath $stagingRoot) {
        Remove-Item -LiteralPath $stagingRoot -Recurse -Force
    }
}
