# Build-Release.ps1
# Builds a release package for the ETHOS Mapping Widget.
#
# 1. Copies all source files from src/ into build/release/ with ETHOS layout.
# 2. Creates a ZIP archive ready to extract onto the radio SD card.
# 3. Deploys the release into the local RADIO/ simulator directory.
#
# Usage:  .\build\Build-Release.ps1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Paths ---

$repoRoot   = Split-Path -Parent $PSScriptRoot
$srcDir     = Join-Path $repoRoot 'src'
$buildDir   = Join-Path $repoRoot 'build'
$releaseDir = Join-Path $buildDir 'release'
$radioDir   = Join-Path $repoRoot 'RADIO'

# --- Version ---

# Extract WIDGET_VERSION from main.lua (e.g. "2.0-beta1")
$mainLua = Join-Path (Join-Path (Join-Path $srcDir 'scripts') 'ethosmaps') 'main.lua'
$widgetVersion = 'unknown'
foreach ($line in (Get-Content $mainLua)) {
    if ($line -match 'local\s+WIDGET_VERSION\s*=\s*"([^"]+)"') {
        $widgetVersion = $Matches[1]
        break
    }
}

# Short commit hash for traceability
$commitId = git -C $repoRoot rev-parse --short HEAD 2>$null
if (-not $commitId) { $commitId = 'nogit' }
$commitId = $commitId.Trim()

$zipName = 'ETHOSMappingWidget-' + $widgetVersion + '-' + $commitId + '.zip'
$zipPath = Join-Path $buildDir $zipName

# --- Clean ---

Write-Host '=== ETHOS Mapping Widget Build ===' -ForegroundColor Cyan
Write-Host "Version : $widgetVersion ($commitId)"
Write-Host "Source  : $srcDir"
Write-Host "Release : $releaseDir"
Write-Host ''

if (Test-Path $releaseDir) {
    Write-Host 'Cleaning previous release...' -ForegroundColor Yellow
    Remove-Item -Recurse -Force $releaseDir
}
if (Test-Path $zipPath) {
    Remove-Item -Force $zipPath
}

# --- Stage ---

Write-Host 'Staging source files...' -ForegroundColor Green

# Bitmaps
$bmpSrc = Join-Path (Join-Path (Join-Path $srcDir 'bitmaps') 'ethosmaps') 'bitmaps'
$bmpDst = Join-Path (Join-Path (Join-Path $releaseDir 'bitmaps') 'ethosmaps') 'bitmaps'
New-Item -ItemType Directory -Path $bmpDst -Force | Out-Null
Copy-Item -Path (Join-Path $bmpSrc '*') -Destination $bmpDst -Recurse

# Scripts main.lua
$scriptSrc = Join-Path (Join-Path $srcDir 'scripts') 'ethosmaps'
$scriptDst = Join-Path (Join-Path $releaseDir 'scripts') 'ethosmaps'
New-Item -ItemType Directory -Path $scriptDst -Force | Out-Null
Copy-Item -Path (Join-Path $scriptSrc 'main.lua') -Destination $scriptDst

# Scripts lib/
$libDst = Join-Path $scriptDst 'lib'
New-Item -ItemType Directory -Path $libDst -Force | Out-Null
Copy-Item -Path (Join-Path (Join-Path $scriptSrc 'lib') '*') -Destination $libDst -Recurse

# Scripts audio/
$audioDst = Join-Path $scriptDst 'audio'
New-Item -ItemType Directory -Path $audioDst -Force | Out-Null
Copy-Item -Path (Join-Path (Join-Path $scriptSrc 'audio') '*') -Destination $audioDst -Recurse

$fileCount = (Get-ChildItem -Path $releaseDir -Recurse -File).Count
Write-Host "Staged $fileCount files." -ForegroundColor Green

# --- ZIP ---

Write-Host "Creating ZIP: $zipName" -ForegroundColor Green
Compress-Archive -Path (Join-Path $releaseDir '*') -DestinationPath $zipPath -Force

$zipSizeKB = [math]::Round((Get-Item $zipPath).Length / 1KB, 1)
Write-Host "ZIP created ($zipSizeKB KB)" -ForegroundColor Green

# --- Deploy to RADIO ---

Write-Host 'Deploying to RADIO/ simulator...' -ForegroundColor Green

$radioBmpDst = Join-Path (Join-Path (Join-Path $radioDir 'bitmaps') 'ethosmaps') 'bitmaps'
New-Item -ItemType Directory -Path $radioBmpDst -Force | Out-Null
Copy-Item -Path (Join-Path $bmpDst '*') -Destination $radioBmpDst -Force -Recurse

$radioScriptDst = Join-Path (Join-Path $radioDir 'scripts') 'ethosmaps'
New-Item -ItemType Directory -Path $radioScriptDst -Force | Out-Null
Copy-Item -Path (Join-Path $scriptDst 'main.lua') -Destination $radioScriptDst -Force

$radioLibDst = Join-Path $radioScriptDst 'lib'
New-Item -ItemType Directory -Path $radioLibDst -Force | Out-Null
Copy-Item -Path (Join-Path $libDst '*') -Destination $radioLibDst -Force -Recurse

$radioAudioDst = Join-Path $radioScriptDst 'audio'
New-Item -ItemType Directory -Path $radioAudioDst -Force | Out-Null
Copy-Item -Path (Join-Path $audioDst '*') -Destination $radioAudioDst -Force -Recurse

Write-Host ''
Write-Host '=== Build complete ===' -ForegroundColor Cyan
Write-Host "  Release : $releaseDir"
Write-Host "  ZIP     : $zipPath"
Write-Host "  RADIO   : $radioDir"
