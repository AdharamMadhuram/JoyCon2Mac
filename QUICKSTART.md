# Quick Start Guide

## Prerequisites

1. **macOS 11.0+** (Big Sur or later)
2. **Xcode Command Line Tools**
   ```bash
   xcode-select --install
   ```
3. **CMake** (via Homebrew)
   ```bash
   brew install cmake
   ```
4. **Nintendo Switch 2 Joy-Con** controller

## Build & Run (5 minutes)

### Step 1: Build the project
```bash
cd ~/Downloads/joycon2-mac-driver
./build.sh
```

You should see:
```
✓ CMake found
✓ Xcode tools found
⚙️  Configuring with CMake...
🔨 Building...
[100%] Built target joycon2mac
╔════════════════════════════════════════════════════════╗
║         Build Complete!                                ║
╚════════════════════════════════════════════════════════╝
```

### Step 2: Put Joy-Con in pairing mode
1. Hold the **SYNC button** (small button on the rail)
2. LEDs should flash rapidly
3. Keep holding until the app connects

### Step 3: Run the application
```bash
cd build/bin
./joycon2mac
```

You should see:
```
[BLE] Bluetooth powered on
[BLE] Starting scan for Joy-Con 2 controllers...
[BLE] Found Nintendo device: Joy-Con (L) [RSSI: -45 dBm]
[BLE] Connecting to Joy-Con...
[BLE] ✓ Connected! Discovering services...
[BLE] ✓ Found input characteristic
[BLE] ✓ Found command characteristic
[BLE] ✓ Found response characteristic
[BLE] Starting IMU initialization sequence...
[BLE] Sending IMU init step 1...
[BLE] Received command response
[BLE] Sending IMU init step 2...
[BLE] Received command response
[BLE] Sending IMU init step 3 (start)...
[BLE] IMU initialization complete!
[BLE] Sending pairing vibration...
[BLE] Setting player LED: 0x1

BTN:0x000000 L:(     0,     0) R:(     0,     0) T:(  0,  0) BAT:3.85V #1
```

### Step 4: Test the controller
- Press buttons → BTN value changes
- Move joystick → L values change
- Tilt controller → Motion data updates (use `-v` flag to see)

## Verbose Mode

To see detailed motion, battery, and sensor data:
```bash
./joycon2mac -v
```

Output every second:
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

## Common Issues

### "Bluetooth not ready"
**Solution**: Enable Bluetooth in System Preferences → Bluetooth

### "Cooldown active. Waiting X seconds..."
**Cause**: Joy-Con has a 3-minute cooldown after rapid connection attempts  
**Solution**: Wait the displayed time, then try again

### "Failed to connect"
**Solutions**:
1. Make sure Joy-Con is in pairing mode (LEDs flashing)
2. Remove Joy-Con from Bluetooth settings if already paired
3. Make sure Joy-Con isn't connected to a Switch
4. Try moving closer to your Mac
5. Wait for automatic retry (exponential backoff: 30s, 60s, 120s...)

### No motion data
**Cause**: IMU init sequence failed  
**Solution**: Disconnect and reconnect. Look for "IMU initialization complete!" message

### Permission denied
**Solution**: Grant Bluetooth permissions when macOS prompts

## What's Working

✅ BLE connection  
✅ IMU initialization  
✅ Button decoding  
✅ Joystick decoding  
✅ Motion sensors (gyro + accel)  
✅ Optical mouse sensor  
✅ Battery monitoring  
✅ Analog triggers  
✅ Auto-reconnect  

## What's Not Yet Implemented

❌ System-wide gamepad (Phase 4 - needs DriverKit)  
❌ Mouse mode (Phase 5 - optical sensor → cursor)  
❌ Dual Joy-Con pairing (Phase 4)  
❌ Pairing persistence (Phase 3 - auto-reconnect without re-pairing)  
❌ GUI app (Phase 6)  

## Next Steps

Want to contribute? See `IMPLEMENTATION_PLAN.md` for the full roadmap.

Current priority: **Phase 3 - Pairing Persistence**

## Exit

Press **Ctrl+C** to stop the application.

## Need Help?

1. Check `README.md` for detailed documentation
2. Check `PROJECT_SUMMARY.md` for technical details
3. Check `IMPLEMENTATION_PLAN.md` for the full roadmap
4. Review reference projects in `~/Downloads/`:
   - `joycon2cpp/`
   - `Joy2Win/`
   - `Switch2-Controllers/`
   - `Switch2-Mouse/`
