#!/usr/bin/env pwsh
# Runs the web/ frontend gates (ESLint, tsc --noEmit, Vitest, Vite build).
# Exits 1 when any step fails; 0 when all pass; 2 (SKIPPED) when disabled in harness.yml
# or no web/ file changed.

[CmdletBinding()]
param(
    [string]$BaseRef = '',
    [switch]$All,
    [switch]$Help
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_gate-common.ps1')

if ($Help) {
    Write-Output @"
Usage: run-web-gates.ps1 [OPTIONS]

Runs the web/ frontend gates: ESLint, TypeScript type checking, Vitest,
and Vite build. Exits 0 when all pass, 1 on any failure, 2 when disabled
in harness.yml or no web/ files changed.

OPTIONS:
  -BaseRef <ref>    Base branch/commit for diff check (default: resolved from git)
  -All              Run gates regardless of diff (useful for checking whole frontend)
  -Help             Show this help

EXAMPLES:
  ./scripts/run-web-gates.ps1
  ./scripts/run-web-gates.ps1 -All
  ./scripts/run-web-gates.ps1 -BaseRef origin/main
"@
    exit 0
}

$repoRoot = Get-RepoRoot

# Check if web gates are enabled in harness.yml
if (-not (Get-HarnessValue 'gates.web.enabled' -RepoRoot $repoRoot)) {
    Write-Host 'Web gates: SKIPPED - disabled in harness.yml (gates.web.enabled: false).'
    exit 2
}

$webDir = Join-Path $repoRoot 'web'

# Check if web/package.json exists
if (-not (Test-Path (Join-Path $webDir 'package.json'))) {
    Write-Host 'Web gates: FAIL - gates.web.enabled is true but web/package.json is missing.'
    exit 1
}

# Check if web/ files have changed (unless -All is specified)
if (-not $All) {
    $ref = Resolve-BaseRef -RepoRoot $repoRoot -Explicit $BaseRef

    # Compute merge base exactly as Get-ChangedCsFiles does
    $mergeBase = git -C $repoRoot merge-base HEAD $ref 2>$null
    if (-not $mergeBase) {
        $mergeBase = git -C $repoRoot merge-base HEAD origin/$ref 2>$null
    }
    if (-not $mergeBase) {
        Write-Warning "Could not resolve merge base; falling back to diff vs HEAD"
        $mergeBase = 'HEAD'
    }

    # Get changed files in web/ directory
    $changedFiles = @(
        git -C $repoRoot diff --name-only --diff-filter=ACMRT $mergeBase |
            ForEach-Object { $_.Replace('\', '/') } |
            Where-Object { $_ -match '^web/' }
    )

    # Also include untracked files under web/
    $untrackedFiles = @(
        git -C $repoRoot ls-files --others --exclude-standard -- web |
            ForEach-Object { $_.Replace('\', '/') } |
            Where-Object { $_ -match '^web/' }
    )

    $allWebFiles = @($changedFiles) + @($untrackedFiles)

    if ($allWebFiles.Count -eq 0) {
        Write-Host 'Web gates: SKIPPED - no web/ files changed (re-run with -All to check the whole frontend).'
        exit 2
    }
}

# Run gates inside the web directory
Push-Location $webDir
try {
    # If node_modules is missing, run npm ci first
    if (-not (Test-Path 'node_modules')) {
        Write-Host 'Web gates: running npm ci'
        npm ci
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Web gates: FAIL - npm ci exited $LASTEXITCODE."
            exit 1
        }
    }

    # Run lint
    Write-Host 'Web gates: running lint'
    npm run lint
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Web gates: FAIL - lint exited $LASTEXITCODE."
        exit 1
    }

    # Run TypeScript type check
    Write-Host 'Web gates: running tsc --noEmit'
    npx tsc --noEmit
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Web gates: FAIL - tsc --noEmit exited $LASTEXITCODE."
        exit 1
    }

    # Run tests
    Write-Host 'Web gates: running test:run'
    npm run test:run
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Web gates: FAIL - test:run exited $LASTEXITCODE."
        exit 1
    }

    # Run build
    Write-Host 'Web gates: running build'
    npm run build
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Web gates: FAIL - build exited $LASTEXITCODE."
        exit 1
    }

    # All passed
    Write-Host 'Web gates: PASS (lint, tsc, vitest, build).'
    exit 0
}
finally {
    Pop-Location
}
