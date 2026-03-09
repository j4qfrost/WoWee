<#
.SYNOPSIS
    Clean rebuilds the wowee project (Windows equivalent of rebuild.sh).

.DESCRIPTION
    Removes the build directory, reconfigures from scratch, rebuilds, and
    creates a directory junction for the Data folder.
#>

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ScriptDir

function Ensure-Fsr2Sdk {
    $sdkDir = Join-Path $ScriptDir "extern\FidelityFX-FSR2"
    $sdkHeader = Join-Path $sdkDir "src\ffx-fsr2-api\ffx_fsr2.h"
    if (Test-Path $sdkHeader) { return }

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Warning "git not found; cannot auto-fetch AMD FSR2 SDK."
        return
    }

    Write-Host "Fetching AMD FidelityFX FSR2 SDK into $sdkDir ..."
    New-Item -ItemType Directory -Path (Join-Path $ScriptDir "extern") -Force | Out-Null
    & git clone --depth 1 https://github.com/GPUOpen-Effects/FidelityFX-FSR2.git $sdkDir
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Failed to clone AMD FSR2 SDK. Build will use internal fallback path."
    }
}

Write-Host "Clean rebuilding wowee..."
Ensure-Fsr2Sdk

# Remove build directory completely
if (Test-Path "build") {
    Write-Host "Removing old build directory..."
    Remove-Item -Recurse -Force "build"
}

# Create fresh build directory
New-Item -ItemType Directory -Path "build" | Out-Null
Set-Location "build"

# Configure with CMake
Write-Host "Configuring with CMake..."
& cmake .. -DCMAKE_BUILD_TYPE=Release
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

# Build with all cores
$numProcs = $env:NUMBER_OF_PROCESSORS
if (-not $numProcs) { $numProcs = 4 }
Write-Host "Building with $numProcs cores..."
& cmake --build . --parallel $numProcs
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

# Create Data junction in bin directory
Write-Host "Creating Data junction..."
$binData = Join-Path (Get-Location) "bin\Data"
if (-not (Test-Path $binData)) {
    $target = (Resolve-Path (Join-Path (Get-Location) "..\Data")).Path
    cmd /c mklink /J "$binData" "$target"
    Write-Host "  Created Data junction -> $target"
}

Write-Host ""
Write-Host "Clean build complete! Binary: build\bin\wowee.exe"
Write-Host "Run with: cd build\bin && .\wowee.exe"
