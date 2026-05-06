#!/bin/bash

set -e

echo "╔════════════════════════════════════════════════════════╗"
echo "║         Building DriverKit Extension via CMake         ║"
echo "╚════════════════════════════════════════════════════════╝"
echo ""

BUILD_DIR="build/xcode"
GENERATED_DIR="build/generated"
DRIVERKIT_SDK="$(xcrun --sdk driverkit --show-sdk-path)"

# Create build directory
mkdir -p "$BUILD_DIR"
mkdir -p "$GENERATED_DIR"

echo "Step 0: Generating DriverKit IIG sources..."
xcrun --sdk driverkit iig \
    --def VirtualJoyConDriver/VirtualJoyConDriver.iig \
    --header "$GENERATED_DIR/VirtualJoyConDriver.h" \
    --impl "$GENERATED_DIR/VirtualJoyConDriver.iig.cpp" \
    --framework-name local.joycon2mac.driver \
    --deployment-target 25.4 \
    -- \
    -x c++ \
    -std=c++17 \
    -D__IIG=1 \
    -isysroot "$DRIVERKIT_SDK"

mkdir -p "$GENERATED_DIR/local.joycon2mac.driver"
cp "$GENERATED_DIR/VirtualJoyConDriver.h" "$GENERATED_DIR/local.joycon2mac.driver/VirtualJoyConDriver.h"
cp "$GENERATED_DIR/VirtualJoyConDriver.h" "$GENERATED_DIR/local.joycon2mac.driver/VirtualJoyConUserClient.h"

# Generate Xcode project
echo "Step 1: Generating Xcode project..."
cmake -B "$BUILD_DIR" -G Xcode

# Compile the driver
echo "Step 2: Compiling driver..."
xcodebuild -project "$BUILD_DIR/JoyCon2Mac.xcodeproj" -target VirtualJoyConDriver -configuration Release CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO

echo "Step 3: Packaging dext bundle..."
PRODUCT_DIR="$BUILD_DIR/Release"
DRIVER_BINARY="$PRODUCT_DIR/libVirtualJoyConDriver.so"
# Apple's System Extensions overview requires the dext filename (without
# the .dext extension) to be exactly the dext's CFBundleIdentifier. sysextd
# looks for that file inside Contents/Library/SystemExtensions/ and returns
# "Extension not found in App bundle" if the names don't line up, even when
# the Info.plist is otherwise correct.
DEXT_DIR="$PRODUCT_DIR/local.joycon2mac.driver.dext"
DEXT_CONTENTS="$DEXT_DIR/Contents"
DEXT_MACOS="$DEXT_CONTENTS/MacOS"

if [ ! -f "$DRIVER_BINARY" ]; then
    echo "Expected DriverKit binary not found at $DRIVER_BINARY" >&2
    exit 1
fi

/bin/rm -rf "$DEXT_DIR"
# Also wipe any stale-named bundle from earlier builds so the app package
# doesn't end up with both copies side-by-side.
/bin/rm -rf "$PRODUCT_DIR/VirtualJoyConDriver.dext"
mkdir -p "$DEXT_MACOS"
# CFBundleExecutable must also match the bundle-id-derived name so the
# Mach-O inside the bundle can be located by the loader.
cp "$DRIVER_BINARY" "$DEXT_MACOS/local.joycon2mac.driver"
cat > "$DEXT_CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>local.joycon2mac.driver</string>
    <key>CFBundleIdentifier</key>
    <string>local.joycon2mac.driver</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>local.joycon2mac.driver</string>
    <key>CFBundlePackageType</key>
    <string>DEXT</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>2026.05.05</string>
    <!--
      macOS 15+ sysextd rejects any driver_extension Info.plist that does
      not carry OSBundleUsageDescription — the activation request fails
      with "extensions belonging to the com.apple.system_extension.
      driver_extension category require the presence of the
      'OSBundleUsageDescription' property". The string is shown in the
      System Settings approval prompt, so keep it human-readable.
    -->
    <key>OSBundleUsageDescription</key>
    <string>JoyCon2Mac Virtual HID Driver — exposes paired Joy-Con 2 controllers as a system gamepad and mouse so games, browsers, and macOS itself can use them as real HID devices.</string>
    <key>IOKitPersonalities</key>
    <dict>
        <key>VirtualJoyConDriver</key>
        <dict>
            <key>UserClientProperties</key>
            <dict>
                <key>IOClass</key>
                <string>IOUserUserClient</string>
                <key>IOUserClass</key>
                <string>VirtualJoyConUserClient</string>
            </dict>
            <key>CFBundleIdentifier</key>
            <string>local.joycon2mac.driver</string>
            <key>IOClass</key>
            <string>IOUserService</string>
            <key>IOMatchCategory</key>
            <string>VirtualJoyConDriver</string>
            <key>IOProviderClass</key>
            <string>IOUserResources</string>
            <key>IOResourceMatch</key>
            <string>IOKit</string>
            <key>IOUserClass</key>
            <string>VirtualJoyConDriver</string>
            <key>IOUserServerName</key>
            <string>local.joycon2mac.driver</string>
            <key>bConfigurationValue</key>
            <integer>1</integer>
            <key>bInterfaceNumber</key>
            <integer>0</integer>
            <key>idProduct</key>
            <integer>8192</integer>
            <key>idVendor</key>
            <integer>1363</integer>
        </dict>
    </dict>
</dict>
</plist>
PLIST

# Sign the driver
echo "Step 4: Signing driver..."
codesign -s - -f --entitlements VirtualJoyConDriver/VirtualJoyConDriver.entitlements "$DEXT_DIR"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  DriverKit Extension Built Successfully!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Location: $DEXT_DIR"
echo ""
echo "To install (with SIP disabled):"
echo "  sudo cp -r $BUILD_DIR/Release/VirtualJoyConDriver.dext /Library/SystemExtensions/"
echo "  sudo kmutil load -p /Library/SystemExtensions/VirtualJoyConDriver.dext"
echo ""
echo "To verify:"
echo "  sudo kmutil showloaded | grep VirtualJoyCon"
echo ""
