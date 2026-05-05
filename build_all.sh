#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"

"$ROOT_DIR/build_gui.sh"

echo
echo "Attempting DriverKit build..."
if "$ROOT_DIR/build_driver.sh"; then
    echo "DriverKit extension built."
    if [ -d "$ROOT_DIR/build/JoyCon2Mac.app" ]; then
        SYSTEM_EXTENSIONS_DIR="$ROOT_DIR/build/JoyCon2Mac.app/Contents/Library/SystemExtensions"
        /bin/rm -rf "$ROOT_DIR/build/JoyCon2Mac.app/Contents/Resources/VirtualJoyConDriver.dext"
        /bin/rm -rf "$SYSTEM_EXTENSIONS_DIR/VirtualJoyConDriver.dext"
        mkdir -p "$SYSTEM_EXTENSIONS_DIR"
        cp -R "$ROOT_DIR/build/xcode/Release/VirtualJoyConDriver.dext" "$SYSTEM_EXTENSIONS_DIR/VirtualJoyConDriver.dext"
        codesign -s - -f --deep --entitlements "$ROOT_DIR/JoyCon2MacApp/JoyCon2Mac.entitlements" "$ROOT_DIR/build/JoyCon2Mac.app" >/dev/null
        echo "Embedded DriverKit extension in JoyCon2Mac.app/Contents/Library/SystemExtensions."
    fi
else
    echo "DriverKit build failed. The daemon and GUI app are still built."
    echo "Check build/xcode logs for DriverKit/iig diagnostics."
    exit 1
fi
