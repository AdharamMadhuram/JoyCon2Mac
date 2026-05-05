# JoyCon2Mac Driver

Native macOS driver for Nintendo Switch 2 Joy-Con controllers with full motion control and mouse support.

## Current Status: Phase 1 - BLE Connection & IMU Init ✅

This prototype demonstrates:
- ✅ Bluetooth Low Energy scanning for Joy-Con 2 controllers
- ✅ Connection with cooldown protection
- ✅ Full IMU initialization sequence (3-step process)
- ✅ Real-time packet decoding (buttons, sticks, motion, mouse, battery)
- ✅ Pairing vibration and LED control

## Requirements

- macOS 11.0 or later (Big Sur+)
- CMake 3.15+
- Xcode Command Line Tools
- Nintendo Switch 2 Joy-Con controller

## Building

```bash
# Create build directory
mkdir build && cd build

# Configure
cmake ..

# Build
make

# Run
./bin/joycon2mac
```

Or use the build script:

```bash
./build.sh
```

## Usage

1. Put your Joy-Con in pairing mode (hold the sync button until LEDs flash)
2. Run the application:
   ```bash
   ./build/bin/joycon2mac           # Compact output
   ./build/bin/joycon2mac -v        # Detailed output
   ```
3. The app will automatically:
   - Scan for Joy-Con controllers
   - Connect to the first one found
   - Initialize IMU sensors
   - Send pairing vibration
   - Set player LED
   - Display live controller data

## Output Format

**Compact mode** (default):
```
BTN:0x000000 L:(     0,     0) R:(     0,     0) T:(  0,  0) BAT:3.85V #1234
```

**Verbose mode** (`-v`):
```
========== Joy-Con State ==========
Packet #60

Buttons: 0x0

Sticks:
  Left:  X=0 Y=0
  Right: X=0 Y=0

Motion (IMU):
  Gyro:  X=0.00° Y=0.00° Z=0.00°/s
  Accel: X=0.00G Y=0.00G Z=1.00G

Mouse:
  Delta: X=0 Y=0
  Distance: 0

Triggers:
  L=0 R=0

Battery:
  Voltage: 3.85V
  Current: 0.00mA
  Temp: 25.00°C
===================================
```

## Troubleshooting

### "Bluetooth not ready"
- Make sure Bluetooth is enabled in System Preferences
- Grant Bluetooth permissions if prompted

### "Cooldown active"
- The Joy-Con has a built-in cooldown after repeated connection attempts
- Wait 3 minutes before trying again
- This is a hardware limitation to prevent battery drain

### "No response for IMU step X"
- The controller may not be fully paired yet
- Try holding the sync button longer
- Make sure the controller isn't connected to a Switch or other device

### Connection fails repeatedly
- Remove the Joy-Con from Bluetooth settings if it's already paired
- Put the controller in pairing mode again
- The app implements exponential backoff (30s, 60s, 120s, etc.)

## Architecture

```
JoyCon2Mac/
├── BLEManager.mm          - CoreBluetooth connection & command protocol
├── JoyConDecoder.cpp      - Packet parsing (buttons, sticks, IMU, mouse)
├── main.mm                - Entry point & display logic
└── *.h                    - Headers
```

## Next Steps (Phase 2+)

- [ ] Dual Joy-Con pairing (merge L+R into one controller)
- [ ] MAC address persistence (auto-reconnect)
- [ ] DriverKit virtual gamepad (system-wide HID device)
- [ ] Mouse mode (optical sensor → CGEvent)
- [ ] Menu bar app with GUI controls

## References

This project builds on reverse engineering work from:
- [joycon2cpp](https://github.com/TheFrano/joycon2cpp) - C++ protocol implementation
- [Joy2Win](https://github.com/Logan-Gaillard/Joy2Win) - Windows driver with BLE commands
- [Switch2-Controllers](https://github.com/Nohzockt/Switch2-Controllers) - Python GUI reference
- [Switch2-Mouse](https://github.com/NVNTLabs/Switch2-Mouse) - Optical sensor research

## License

MIT License - See LICENSE file for details

## Contributing

This is an active research project. Contributions welcome!

Areas needing help:
- Right Joy-Con axis mapping verification
- Firmware version compatibility testing
- DriverKit signing and deployment
- Dual-controller synchronization
