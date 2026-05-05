# JoyCon2 macOS Driver — Implementation Plan

## Overview
Build a native macOS driver that:
- Discovers and pairs one or two Switch 2 Joy-Con 2s over BLE
- Presents a paired set as a single gamepad to macOS (via DriverKit / HIDDriverKit)
- Optionally presents each Joy-Con's optical sensor as a system mouse
- Persists the pairing so controllers re-connect automatically

## Project Status
**Current Phase:** Phase 1 - CoreBluetooth Connection + IMU Init

## BLE Protocol Reference

### Device Identity
| Property | Value |
|----------|-------|
| Nintendo BLE Manufacturer ID | 0x0553 (1363 decimal) |
| Manufacturer data prefix | 0x01 0x00 0x03 0x7E |
| Input report characteristic UUID | ab7de9be-89fe-49ad-828f-118f09df7fd2 |
| Write command characteristic UUID | 649d4ac9-8eb7-4e6c-af44-1ea54fe5f005 |
| Response characteristic UUID | c765a961-d9d8-4d36-a20a-5315b111836a |

### BLE Command Protocol
Format: `[cmdId] [0x91] [0x01] [subCmdId] [0x00] [len] [0x00] [0x00] [data...]`

| Command | Hex Data | Purpose |
|---------|----------|---------|
| Set LED | 09 91 01 07 00 08 00 00 [pattern] 00 00 00 00 00 00 00 | Set player LED (bitmask: LED1=0x01, LED2=0x02, LED3=0x04, LED4=0x08) |
| Paired vibration | 0A 91 01 02 00 04 00 00 03 00 00 00 | Pairing confirmation haptic |
| IMU init step 1 | 0C 91 01 02 00 04 00 00 FF 00 00 00 | Begin IMU/sensor init |
| IMU init step 2 | 0C 91 01 03 00 04 00 00 FF 00 00 00 | Continue IMU init |
| IMU start step 3 | 0C 91 01 04 00 04 00 00 FF 00 00 00 | Start sending IMU data |
| Save MAC step 1 | 15 91 01 01 00 0E 00 00 00 02 [mac1_bytes] [mac2_bytes] | Persist host MAC (pairing) |

⚠️ **Critical:** IMU sequence ORDER matters: step 1 → step 2 → step 3. Must send all three.

⚠️ **Quirk:** If you try to connect/pair repeatedly in a short time span, the controller enters a cooldown and stops responding for several minutes. Build in retry backoff.

### Input Packet Layout (BLE Notification, 0x3E bytes minimum)

| Offset | Size | Field | Notes |
|--------|------|-------|-------|
| 0x00 | 4 | Packet ID / Timestamp | Sequence counter |
| 0x04 | 4 | Button state | Bitmask, see below |
| 0x08 | 3 | Left stick | 12-bit X/Y packed |
| 0x0B | 3 | Right stick | 12-bit X/Y packed (garbage on Left JoyCon) |
| 0x0E | 2 | Mouse X | Signed 16-bit delta |
| 0x10 | 2 | Mouse Y | Signed 16-bit delta |
| 0x12 | 2 | Mouse Unk | Extra motion data |
| 0x14 | 2 | Mouse Distance | Distance to surface (IR) |
| 0x16 | 6 | Magnetometer X/Y/Z | Signed 16-bit each |
| 0x1C | 2 | Battery Voltage | 1000 = 1V; 0x0000 if unavailable |
| 0x1E | 2 | Battery Current | 100 = 1mA |
| 0x20 | 14 | Reserved | Undocumented |
| 0x2E | 2 | Temperature | 25°C + raw/127 |
| 0x30 | 2 | Accel X | Signed 16-bit; 4096 = 1G |
| 0x32 | 2 | Accel Y | |
| 0x34 | 2 | Accel Z | |
| 0x36 | 2 | Gyro X | Signed 16-bit; 48000 = 360°/s |
| 0x38 | 2 | Gyro Y | |
| 0x3A | 2 | Gyro Z | |
| 0x3C | 1 | Analog Trigger L | 0–255 |
| 0x3D | 1 | Analog Trigger R | 0–255 |

### Button Bitmasks (Left Joy-Con)
| Button | Mask |
|--------|------|
| Down | 0x0001 |
| Up | 0x0002 |
| Right | 0x0004 |
| Left | 0x0008 |
| SRL | 0x0010 |
| SLL | 0x0020 |
| L | 0x0040 |
| ZL | 0x0080 |
| Minus | 0x0100 |
| L3 (stick) | 0x0800 |
| Capture | 0x2000 |

### Button Bitmasks (Right Joy-Con)
| Button | Mask |
|--------|------|
| A | 0x000800 |
| B | 0x000200 |
| X | 0x000400 |
| Y | 0x000100 |
| Plus | 0x000002 |
| R | 0x004000 |
| R3 (stick) | 0x000004 |
| ZR | 0x008000 |

## Implementation Phases

### Phase 1 — CoreBluetooth Connection + IMU Init ✅ IN PROGRESS
**Goal:** Connect to one Joy-Con 2, send the IMU init sequence, and receive raw packets.

**Files:**
- `JoyCon2Mac/BLEManager.h/.mm` — CoreBluetooth scan/connect/notify
- `JoyCon2Mac/JoyConDecoder.h/.cpp` — Enhanced packet parser
- `JoyCon2Mac/main.mm` — Entry point
- `CMakeLists.txt` — Build configuration

**Tasks:**
- [x] Scan for peripherals with manufacturer ID 0x0553
- [x] On discovery: connect, discover services, find all three UUIDs
- [x] Subscribe to input characteristic (ab7de9be-...)
- [x] Subscribe to response characteristic (c765a961-...) for command ACKs
- [ ] After connect, send IMU init sequence (must wait for ACK between steps)
- [ ] Send paired vibration
- [ ] Set LED to player slot
- [ ] Log raw packet bytes to verify 0x3E+ byte payloads
- [ ] Implement exponential backoff for cooldown bug

### Phase 2 — Packet Decoder Enhancement
**Goal:** Full motion and mouse decoding.

**Tasks:**
- [ ] Add `DecodeMotion()` — extract accel/gyro with correct axis remapping and scaling
- [ ] Add `DecodeMouse()` — extract optical delta at buffer[0x10] and buffer[0x12]
- [ ] Add `DecodeBattery()` — voltage at buffer[0x1C], formula: value/1000 = volts
- [ ] Unit test decoder against known packets

### Phase 3 — Pairing Persistence
**Goal:** Make the Joy-Con re-connect to this Mac automatically.

**Files:**
- `JoyCon2Mac/PairingManager.h/.mm`

**Tasks:**
- [ ] Get the Mac's Bluetooth address
- [ ] Send 4-step MAC save sequence
- [ ] Store paired controller MAC addresses in UserDefaults
- [ ] On launch: scan specifically for known MACs first

### Phase 4 — DriverKit Virtual Gamepad
**Goal:** Expose a standard HID gamepad to macOS apps.

**Files:**
- `VirtualJoyConDriver/VirtualJoyConDriver.iig/.cpp`
- `VirtualJoyConApp/main.mm`

**Tasks:**
- [ ] Review and complete HID descriptor
- [ ] Wire up VirtualJoyConApp to connect BLEManager
- [ ] Build JoyConReportData from decoded packets
- [ ] Connect to VirtualJoyConDriver via IOUserClient
- [ ] Handle dual Joy-Con pairing (merge L+R)
- [ ] Sign the DriverKit extension

### Phase 5 — Mouse Mode
**Goal:** Let each Joy-Con's optical sensor act as a system mouse.

**Files:**
- `JoyCon2Mac/MouseEmitter.h/.mm`

**Tasks:**
- [ ] Track per-JoyCon mouseMode state
- [ ] Toggle mode on button press
- [ ] Emit CGEvent mouse movements
- [ ] Map L/ZL to left/right click
- [ ] Map joystick to scroll

### Phase 6 — UI / Menu Bar App
**Goal:** Simple macOS menu bar app to control the daemon.

**Tasks:**
- [ ] Show connected controllers
- [ ] Toggle mouse mode
- [ ] Show gyro visualizer
- [ ] Preferences panel
- [ ] Launch at login

## Key Technical Risks

| Risk | Mitigation |
|------|------------|
| DriverKit entitlement requires Apple Developer account | Use IOHIDDevice userspace injection as fallback |
| BLE cooldown bug | Implement exponential backoff |
| MAC address save sequence may differ per firmware | Test on actual hardware; log responses |
| Dual Joy-Con timing: L and R packets arrive asynchronously | Buffer last packet per side; merge on whichever arrives second |
| macOS Bluetooth stack vs Windows | The macos_prototype already confirms basic connect/subscribe works |
| Mouse mode + gamepad mode simultaneously | Maintain two separate output paths |

## Reference Projects (in ~/Downloads)

| Project | What to borrow |
|---------|----------------|
| joycon2cpp/macos_prototype/ | BLE scan/connect/subscribe skeleton (Obj-C++) |
| joycon2cpp/virtualjoycon/ | DriverKit skeleton + HID descriptor |
| joycon2cpp/testapp/src/JoyConDecoder.cpp | Full decoder incl. dual-JoyCon merge + mouse |
| joycon2cpp/testapp/src/testapp.cpp | Command protocol, mouse mode logic, LED control |
| Joy2Win/controller_command.py | Exact byte sequences for all BLE commands |
| Joy2Win/controllers/JoyconL.py | Calibrated stick values, gyro scaling, button masks |

## Next Steps
1. Complete IMU init sequence in BLEManager
2. Test connection with actual Joy-Con 2 hardware
3. Verify full packet reception (0x3E+ bytes)
4. Move to Phase 2: Enhanced decoder
