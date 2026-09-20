#!/usr/bin/env pwsh
<#
  Proves the CI fail-closed Gitleaks integrity check.

  Behaviour:
    - "Good" tarball: hardcoded SHA256 must match, tarball must extract,
      and the extracted gitleaks binary must exist.
    - "Corrupt" tarball: digest mismatch must be detected (fail-closed).
      This script treats that mismatch as expected and continues.

  Exit code: 0 when both assertions pass; 1 otherwise.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$version = '8.21.2'
$tarballName = "gitleaks_${version}_linux_x64.tar.gz"
$url = "https://github.com/gitleaks/gitleaks/releases/download/v${version}/${tarballName}"

# Hardcoded, reviewed constant (must match the workflow).
$expectedSha256 = '5BC41815076E6ED6EF8FBECC9D9B75BCAE31F39029CEB55DA08086315316E3BA'

function Assert-Sha256 {
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )
    $actual = (Get-FileHash -Algorithm SHA256 -Path $Path).Hash
    if ($actual.ToUpperInvariant() -ne $expectedSha256.ToUpperInvariant()) {
        throw "SHA256 mismatch for $Path (expected=$expectedSha256 actual=$actual)"
    }
}

function Extract-Gitleaks {
    param(
        [Parameter(Mandatory = $true)][string]$TarballPath,
        [Parameter(Mandatory = $true)][string]$DestinationDir
    )

    if (-not (Get-Command tar -ErrorAction SilentlyContinue)) {
        throw "Required command 'tar' was not found on PATH."
    }

    New-Item -ItemType Directory -Force -Path $DestinationDir | Out-Null

    # Extract only the gitleaks binary from the tarball.
    tar -xzf $TarballPath -C $DestinationDir gitleaks | Out-Null

    $bin = Join-Path $DestinationDir 'gitleaks'
    if (-not (Test-Path -LiteralPath $bin)) {
        throw "Expected extracted binary not found: $bin"
    }
    $len = (Get-Item -LiteralPath $bin).Length
    if ($len -le 0) {
        throw "Extracted binary exists but is empty: $bin"
    }

    return $bin
}

function Corrupt-FileByOneByte {
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$TargetPath
    )

    Copy-Item -LiteralPath $SourcePath -Destination $TargetPath -Force
    $bytes = [System.IO.File]::ReadAllBytes($TargetPath)
    $bytes[0] = $bytes[0] -bxor 0xFF
    [System.IO.File]::WriteAllBytes($TargetPath, $bytes)
}

$tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("gitleaks-integrity-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tmpRoot | Out-Null

try {
    $goodTar = Join-Path $tmpRoot $tarballName
    $goodExtractDir = Join-Path $tmpRoot 'good-extract'
    $corruptTar = Join-Path $tmpRoot ('corrupt-' + $tarballName)
    $corruptExtractDir = Join-Path $tmpRoot 'corrupt-extract'

    Write-Host "Downloading gitleaks tarball..."
    Invoke-WebRequest -Uri $url -OutFile $goodTar

    Write-Host "Good case: digest matches, extraction succeeds."
    Assert-Sha256 -Path $goodTar
    $null = Extract-Gitleaks -TarballPath $goodTar -DestinationDir $goodExtractDir

    Write-Host "Corrupt case: digest mismatch is detected (fail-closed)."
    Corrupt-FileByOneByte -SourcePath $goodTar -TargetPath $corruptTar

    $threw = $false
    try {
        Assert-Sha256 -Path $corruptTar | Out-Null
    } catch {
        $threw = $true
    }

    if (-not $threw) {
        throw "Corrupt tarball SHA256 mismatch was NOT detected."
    }

    # Extraction should never be attempted in the workflow on mismatch; we
    # don't extract here either. The mismatch assertion is the evidence.
    $null = $corruptExtractDir

    Write-Host 'Integrity checks passed (good+corrupt).'
    exit 0
}
finally {
    Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
}

