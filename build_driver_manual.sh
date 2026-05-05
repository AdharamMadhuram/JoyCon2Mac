#!/bin/bash

set -e

echo "╔════════════════════════════════════════════════════════╗"
echo "║      Building DriverKit Extension (Manual Build)      ║"
echo "╚════════════════════════════════════════════════════════╝"
echo ""

DRIVER_DIR="VirtualJoyConDriver"
BUILD_DIR="build/driver"
IIG_TOOL="/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/iig"
SDK_PATH="/Applications/Xcode.app/Contents/Developer/Platforms/DriverKit.platform/Developer/SDKs/DriverKit.sdk"

# Create build directory
mkdir -p "$BUILD_DIR"

echo "Step 1: Processing .iig file..."
$IIG_TOOL \
    --def "$DRIVER_DIR/VirtualJoyConDriver.iig" \
    --header "$BUILD_DIR/VirtualJoyConDriver.h" \
    --impl "$BUILD_DIR/VirtualJoyConDriver_Impl.h" \
    --framework HIDDriverKit

if [ ! -f "$BUILD_DIR/VirtualJoyConDriver.h" ]; then
    echo "✗ Failed to generate VirtualJoyConDriver.h"
    exit 1
fi

echo "✓ Generated VirtualJoyConDriver.h"

echo ""
echo "Step 2: Compiling driver..."
clang++ \
    -target arm64-apple-driverkit25.4 \
    -std=gnu++17 \
    -O3 \
    -fPIC \
    -I"$BUILD_DIR" \
    -I"$SDK_PATH/System/DriverKit/usr/include" \
    -isysroot "$SDK_PATH" \
    -c "$DRIVER_DIR/VirtualJoyConDriver.cpp" \
    -o "$BUILD_DIR/VirtualJoyConDriver.o"

echo "✓ Compiled VirtualJoyConDriver.cpp"

echo ""
echo "Step 3: Linking driver..."
clang++ \
    -target arm64-apple-driverkit25.4 \
    -dynamiclib \
    -Wl,-dylib \
    -Wl,-install_name,@rpath/VirtualJoyConDriver.dext/VirtualJoyConDriver \
    -isysroot "$SDK_PATH" \
    -L"$SDK_PATH/System/DriverKit/usr/lib" \
    -framework DriverKit \
    -framework HIDDriverKit \
    "$BUILD_DIR/VirtualJoyConDriver.o" \
    -o "$BUILD_DIR/VirtualJoyConDriver"

echo "✓ Linked driver"

echo ""
echo "Step 4: Creating .dext bundle..."
DEXT_DIR="$BUILD_DIR/VirtualJoyConDriver.dext"
mkdir -p "$DEXT_DIR"
cp "$BUILD_DIR/VirtualJoyConDriver" "$DEXT_DIR/"
cp "$DRIVER_DIR/Info.plist" "$DEXT_DIR/"

echo "✓ Created bundle"

echo ""
echo "Step 5: Signing driver..."
codesign -s - -f --entitlements "$DRIVER_DIR/VirtualJoyConDriver.entitlements" "$DEXT_DIR"

echo "✓ Signed driver"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  DriverKit Extension Built Successfully!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Location: $BUILD_DIR/VirtualJoyConDriver.dext"
echo ""
echo "To install (with SIP disabled):"
echo "  sudo cp -r $BUILD_DIR/VirtualJoyConDriver.dext /Library/SystemExtensions/"
echo "  sudo kmutil load -p /Library/SystemExtensions/VirtualJoyConDriver.dext"
echo ""
echo "To verify:"
echo "  sudo kmutil showloaded | grep VirtualJoyCon"
echo ""
