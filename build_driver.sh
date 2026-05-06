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
cp "$GENERATED_DIR/VirtualJoyConDriver.h" "$GENERATED_DIR/local.joycon2mac.driver/VirtualJoyConHIDDevice.h"
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
# CFBundleVersion must increase on every rebuild so sysextd/kernelmanagerd
# actually treats the freshly-built dext as an upgrade instead of getting
# stuck in "terminating for upgrade via delegate" when the on-disk
# staged bundle has the same version. Use BUILD_STAMP (current epoch) so
# every build is unique.
BUILD_STAMP=$(date +%Y.%m.%d.%H%M%S)
cat > "$DEXT_CONTENTS/Info.plist" <<PLIST
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
    <!--
      CFBundleIdentifierKernel tells kernelmanagerd which kernel KPI the
      dext's in-kernel half binds to. Missing this makes the loader treat
      the extension as a "codeless" kext that never launches the DEXT
      process — exactly the symptom we saw before the restructure
      (systemextensionsctl shows [activated enabled] but no os_log output
      from Start_Impl and no IOHIDDevice nub appears in ioreg).
    -->
    <key>CFBundleIdentifierKernel</key>
    <string>com.apple.kpi.iokit</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>local.joycon2mac.driver</string>
    <key>CFBundlePackageType</key>
    <string>DEXT</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_STAMP}</string>
    <!--
      macOS 15+ sysextd rejects any driver_extension Info.plist that does
      not carry OSBundleUsageDescription. The string is shown in the
      System Settings approval prompt, so keep it human-readable.
    -->
    <key>OSBundleUsageDescription</key>
    <string>JoyCon2Mac Virtual HID Driver — exposes paired Joy-Con 2 controllers as a system gamepad and mouse so games, browsers, and macOS itself can use them as real HID devices.</string>
    <!--
      Personality layout follows the Karabiner-DriverKit-VirtualHIDDevice
      reference (pqrs-org/Karabiner-DriverKit-VirtualHIDDevice, Info.plist.in)
      because that's the verified working pattern for a virtual HID dext on
      modern macOS. Content was rephrased for compliance with licensing
      restrictions.

      Structure:
        * Root personality matches on IOUserResources and exposes a user
          client (IOUserUserClient / VirtualJoyConUserClient). Does NOT
          publish an HID device itself.
        * UserClient holds a nested HIDDeviceProperties personality with
          IOClass=AppleUserHIDDevice + IOUserClass=VirtualJoyConHIDDevice.
          The daemon triggers creation of that HID device by calling
          IOService::Create(self, "HIDDeviceProperties", ...) on the first
          report. This is why the gamepad only appears in the HID tree
          once the daemon actually starts pushing data, matching how
          Karabiner's virtual keyboard/pointing devices appear on demand.
    -->
    <key>IOKitPersonalities</key>
    <dict>
        <key>VirtualJoyConDriver</key>
        <dict>
            <key>CFBundleIdentifier</key>
            <string>local.joycon2mac.driver</string>
            <key>CFBundleIdentifierKernel</key>
            <string>com.apple.kpi.iokit</string>
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
            <key>UserClientProperties</key>
            <dict>
                <key>IOClass</key>
                <string>IOUserUserClient</string>
                <key>IOUserClass</key>
                <string>VirtualJoyConUserClient</string>
                <!--
                  Empty IOServiceDEXTEntitlements declares that the user
                  client accepts connections without requiring the host
                  app to carry a com.apple.developer.driverkit.userclient-
                  access entitlement. With SIP off + ad-hoc signing this
                  is required — otherwise IOServiceOpen returns 0xE00002C7
                  (kIOReturnNotPermitted).
                -->
                <key>IOServiceDEXTEntitlements</key>
                <string></string>
                <key>HIDDeviceProperties</key>
                <dict>
                    <!--
                      AppleUserHIDDevice is the kernel half that backs a
                      DEXT-provided HID device; our VirtualJoyConHIDDevice
                      (subclass of IOUserHIDDevice) is the DEXT half. This
                      pairing is what makes the device show up as a real
                      IOHIDDevice nub in IOKit, which is prerequisite for
                      anything higher up the stack (IOHIDManager clients,
                      GameController framework's probing, etc.) to see it.
                    -->
                    <key>IOClass</key>
                    <string>AppleUserHIDDevice</string>
                    <key>IOUserClass</key>
                    <string>VirtualJoyConHIDDevice</string>
                </dict>
            </dict>
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
