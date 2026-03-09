#!/bin/bash
# Wowee Build Script - Ensures no stale binaries

set -e  # Exit on error

cd "$(dirname "$0")"

ensure_fsr2_sdk() {
    local sdk_dir="extern/FidelityFX-FSR2"
    local sdk_header="$sdk_dir/src/ffx-fsr2-api/ffx_fsr2.h"
    if [ -f "$sdk_header" ]; then
        return
    fi
    if ! command -v git >/dev/null 2>&1; then
        echo "Warning: git not found; cannot auto-fetch AMD FSR2 SDK."
        return
    fi
    echo "Fetching AMD FidelityFX FSR2 SDK into $sdk_dir ..."
    mkdir -p extern
    git clone --depth 1 https://github.com/GPUOpen-Effects/FidelityFX-FSR2.git "$sdk_dir" || {
        echo "Warning: failed to clone AMD FSR2 SDK. Build will use internal fallback path."
    }
}

echo "Building wowee..."
ensure_fsr2_sdk

# Create build directory if it doesn't exist
mkdir -p build
cd build

# Configure with cmake
echo "Configuring with CMake..."
cmake .. -DCMAKE_BUILD_TYPE=Release

# Build with all cores
NPROC=$(nproc 2>/dev/null || sysctl -n hw.logicalcpu 2>/dev/null || echo 4)
echo "Building with $NPROC cores..."
cmake --build . --parallel "$NPROC"

# Ensure Data symlink exists in bin directory
cd bin
if [ ! -e Data ]; then
    ln -s ../../Data Data
fi
cd ..

echo ""
echo "Build complete! Binary: build/bin/wowee"
echo "Run with: cd build/bin && ./wowee"
