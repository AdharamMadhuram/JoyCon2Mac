#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Build the daemon + GUI first.
"$ROOT_DIR/build_gui.sh"

# If we already have a pre-built dext around, embed it immediately so
# `build_all.sh` never leaves the .app without its dext. That prevented the
# "Driver extension is missing from Contents/Library/SystemExtensions"
# failure seen after running build_gui.sh standalone.
SYSTEM_EXTENSIONS_DIR="$ROOT_DIR/build/JoyCon2Mac.app/Contents/Library/SystemExtensions"
PREBUILT_DEXT="$ROOT_DIR/build/xcode/Release/VirtualJoyConDriver.dext"
if [ -d "$PREBUILT_DEXT" ] && [ -d "$ROOT_DIR/build/JoyCon2Mac.app" ]; then
    mkdir -p "$SYSTEM_EXTENSIONS_DIR"
    /bin/rm -rf "$SYSTEM_EXTENSIONS_DIR/VirtualJoyConDriver.dext"
    cp -R "$PREBUILT_DEXT" "$SYSTEM_EXTENSIONS_DIR/VirtualJoyConDriver.dext"
    codesign -s - -f --deep --entitlements "$ROOT_DIR/JoyCon2MacApp/JoyCon2Mac.entitlements" "$ROOT_DIR/build/JoyCon2Mac.app" >/dev/null
    echo "Embedded pre-built DriverKit extension in JoyCon2Mac.app/Contents/Library/SystemExtensions."
fi

echo
echo "Attempting DriverKit build..."
if "$ROOT_DIR/build_driver.sh"; then
    echo "DriverKit extension built."
    if [ -d "$ROOT_DIR/build/JoyCon2Mac.app" ]; then
        /bin/rm -rf "$ROOT_DIR/build/JoyCon2Mac.app/Contents/Resources/VirtualJoyConDriver.dext"
        /bin/rm -rf "$SYSTEM_EXTENSIONS_DIR/VirtualJoyConDriver.dext"
        mkdir -p "$SYSTEM_EXTENSIONS_DIR"
        cp -R "$PREBUILT_DEXT" "$SYSTEM_EXTENSIONS_DIR/VirtualJoyConDriver.dext"
        codesign -s - -f --deep --entitlements "$ROOT_DIR/JoyCon2MacApp/JoyCon2Mac.entitlements" "$ROOT_DIR/build/JoyCon2Mac.app" >/dev/null
        echo "Embedded freshly-built DriverKit extension in JoyCon2Mac.app/Contents/Library/SystemExtensions."
    fi
else
    echo "DriverKit build failed. The daemon and GUI app are still built."
    echo "Check build/xcode logs for DriverKit/iig diagnostics."
    if [ -d "$SYSTEM_EXTENSIONS_DIR/VirtualJoyConDriver.dext" ]; then
        echo "(The pre-built dext embedded above is still in the bundle.)"
    fi
fi
