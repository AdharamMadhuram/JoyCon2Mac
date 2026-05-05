#!/bin/bash

set -e

echo "╔════════════════════════════════════════════════════════╗"
echo "║         Building JoyCon2Mac SwiftUI App               ║"
echo "╚════════════════════════════════════════════════════════╝"
echo ""

APP_NAME="JoyCon2Mac"
BUILD_DIR="build/app"
DAEMON_PATH="build/bin/joycon2mac"

# Check if daemon is built
if [ ! -f "$DAEMON_PATH" ]; then
    echo "✗ Daemon not found at $DAEMON_PATH"
    echo "  Please build the daemon first: ./build.sh"
    exit 1
fi

echo "✓ Found daemon at $DAEMON_PATH"

# Create build directory
mkdir -p "$BUILD_DIR"

echo ""
echo "Step 1: Compiling SwiftUI app..."

# Compile Swift files
swiftc \
    -target arm64-apple-macos11.0 \
    -sdk /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk \
    -F /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks \
    -framework SwiftUI \
    -framework AppKit \
    -framework Combine \
    -o "$BUILD_DIR/$APP_NAME" \
    JoyCon2MacApp/*.swift

if [ $? -ne 0 ]; then
    echo "✗ Compilation failed"
    exit 1
fi

echo "✓ Compiled SwiftUI app"

echo ""
echo "Step 2: Creating app bundle..."

# Create app bundle structure
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Move executable
mv "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/"

# Copy daemon
cp "$DAEMON_PATH" "$APP_BUNDLE/Contents/MacOS/"

# Create Info.plist
cat > "$APP_BUNDLE/Contents/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>JoyCon2Mac</string>
    <key>CFBundleIdentifier</key>
    <string>com.joycon2mac.app</string>
    <key>CFBundleName</key>
    <string>JoyCon2Mac</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>11.0</string>
    <key>LSUIElement</key>
    <false/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026</string>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>JoyCon2Mac needs Bluetooth access to connect to Joy-Con controllers.</string>
    <key>NSBluetoothPeripheralUsageDescription</key>
    <string>JoyCon2Mac needs Bluetooth access to connect to Joy-Con controllers.</string>
</dict>
</plist>
EOF

echo "✓ Created app bundle"

echo ""
echo "Step 3: Signing app..."
codesign -s - -f "$APP_BUNDLE"

echo "✓ Signed app"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  SwiftUI App Built Successfully!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Location: $APP_BUNDLE"
echo ""
echo "To run:"
echo "  open $APP_BUNDLE"
echo ""
echo "To install:"
echo "  cp -r $APP_BUNDLE /Applications/"
echo ""
