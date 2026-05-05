#!/bin/bash

# JoyCon2Mac Build Script
# Phase 1 - BLE Connection & IMU Init

set -e  # Exit on error

echo "╔════════════════════════════════════════════════════════╗"
echo "║         JoyCon2Mac - Build Script                     ║"
echo "╚════════════════════════════════════════════════════════╝"
echo ""

# Check for CMake
if ! command -v cmake &> /dev/null; then
    echo "❌ CMake not found. Please install it:"
    echo "   brew install cmake"
    exit 1
fi

# Check for Xcode Command Line Tools
if ! xcode-select -p &> /dev/null; then
    echo "❌ Xcode Command Line Tools not found. Please install:"
    echo "   xcode-select --install"
    exit 1
fi

echo "✓ CMake found: $(cmake --version | head -n1)"
echo "✓ Xcode tools found"
echo ""

# Create build directory
if [ -d "build" ]; then
    echo "🗑️  Cleaning old build directory..."
    rm -rf build
fi

mkdir build
cd build

echo "⚙️  Configuring with CMake..."
cmake .. -DCMAKE_BUILD_TYPE=Release

echo ""
echo "🔨 Building..."
make -j$(sysctl -n hw.ncpu)

echo ""
echo "╔════════════════════════════════════════════════════════╗"
echo "║         Build Complete!                                ║"
echo "╚════════════════════════════════════════════════════════╝"
echo ""
echo "Executable: ./build/bin/joycon2mac"
echo ""
echo "To run:"
echo "  cd build/bin"
echo "  ./joycon2mac           # Compact output"
echo "  ./joycon2mac -v        # Verbose output"
echo ""
echo "Make sure your Joy-Con is in pairing mode (hold sync button)!"
