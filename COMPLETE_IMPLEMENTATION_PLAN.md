# JoyCon2Mac - Complete Implementation (Phases 3-6)

## Updated Requirements

The Joy-Con 2 controller will register as **THREE** separate devices on macOS:

1. **Bluetooth HID Gamepad** - Standard game controller (works in all games)
2. **Bluetooth Mouse** - Using optical sensor for cursor control
3. **Bluetooth NFC Reader** - For reading NFC tags (Amiibo, etc.)

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                    JoyCon2Mac Daemon                         │
│                                                              │
│  ┌──────────────┐    ┌─────────────────┐   ┌─────────────┐ │
│  │ BLEManager   │───▶│ JoyConDecoder   │──▶│ Controllers │ │
│  │ (Phase 1)    │    │ (Phase 1)       │   │             │ │
│  └──────────────┘    └─────────────────┘   │ - Gamepad   │ │
│         │                     │             │ - Mouse     │ │
│  ┌──────────────┐    ┌─────────────────┐   │ - NFC       │ │
│  │ Pairing      │    │ MouseEmitter    │   └─────────────┘ │
│  │ Manager      │    │ (Phase 5)       │                   │
│  │ (Phase 3)    │    └─────────────────┘                   │
│  └──────────────┘             │                            │
│                        ┌──────▼──────┐                     │
│                        │  CGEvent    │                     │
│                        │  (Mouse)    │                     │
│                        └─────────────┘                     │
│                                                             │
│  ┌──────────────────────────────────────────────────────┐  │
│  │          HIDGamepadEmulator (Phase 4)                │  │
│  │          IOHIDUserDevice (no DriverKit!)             │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                             │
│  ┌──────────────────────────────────────────────────────┐  │
│  │          NFCReader (Phase 6)                         │  │
│  │          CoreNFC / Custom HID                        │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│              SwiftUI Menu Bar App (Phase 6)                  │
│                                                              │
│  • Connected Controllers                                     │
│  • Battery Levels                                            │
│  • Mouse Mode Toggle (Off/Slow/Normal/Fast)                  │
│  • Gamepad/Mouse/NFC Status                                  │
│  • Gyro Visualizer                                           │
│  • NFC Tag Reader                                            │
│  • Settings & Preferences                                    │
└─────────────────────────────────────────────────────────────┘
```

## Phase 3: Pairing Persistence ✅

### Goal
Auto-reconnect without re-pairing every session.

### Implementation
- `PairingManager.mm` - MAC address binding
- Store paired controllers in UserDefaults
- Send 4-step MAC save sequence
- Scan for known MACs first on launch

### Files
- `JoyCon2Mac/PairingManager.h/.mm`

## Phase 4: HID Gamepad (IOHIDDevice) ✅

### Goal
System-wide gamepad using **IOHIDUserDevice** (no DriverKit/signing needed!)

### Why IOHIDUserDevice instead of DriverKit?
- ✅ No Apple Developer certificate required
- ✅ No signing/entitlements needed
- ✅ Works locally without approval
- ✅ Full HID descriptor control
- ✅ Same functionality as DriverKit for our use case

### Implementation
- Create virtual HID gamepad using IOHIDUserDevice
- 14 buttons + D-pad + 2 analog sticks + 2 analog triggers
- Merge dual Joy-Con (L+R) into single controller
- Real-time report updates (~120 Hz)

### HID Descriptor
```
Usage Page: Generic Desktop (0x01)
Usage: Gamepad (0x05)
Collection: Application
  - Buttons (14): A, B, X, Y, L, R, ZL, ZR, Minus, Plus, L3, R3, Capture, Home
  - D-Pad: Hat Switch (8-way)
  - Left Stick: X, Y (16-bit signed)
  - Right Stick: X, Y (16-bit signed)
  - Triggers: L, R (8-bit unsigned)
```

### Files
- `JoyCon2Mac/HIDGamepadEmulator.h/.mm`

## Phase 5: Mouse Mode ✅

### Goal
Optical sensor → system mouse cursor

### Features
- **4 Modes**: Off, Slow, Normal, Fast
- **Toggle**: Capture button (or configurable)
- **Mouse Buttons**:
  - L → Left Click
  - ZL → Right Click
  - Stick Click → Middle Click
- **Scroll**: Joystick Y-axis
- **Side Buttons**: Joystick X-axis peaks (Back/Forward)
- **Sensitivity**: Adjustable per mode
- **LED Indicator**: Shows current mode (LED 1-4)

### Implementation
- Track mouse mode state per controller
- Read optical sensor deltas (0x0E, 0x10)
- Emit CGEvent for mouse movement/clicks/scroll
- Suppress gamepad input when mouse mode active

### Files
- `JoyCon2Mac/MouseEmitter.h/.mm`

## Phase 6: SwiftUI Menu Bar App + NFC ✅

### Goal
User-friendly GUI with NFC support

### Features

#### Menu Bar
- **Icon**: Joy-Con symbol with connection status
- **Quick Actions**:
  - Toggle mouse mode
  - Show/hide main window
  - Quit

#### Main Window
- **Controllers Tab**:
  - List of connected controllers
  - Battery level (voltage, %, time remaining)
  - Connection status (RSSI, latency)
  - Player LED indicator
  - Disconnect button
  
- **Mouse Tab**:
  - Mode selector (Off/Slow/Normal/Fast)
  - Sensitivity sliders per mode
  - Button mapping configuration
  - Scroll speed adjustment
  - Test area with cursor tracking
  
- **Gamepad Tab**:
  - Live button/stick visualization
  - Calibration tools
  - Deadzone adjustment
  - Button remapping
  - Dual Joy-Con pairing
  
- **NFC Tab**:
  - Scan for NFC tags
  - Display tag UID/data
  - Amiibo detection
  - Save/load tag dumps
  - Write tags (if supported)
  
- **Gyro Tab**:
  - 3D visualization of controller orientation
  - Gyro/accel graphs
  - Calibration
  - Sensitivity adjustment
  
- **Settings Tab**:
  - Launch at login
  - Auto-reconnect
  - Notification preferences
  - Logging level
  - Export/import config

### NFC Implementation

Joy-Con 2 has built-in NFC reader. We'll expose it as:

1. **CoreNFC Integration** (if available)
2. **Custom HID NFC Device** (fallback)
3. **Raw NFC Data Access** via BLE commands

#### NFC BLE Commands
```
Read NFC Tag:
  CMD: 0x04, SUB: 0x01, Data: [start_page, page_count]
  
Write NFC Tag:
  CMD: 0x04, SUB: 0x02, Data: [page, data[4]]
  
Get NFC Status:
  CMD: 0x04, SUB: 0x00
```

### Files
- `JoyCon2MacApp/` (SwiftUI)
  - `JoyCon2MacApp.swift` - App entry point
  - `MenuBarView.swift` - Menu bar interface
  - `MainWindow.swift` - Main window coordinator
  - `ControllersView.swift` - Controllers tab
  - `MouseView.swift` - Mouse configuration
  - `GamepadView.swift` - Gamepad visualization
  - `NFCView.swift` - NFC reader interface
  - `GyroView.swift` - Motion visualization
  - `SettingsView.swift` - Preferences
  - `DaemonBridge.swift` - IPC with daemon

## Implementation Order

### Step 1: Phase 3 - Pairing Persistence
1. Implement `PairingManager.mm`
2. Get Mac Bluetooth address
3. Send 4-step MAC binding sequence
4. Store/load paired controllers
5. Update `BLEManager` to scan for known MACs first

### Step 2: Phase 4 - HID Gamepad
1. Implement `HIDGamepadEmulator.mm`
2. Create HID descriptor
3. Initialize IOHIDUserDevice
4. Build HID reports from JoyConDecoder
5. Handle dual Joy-Con merging
6. Test in games/apps

### Step 3: Phase 5 - Mouse Mode
1. Implement `MouseEmitter.mm`
2. Track mouse mode state
3. Read optical sensor
4. Emit CGEvent mouse movements
5. Map buttons to clicks
6. Implement scroll/side buttons
7. Suppress gamepad when active

### Step 4: Phase 6 - SwiftUI GUI + NFC
1. Create SwiftUI app target
2. Implement menu bar interface
3. Build all tabs (Controllers, Mouse, Gamepad, NFC, Gyro, Settings)
4. Implement NFC reader
5. Create IPC bridge to daemon
6. Add visualizations (gyro, gamepad)
7. Implement preferences/config

### Step 5: Integration & Testing
1. Wire all components together
2. Test gamepad in games
3. Test mouse mode
4. Test NFC reading
5. Test dual Joy-Con
6. Performance optimization
7. Bug fixes

## Technical Details

### IOHIDUserDevice vs DriverKit

| Feature | IOHIDUserDevice | DriverKit |
|---------|----------------|-----------|
| Signing Required | ❌ No | ✅ Yes |
| Developer Account | ❌ No | ✅ Yes ($99/year) |
| Entitlements | ❌ No | ✅ Yes |
| Local Development | ✅ Easy | ❌ Complex |
| System Integration | ✅ Full | ✅ Full |
| Performance | ✅ Excellent | ✅ Excellent |

**Decision**: Use IOHIDUserDevice for local development. Can migrate to DriverKit later for distribution.

### Mouse Mode State Machine

```
State: OFF (LED 1)
  ↓ [Capture Button]
State: FAST (LED 2) - Sensitivity 1.0x
  ↓ [Capture Button]
State: NORMAL (LED 3) - Sensitivity 0.6x
  ↓ [Capture Button]
State: SLOW (LED 4) - Sensitivity 0.3x
  ↓ [Capture Button]
State: OFF (LED 1)
```

### NFC Protocol

Joy-Con 2 NFC commands (from reference projects):

```cpp
// Start NFC scan
SendGenericCommand(0x04, 0x00, {0x01});

// Read tag (page 0-135 for Amiibo)
SendGenericCommand(0x04, 0x01, {start_page, page_count});

// Response format:
// [0x04] [status] [uid[7]] [data...]
```

### Dual Joy-Con Merging

```cpp
struct DualJoyConState {
    // Left Joy-Con
    uint32_t buttonsL;
    StickData stickL;
    MotionData motionL;
    
    // Right Joy-Con
    uint32_t buttonsR;
    StickData stickR;
    MotionData motionR;
    
    // Merged output
    uint32_t buttonsMerged;  // L buttons → D-pad, R buttons → face buttons
    StickData stickLeft;     // From L Joy-Con
    StickData stickRight;    // From R Joy-Con
    MotionData motion;       // Averaged or selected source
};
```

## Build Configuration

### CMakeLists.txt Updates

```cmake
# Add new source files
set(SOURCES
    JoyCon2Mac/main.mm
    JoyCon2Mac/BLEManager.mm
    JoyCon2Mac/JoyConDecoder.cpp
    JoyCon2Mac/PairingManager.mm          # Phase 3
    JoyCon2Mac/HIDGamepadEmulator.mm      # Phase 4
    JoyCon2Mac/MouseEmitter.mm            # Phase 5
)

# Link additional frameworks
target_link_libraries(joycon2mac
    "-framework Foundation"
    "-framework CoreBluetooth"
    "-framework IOKit"                     # For IOHIDUserDevice
    "-framework ApplicationServices"       # For CGEvent
)

# SwiftUI app (separate target)
add_executable(JoyCon2MacApp MACOSX_BUNDLE
    JoyCon2MacApp/JoyCon2MacApp.swift
    JoyCon2MacApp/MenuBarView.swift
    # ... other Swift files
)
```

## Testing Plan

### Phase 3 Testing
- [ ] Pair controller once
- [ ] Restart daemon
- [ ] Verify auto-reconnect
- [ ] Test with multiple controllers

### Phase 4 Testing
- [ ] Open System Settings → Game Controllers
- [ ] Verify controller appears
- [ ] Test in Steam
- [ ] Test in native games
- [ ] Test button mapping
- [ ] Test analog sticks
- [ ] Test triggers

### Phase 5 Testing
- [ ] Toggle mouse mode
- [ ] Verify cursor movement
- [ ] Test left/right/middle click
- [ ] Test scroll wheel
- [ ] Test side buttons (back/forward)
- [ ] Verify gamepad suppression

### Phase 6 Testing
- [ ] Launch menu bar app
- [ ] Verify controller list
- [ ] Test mouse mode toggle from GUI
- [ ] Scan NFC tag
- [ ] Verify gyro visualization
- [ ] Test settings persistence

## Performance Targets

- **Latency**: <10ms from controller to HID report
- **Packet Rate**: 120 Hz (8ms intervals)
- **CPU Usage**: <2% on Apple Silicon
- **Memory**: <10MB RSS
- **Battery Impact**: Minimal (BLE optimized)

## Known Limitations

1. **NFC Write**: May require additional reverse engineering
2. **Right Joy-Con Axis**: Needs hardware verification
3. **Dual Joy-Con Sync**: Timing challenges (L/R packets async)
4. **Mouse Acceleration**: macOS applies system acceleration
5. **Gamepad Compatibility**: Some games may need specific HID descriptor tweaks

## Next Steps

Ready to implement! Let's build all phases systematically.

---

**Status**: Ready for implementation  
**Estimated Time**: 4-6 hours for full implementation  
**Priority**: Phase 4 (Gamepad) → Phase 5 (Mouse) → Phase 3 (Pairing) → Phase 6 (GUI+NFC)
