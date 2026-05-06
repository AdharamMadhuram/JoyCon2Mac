#import <Foundation/Foundation.h>
#import "BLEManager.h"
#import "PairingManager.h"
#import "DriverKitClient.h"
#import "MouseEmitter.h"
#include "JoyConDecoder.h"
#include <iostream>
#include <iomanip>
#include <sstream>
#include <climits>
#include <cstdio>
#include <signal.h>

// Global state for tracking controller data
struct ControllerState {
    uint32_t buttons = 0;
    uint32_t leftButtons = 0;
    uint32_t rightButtons = 0;
    StickData leftStick = {0, 0, 0, 0};
    StickData rightStick = {0, 0, 0, 0};
    // joycon2cpp emits IMU data per-side (each Joy-Con has its own accel +
    // gyro). Keep the last-seen samples separately so the UI can show stable
    // readouts for each side instead of one struct that flickers between
    // whichever controller pushed the most recent BLE notification.
    MotionData motionLeft  = {0, 0, 0, 0, 0, 0};
    MotionData motionRight = {0, 0, 0, 0, 0, 0};
    // Mouse telemetry per side. Both Joy-Con 2 halves carry the optical
    // sensor at the same packet offsets (0x10..0x13 for XY delta, 0x17 for
    // surface distance). Keeping a separate record per side lets the UI
    // show which controller is on a surface and lets the Auto source
    // picker flip based on which one has distance == 0.
    MouseData mouseLeft  = {0, 0, 0};
    MouseData mouseRight = {0, 0, 0};
    // Single "mouse" field preserved for the legacy printDetailedState().
    MouseData mouse = {0, 0, 0};
    BatteryData battery = {0, 0, 0, -1};
    uint8_t triggerL = 0;
    uint8_t triggerR = 0;
    uint32_t packetCount = 0;
    bool isLeftJoyCon = true;
    JoyConSide lastSide = JoyConSide::Left;
};

static ControllerState g_state;
static bool g_showDetailedOutput = false;
static bool g_emitJSON = false;
static bool g_enableGamepad = true;
static bool g_debugInput = false;   // --debug-input: targeted dpad + right-stick trace
static FILE *g_jsonFile = nullptr;
static NSDate *g_lastPrintTime = nil;
static NSDate *g_lastJSONLeftTime = nil;
static NSDate *g_lastJSONRightTime = nil;
static const NSTimeInterval kJSONStateIntervalSeconds = 1.0 / 120.0;
static DriverKitClient *g_driverClient = nil;
static MouseEmitter *g_mouseEmitter = nil;
static BLEManager *g_bleManager = nil;
// Control-file IPC. The GUI writes one JSON command per line into this file
// (e.g. {"cmd":"setMouseMode","value":2}). We poll it on a GCD timer and
// apply any new lines. Kept deliberately simple: no XPC, no Mach ports, no
// signing entitlements — just a file in Application Support the daemon
// already owns exclusively.
static NSString *g_controlFilePath = nil;
static unsigned long long g_controlFileOffset = 0;
static dispatch_source_t g_controlFileTimer = nullptr;

static void emitJSONLine(const std::string& line) {
    std::cout << line << std::endl;
    if (g_jsonFile) {
        fprintf(g_jsonFile, "%s\n", line.c_str());
        fflush(g_jsonFile);
    }
}

static std::string jsonEscape(const char *value) {
    std::string input = value ? value : "";
    std::string output;
    output.reserve(input.size());
    for (char c : input) {
        switch (c) {
            case '\\': output += "\\\\"; break;
            case '"': output += "\\\""; break;
            case '\n': output += "\\n"; break;
            case '\r': output += "\\r"; break;
            case '\t': output += "\\t"; break;
            default: output += c; break;
        }
    }
    return output;
}

void onJoyConStatus(JoyConSide side, const char *status, const char *message, const char *name) {
    if (!g_emitJSON) {
        return;
    }

    const char *sideName = side == JoyConSide::Right ? "right" : "left";
    std::string line = std::string("{")
        + "\"event\":\"controller\","
        + "\"side\":\"" + sideName + "\","
        + "\"status\":\"" + jsonEscape(status) + "\","
        + "\"message\":\"" + jsonEscape(message) + "\","
        + "\"name\":\"" + jsonEscape(name) + "\""
        + "}";
    emitJSONLine(line);
}

void onJoyConTelemetry(JoyConSide side, const char *phase, const char *detail, const char *name) {
    if (!g_emitJSON) {
        return;
    }

    const char *sideName = side == JoyConSide::Right ? "right" : "left";
    std::string line = std::string("{")
        + "\"event\":\"telemetry\","
        + "\"side\":\"" + sideName + "\","
        + "\"phase\":\"" + jsonEscape(phase) + "\","
        + "\"detail\":\"" + jsonEscape(detail) + "\","
        + "\"name\":\"" + jsonEscape(name) + "\""
        + "}";
    emitJSONLine(line);
}

void emitDaemonEvent(const char *status, const char *detail) {
    if (!g_emitJSON) {
        return;
    }

    std::string line = std::string("{")
        + "\"event\":\"daemon\","
        + "\"status\":\"" + jsonEscape(status) + "\","
        + "\"detail\":\"" + jsonEscape(detail) + "\""
        + "}";
    emitJSONLine(line);
}

void toggleMouseMode() {
    if (!g_mouseEmitter) return;

    // Cycle joycon2cpp-style: OFF -> FAST -> NORMAL -> SLOW -> OFF.
    g_mouseEmitter.currentMode = (MouseMode)((g_mouseEmitter.currentMode + 1) % 4);

    // Switch the player-LED pattern to mirror the mode, matching
    // joycon2cpp/testapp/src/testapp.cpp lines 990-1006:
    //   OFF    -> LED 1 (0x01)
    //   FAST   -> LED 2 (0x02)
    //   NORMAL -> LED 3 (0x04)
    //   SLOW   -> LED 4 (0x08)
    uint8_t ledPattern = 0x01;
    const char *modeName = "OFF";
    switch (g_mouseEmitter.currentMode) {
        case MouseModeFast:   modeName = "FAST";   ledPattern = 0x02; break;
        case MouseModeNormal: modeName = "NORMAL"; ledPattern = 0x04; break;
        case MouseModeSlow:   modeName = "SLOW";   ledPattern = 0x08; break;
        default: break;
    }
    std::cout << "[Mouse Mode] " << modeName << std::endl;

    if (g_bleManager) {
        [g_bleManager setPlayerLED:ledPattern];
    }
}

// Apply one control command from the GUI. Kept as a small dispatch so we
// can extend it later (rumble trigger, re-pair, etc.) without rewriting
// the polling loop.
static void applyControlCommand(NSDictionary *command) {
    NSString *cmd = command[@"cmd"];
    if (![cmd isKindOfClass:[NSString class]]) return;

    if ([cmd isEqualToString:@"setMouseMode"]) {
        if (!g_mouseEmitter) return;
        NSNumber *value = command[@"value"];
        if (![value isKindOfClass:[NSNumber class]]) return;
        int raw = value.intValue;
        if (raw < 0 || raw > 3) return;
        MouseMode target = (MouseMode)raw;
        if (g_mouseEmitter.currentMode == target) {
            emitDaemonEvent("mouseMode", [[NSString stringWithFormat:@"already=%d", raw] UTF8String]);
            return;
        }
        g_mouseEmitter.currentMode = target;
        uint8_t ledPattern = 0x01;
        const char *modeName = "OFF";
        switch (target) {
            case MouseModeFast:   modeName = "FAST";   ledPattern = 0x02; break;
            case MouseModeNormal: modeName = "NORMAL"; ledPattern = 0x04; break;
            case MouseModeSlow:   modeName = "SLOW";   ledPattern = 0x08; break;
            default: break;
        }
        if (g_bleManager) {
            [g_bleManager setPlayerLED:ledPattern];
        }
        emitDaemonEvent("mouseMode",
                        [[NSString stringWithFormat:@"applied=%s (%d)", modeName, raw] UTF8String]);
        std::cout << "[Control] Mouse mode set to " << modeName << std::endl;
    } else if ([cmd isEqualToString:@"toggleMouseMode"]) {
        toggleMouseMode();
    } else if ([cmd isEqualToString:@"setMouseSource"]) {
        if (!g_mouseEmitter) return;
        NSNumber *value = command[@"value"];
        if (![value isKindOfClass:[NSNumber class]]) return;
        int raw = value.intValue;
        if (raw < 0 || raw > 2) return;
        MouseSource target = (MouseSource)raw;
        if (g_mouseEmitter.source == target) {
            emitDaemonEvent("mouseSource",
                            [[NSString stringWithFormat:@"already=%d", raw] UTF8String]);
            return;
        }
        g_mouseEmitter.source = target;
        const char *srcName = "AUTO";
        switch (target) {
            case MouseSourceLeft:  srcName = "LEFT";  break;
            case MouseSourceRight: srcName = "RIGHT"; break;
            default: break;
        }
        emitDaemonEvent("mouseSource",
                        [[NSString stringWithFormat:@"applied=%s (%d)", srcName, raw] UTF8String]);
        std::cout << "[Control] Mouse source set to " << srcName << std::endl;
    } else {
        emitDaemonEvent("controlUnknown",
                        [[NSString stringWithFormat:@"unknown cmd=%@", cmd] UTF8String]);
    }
}

static void pollControlFile() {
    if (!g_controlFilePath) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:g_controlFilePath]) {
        g_controlFileOffset = 0;
        return;
    }
    NSError *err = nil;
    NSDictionary *attrs = [fm attributesOfItemAtPath:g_controlFilePath error:&err];
    if (!attrs) return;
    unsigned long long size = [attrs[NSFileSize] unsignedLongLongValue];
    if (size < g_controlFileOffset) {
        // File was truncated or rotated. Rewind.
        g_controlFileOffset = 0;
    }
    if (size <= g_controlFileOffset) return;

    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:g_controlFilePath];
    if (!fh) return;
    @try {
        [fh seekToFileOffset:g_controlFileOffset];
        NSData *data = [fh readDataToEndOfFile];
        g_controlFileOffset = [fh offsetInFile];
        [fh closeFile];
        if (data.length == 0) return;
        NSString *chunk = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        for (NSString *rawLine in [chunk componentsSeparatedByString:@"\n"]) {
            NSString *line = [rawLine stringByTrimmingCharactersInSet:
                                  [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (line.length == 0) continue;
            NSData *lineData = [line dataUsingEncoding:NSUTF8StringEncoding];
            NSError *jsonErr = nil;
            id obj = [NSJSONSerialization JSONObjectWithData:lineData
                                                     options:0
                                                       error:&jsonErr];
            if ([obj isKindOfClass:[NSDictionary class]]) {
                applyControlCommand((NSDictionary *)obj);
            }
        }
    } @catch (NSException *e) {
        [fh closeFile];
    }
}

static void startControlFilePolling(NSString *path) {
    if (!path) return;
    g_controlFilePath = [path copy];
    // Ensure the file exists so the GUI's append-open doesn't race us, and
    // so we know where the read cursor is.
    if (![[NSFileManager defaultManager] fileExistsAtPath:g_controlFilePath]) {
        [[NSFileManager defaultManager] createFileAtPath:g_controlFilePath
                                                contents:nil
                                              attributes:nil];
    }
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:g_controlFilePath error:nil];
    g_controlFileOffset = [attrs[NSFileSize] unsignedLongLongValue];

    dispatch_queue_t queue = dispatch_get_main_queue();
    g_controlFileTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    dispatch_source_set_timer(g_controlFileTimer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                              (uint64_t)(0.1 * NSEC_PER_SEC),
                              (uint64_t)(0.02 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(g_controlFileTimer, ^{
        pollControlFile();
    });
    dispatch_resume(g_controlFileTimer);
    emitDaemonEvent("controlFile", [[NSString stringWithFormat:@"path=%@", path] UTF8String]);
}


void printControllerState() {
    if (g_emitJSON) {
        return;
    }

    // Throttle output to once per 100ms
    if (g_lastPrintTime && [[NSDate date] timeIntervalSinceDate:g_lastPrintTime] < 0.1) {
        return;
    }
    g_lastPrintTime = [NSDate date];
    
    std::cout << "\r";
    std::cout << "BTN:0x" << std::hex << std::setw(6) << std::setfill('0') << g_state.buttons << std::dec << " ";
    std::cout << "L:(" << std::setw(6) << g_state.leftStick.x << "," << std::setw(6) << g_state.leftStick.y << ") ";
    
    if (g_state.rightStick.x != 0 || g_state.rightStick.y != 0) {
        std::cout << "R:(" << std::setw(6) << g_state.rightStick.x << "," << std::setw(6) << g_state.rightStick.y << ") ";
    }
    
    std::cout << "T:(" << std::setw(3) << (int)g_state.triggerL << "," << std::setw(3) << (int)g_state.triggerR << ") ";
    std::cout << "BAT:" << std::fixed << std::setprecision(2) << g_state.battery.voltage << "V ";
    
    if (g_mouseEmitter && g_mouseEmitter.currentMode != MouseModeOff) {
        const char *modeChars[] = {"", "S", "N", "F"};
        std::cout << "[MOUSE:" << modeChars[g_mouseEmitter.currentMode] << "] ";
    }
    
    std::cout << "#" << g_state.packetCount << std::flush;
}

void printDetailedState() {
    if (g_emitJSON) {
        return;
    }

    std::cout << "\n========== Joy-Con State ==========\n";
    std::cout << "Packet #" << g_state.packetCount << "\n\n";
    std::cout << "Buttons: 0x" << std::hex << g_state.buttons << std::dec << "\n";
    
    std::cout << "\nSticks:\n";
    std::cout << "  Left:  X=" << g_state.leftStick.x << " Y=" << g_state.leftStick.y << "\n";
    std::cout << "  Right: X=" << g_state.rightStick.x << " Y=" << g_state.rightStick.y << "\n";
    
    std::cout << "\nMotion (IMU):\n";
    // Print whichever side pushed the most recent packet. The per-side
    // slots above keep Left and Right separate for the JSON emitter; for
    // the human-readable dump we show the side we just received from so
    // the readout tracks the controller the user is moving.
    const MotionData &motion =
        g_state.lastSide == JoyConSide::Right ? g_state.motionRight : g_state.motionLeft;
    std::cout << "  Gyro:  X=" << std::fixed << std::setprecision(2) << motion.gyroX
              << "° Y=" << motion.gyroY << "° Z=" << motion.gyroZ << "°/s\n";
    std::cout << "  Accel: X=" << motion.accelX
              << "G Y=" << motion.accelY << "G Z=" << motion.accelZ << "G\n";
    
    std::cout << "\nMouse:\n";
    std::cout << "  Delta: X=" << g_state.mouse.deltaX << " Y=" << g_state.mouse.deltaY << "\n";
    std::cout << "  Distance: " << g_state.mouse.distance << "\n";
    
    std::cout << "\nTriggers:\n";
    std::cout << "  L=" << (int)g_state.triggerL << " R=" << (int)g_state.triggerR << "\n";
    
    std::cout << "\nBattery:\n";
    std::cout << "  Voltage: " << g_state.battery.voltage << "V\n";
    std::cout << "  Current: " << g_state.battery.current << "mA\n";
    std::cout << "  Temp: " << g_state.battery.temperature << "°C\n";
    
    std::cout << "===================================\n\n";
}

static uint8_t makeHIDDpad(bool up, bool down, bool left, bool right) {
    if (up && right) return 1;
    if (up && left) return 7;
    if (down && right) return 3;
    if (down && left) return 5;
    if (up) return 0;
    if (down) return 4;
    if (left) return 6;
    if (right) return 2;
    return 8;
}

static void printJSONState(const std::vector<uint8_t>& buffer, JoyConSide side, uint32_t sideButtons) {
    if (!g_emitJSON) {
        return;
    }

    NSDate *lastJSONTime = side == JoyConSide::Right ? g_lastJSONRightTime : g_lastJSONLeftTime;
    NSDate *now = [NSDate date];
    if (lastJSONTime && [now timeIntervalSinceDate:lastJSONTime] < kJSONStateIntervalSeconds) {
        return;
    }
    if (side == JoyConSide::Right) {
        g_lastJSONRightTime = now;
    } else {
        g_lastJSONLeftTime = now;
    }

    const char *sideName = side == JoyConSide::Right ? "right" : "left";
    StickData sideStick = side == JoyConSide::Right ? g_state.rightStick : g_state.leftStick;
    // Match the per-side MotionData slot so a state line for the Left Joy-Con
    // only reports the Left IMU (and vice versa). Without this, the UI saw
    // the same gyro/accel trio for both controllers, which is the "wonky 3D
    // cube that doesn't match the physical Joy-Con" symptom.
    const MotionData &sideMotion = side == JoyConSide::Right ? g_state.motionRight : g_state.motionLeft;
    const MouseData &sideMouse = side == JoyConSide::Right ? g_state.mouseRight : g_state.mouseLeft;
    int mouseMode = g_mouseEmitter ? (int)g_mouseEmitter.currentMode : 0;
    int mouseSource = g_mouseEmitter ? (int)g_mouseEmitter.source : 0;
    const char *mouseActive = g_mouseEmitter && g_mouseEmitter.lastActiveSide == JoyConSide::Left ? "left" : "right";

    std::ostringstream out;
    out << "{"
        << "\"event\":\"state\","
        << "\"side\":\"" << sideName << "\","
        << "\"packetCount\":" << g_state.packetCount << ","
        << "\"packetSize\":" << buffer.size() << ","
        << "\"buttons\":" << sideButtons << ","
        << "\"leftButtons\":" << g_state.leftButtons << ","
        << "\"rightButtons\":" << g_state.rightButtons << ","
        << "\"stickX\":" << sideStick.x << ","
        << "\"stickY\":" << sideStick.y << ","
        << "\"leftStickX\":" << g_state.leftStick.x << ","
        << "\"leftStickY\":" << g_state.leftStick.y << ","
        << "\"rightStickX\":" << g_state.rightStick.x << ","
        << "\"rightStickY\":" << g_state.rightStick.y << ","
        << "\"gyroX\":" << sideMotion.gyroX << ","
        << "\"gyroY\":" << sideMotion.gyroY << ","
        << "\"gyroZ\":" << sideMotion.gyroZ << ","
        << "\"accelX\":" << sideMotion.accelX << ","
        << "\"accelY\":" << sideMotion.accelY << ","
        << "\"accelZ\":" << sideMotion.accelZ << ","
        << "\"mouseX\":" << sideMouse.deltaX << ","
        << "\"mouseY\":" << sideMouse.deltaY << ","
        << "\"mouseDistance\":" << sideMouse.distance << ","
        << "\"batteryVoltage\":" << g_state.battery.voltage << ","
        << "\"batteryCurrent\":" << g_state.battery.current << ","
        << "\"batteryTemperature\":" << g_state.battery.temperature << ","
        << "\"batteryPercentage\":" << g_state.battery.percentage << ","
        << "\"triggerL\":" << (int)g_state.triggerL << ","
        << "\"triggerR\":" << (int)g_state.triggerR << ","
        << "\"mouseMode\":" << mouseMode << ","
        << "\"mouseSource\":" << mouseSource << ","
        << "\"mouseActiveSide\":\"" << mouseActive << "\""
        << "}";
    emitJSONLine(out.str());
}

void onJoyConData(const std::vector<uint8_t>& buffer, JoyConSide side) {
    g_state.packetCount++;
    g_state.lastSide = side;
    g_state.isLeftJoyCon = (side == JoyConSide::Left);
    
    uint32_t sideButtons = ExtractButtonState(buffer, side);
    if (side == JoyConSide::Left) {
        g_state.leftButtons = sideButtons;
        g_state.leftStick = DecodeJoystick(buffer, JoyConSide::Left, JoyConOrientation::Upright);

        // [BLE->DEC L] Fires only when dpad or left-stick bucket actually
        // changes. dpad bucket = the 4 dpad bits isolated from the rest of
        // the button word; without this key the log would still fire on
        // every face-button press and drown out the signal we want.
        if (g_debugInput) {
            static uint32_t lastDpadBits = ~0u;
            static int lastLX = INT32_MAX, lastLY = INT32_MAX;
            uint32_t dpadBits = sideButtons & 0x00000F; // bits 0..3 = D/U/R/L
            if (dpadBits != lastDpadBits || g_state.leftStick.x != lastLX || g_state.leftStick.y != lastLY) {
                bool u = dpadBits & 0x2, d = dpadBits & 0x1, l = dpadBits & 0x8, r = dpadBits & 0x4;
                fprintf(stderr,
                        "[BLE->DEC L] btn=0x%06x dpad=%c%c%c%c  LS=(%6d,%6d)\n",
                        sideButtons,
                        u ? 'U' : '.', d ? 'D' : '.', l ? 'L' : '.', r ? 'R' : '.',
                        g_state.leftStick.x, g_state.leftStick.y);
                lastDpadBits = dpadBits;
                lastLX = g_state.leftStick.x;
                lastLY = g_state.leftStick.y;
            }
        }
    } else {
        g_state.rightButtons = sideButtons;
        // joycon2cpp's DecodeJoystick picks `&buffer[13]` for the right
        // Joy-Con — that's where the stick lives in the right's own BLE
        // packet. Offsets 0x10..0x13 on either Joy-Con carry the optical
        // mouse delta (see DecodeMouse / GetRawOpticalMouse), so reading
        // the stick from offset 10 here decodes mouse X/Y raw bytes as a
        // 12-bit stick — which is why right-stick up/down went dead while
        // left/right still looked plausible (mouse deltaX jitter survives
        // the 12-bit unpack, deltaY LSB stays near zero).
        g_state.rightStick = DecodeJoystick(buffer, JoyConSide::Right, JoyConOrientation::Upright);

        // [BLE->DEC R] Shows the raw bytes at offsets 13..15 (where the
        // right stick is packed, 12-bit X | 12-bit Y) alongside the decoded
        // signed int16 values. If RY stays 0 while RX moves, the mystery
        // is in the decoder; if RY shows real motion here but is 0
        // downstream, the mystery is in the HID report path.
        if (g_debugInput && buffer.size() >= 16) {
            static int lastRX = INT32_MAX, lastRY = INT32_MAX;
            if (g_state.rightStick.x != lastRX || g_state.rightStick.y != lastRY) {
                fprintf(stderr,
                        "[BLE->DEC R] raw[13..15]=%02x %02x %02x  RS=(%6d,%6d)\n",
                        buffer[13], buffer[14], buffer[15],
                        g_state.rightStick.x, g_state.rightStick.y);
                lastRX = g_state.rightStick.x;
                lastRY = g_state.rightStick.y;
            }
        }
    }

    g_state.buttons = sideButtons;
    // Write motion into the per-side slot. The JSON emitter below picks the
    // matching slot so gyroX/gyroY/gyroZ for the left packet never bleed
    // into the right controller's telemetry row and vice versa.
    if (side == JoyConSide::Left) {
        g_state.motionLeft = DecodeMotion(buffer, side);
        g_state.mouseLeft  = DecodeMouse(buffer);
        g_state.mouse      = g_state.mouseLeft;
    } else {
        g_state.motionRight = DecodeMotion(buffer, side);
        g_state.mouseRight  = DecodeMouse(buffer);
        g_state.mouse       = g_state.mouseRight;
    }
    g_state.battery = DecodeBattery(buffer);
    auto triggers = DecodeAnalogTriggers(buffer);
    // Only update the trigger for the side that sent this packet.
    // Otherwise a left packet (with 0 at offset 0x3D) would zero out
    // triggerR on every left-side frame, causing rapid flicker when R
    // is held on the right Joy-Con.
    if (side == JoyConSide::Left) {
        g_state.triggerL = triggers.first;
    } else {
        g_state.triggerR = triggers.second;
    }
    
    // joycon2cpp: only the Right Joy-Con / Joy-Con 2 has a Chat (C) button,
    // and that button is the *only* trigger for mouse mode. On the left
    // Joy-Con we do nothing here — Capture remains a normal gamepad button.
    if (side == JoyConSide::Right) {
        static bool wasChatPressed = false;
        bool chatPressed = (sideButtons & 0x000040) != 0;
        if (chatPressed && !wasChatPressed) {
            toggleMouseMode();
        }
        wasChatPressed = chatPressed;
    }

    // Mouse mode: feed the raw packet to the emitter so it can decide
    // (based on its `source` setting + per-side distance) whether to
    // consume this packet as a mouse event.
    //
    // IMPORTANT: the emitter mutates `workingBuffer` to suppress the
    // HID bits it consumed. We want those suppressions to land on the
    // gamepad report ONLY — the UI JSON must still report the real
    // button state so the on-screen gamepad visualisation works. So we
    // build two derived button/stick values:
    //
    //   sideButtonsForGamepad / sideStickForGamepad → fed to DS4/HID
    //   g_state.rightButtons / g_state.rightStick   → untouched, UI sees them
    std::vector<uint8_t> workingBuffer = buffer;
    uint32_t sideButtonsForGamepad = sideButtons;
    StickData sideStickForGamepad  = (side == JoyConSide::Right)
                                        ? g_state.rightStick
                                        : g_state.leftStick;

    // Always feed the emitter — even when mouse mode is Off — so it can
    // keep its per-side surface tracking up to date and drive the "Active"
    // badge in the GUI. The emitter short-circuits internally if the mode
    // is Off (returns NO, buffer untouched) so the gamepad path is unaffected.
    if (g_mouseEmitter) {
        StickData sideStick = sideStickForGamepad;
        uint16_t sideDistance = (side == JoyConSide::Right)
                                  ? g_state.mouseRight.distance
                                  : g_state.mouseLeft.distance;
        BOOL consumed = [g_mouseEmitter processBuffer:workingBuffer
                                                 side:side
                                          buttonState:sideButtons
                                         stickReading:sideStick
                                        mouseDistance:sideDistance];
        if (consumed) {
            // Only the gamepad-path values get the stripped data.
            sideButtonsForGamepad = ExtractButtonState(workingBuffer, side);
            sideStickForGamepad   = DecodeJoystick(workingBuffer, side, JoyConOrientation::Upright);
        }
    }

    if (g_enableGamepad && g_driverClient) {
        // Build the DS4/HID report using the STRIPPED side buttons/stick
        // so the virtual gamepad doesn't also see the mouse clicks and
        // cursor-drive stick tilts. The UI/telemetry path below still
        // uses g_state.{left,right}Buttons which are the real values.
        uint32_t leftButtonsForReport  = g_state.leftButtons;
        uint32_t rightButtonsForReport = g_state.rightButtons;
        StickData leftStickForReport   = g_state.leftStick;
        StickData rightStickForReport  = g_state.rightStick;
        if (side == JoyConSide::Left) {
            leftButtonsForReport = sideButtonsForGamepad;
            leftStickForReport   = sideStickForGamepad;
        } else {
            rightButtonsForReport = sideButtonsForGamepad;
            rightStickForReport   = sideStickForGamepad;
        }

        bool up    = leftButtonsForReport & 0x0002;
        bool down  = leftButtonsForReport & 0x0001;
        bool left  = leftButtonsForReport & 0x0008;
        bool right = leftButtonsForReport & 0x0004;

        struct JoyConReportData report;
        report.buttons = [DriverKitClient convertButtonsToHID:leftButtonsForReport
                                                 rightButtons:rightButtonsForReport
                                                       dpadUp:up
                                                     dpadDown:down
                                                     dpadLeft:left
                                                    dpadRight:right];
        report.dpad = makeHIDDpad(up, down, left, right);
        report.stickLX = leftStickForReport.x;
        report.stickLY = leftStickForReport.y;
        report.stickRX = rightStickForReport.x;
        report.stickRY = rightStickForReport.y;
        report.triggerL = g_state.triggerL;
        report.triggerR = g_state.triggerR;

        [g_driverClient postGamepadReport:report];

        // [HID-TX] Change-triggered trace of exactly what leaves the daemon
        // for the dext. Prints the 18-bit button word in hex so bits 12..15
        // (D-pad in the W3C standard mapping) are directly readable, the
        // hat nibble, all four stick axes, and both analog trigger bytes.
        // Combined with [BLE->DEC L/R] this tells us whether a missing
        // input is lost in the decoder, the mapping, or the driver hop.
        if (g_debugInput) {
            static uint32_t lastBtn = ~0u;
            static uint8_t  lastDpad = 0xFF;
            static int16_t  lastLX = INT16_MIN, lastLY = INT16_MIN;
            static int16_t  lastRX = INT16_MIN, lastRY = INT16_MIN;
            static uint8_t  lastTL = 0xFF, lastTR = 0xFF;
            if (report.buttons != lastBtn || report.dpad != lastDpad
                || report.stickLX != lastLX || report.stickLY != lastLY
                || report.stickRX != lastRX || report.stickRY != lastRY
                || report.triggerL != lastTL || report.triggerR != lastTR) {
                bool bU = report.buttons & (1u << 12);
                bool bD = report.buttons & (1u << 13);
                bool bL = report.buttons & (1u << 14);
                bool bR = report.buttons & (1u << 15);
                fprintf(stderr,
                        "[HID-TX] btn=0x%05x dpadBits=%c%c%c%c hat=%u "
                        "LS=(%6d,%6d) RS=(%6d,%6d) T=(%3u,%3u)\n",
                        report.buttons,
                        bU ? 'U' : '.', bD ? 'D' : '.', bL ? 'L' : '.', bR ? 'R' : '.',
                        (unsigned)report.dpad,
                        report.stickLX, report.stickLY,
                        report.stickRX, report.stickRY,
                        (unsigned)report.triggerL, (unsigned)report.triggerR);
                lastBtn = report.buttons;
                lastDpad = report.dpad;
                lastLX = report.stickLX; lastLY = report.stickLY;
                lastRX = report.stickRX; lastRY = report.stickRY;
                lastTL = report.triggerL; lastTR = report.triggerR;
            }
        }
    }
    
    printJSONState(buffer, side, sideButtons);

    if (g_showDetailedOutput && g_state.packetCount % 60 == 0) {
        printDetailedState();
    } else {
        printControllerState();
    }
}

void printUsage() {
    std::cout << "\n╔════════════════════════════════════════════════════════╗\n";
    std::cout << "║         JoyCon2Mac Daemon - Composite DriverKit       ║\n";
    std::cout << "╚════════════════════════════════════════════════════════╝\n\n";
}

static void installShutdownHandler(int signalNumber) {
    signal(signalNumber, SIG_IGN);
    dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, signalNumber, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(source, ^{
        std::cout << "\n[Daemon] Shutdown requested. Disconnecting Joy-Cons...\n";
        emitDaemonEvent("shutdownRequested", "signal received");
        if (g_bleManager) {
            [g_bleManager disconnect];
        }
        if (g_driverClient) {
            [g_driverClient stop];
        }
        CFRunLoopStop(CFRunLoopGetMain());
    });
    dispatch_resume(source);

    static NSMutableArray *sources = nil;
    if (!sources) {
        sources = [NSMutableArray array];
    }
    [sources addObject:source];
}

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        for (int i = 1; i < argc; i++) {
            std::string arg = argv[i];
            if (arg == "-v" || arg == "--verbose") g_showDetailedOutput = true;
            else if (arg == "--json") g_emitJSON = true;
            else if (arg == "--json-file" && i + 1 < argc) {
                g_emitJSON = true;
                g_jsonFile = fopen(argv[++i], "a");
                if (g_jsonFile) {
                    setvbuf(g_jsonFile, nullptr, _IOLBF, 0);
                }
            }
            else if (arg == "--control-file" && i + 1 < argc) {
                // Path must come from the GUI, which creates the file inside
                // Application Support/JoyCon2Mac and passes the same path we
                // pass to --json-file. Store for post-init wiring.
                g_controlFilePath = [NSString stringWithUTF8String:argv[++i]];
            }
            else if (arg == "-h" || arg == "--help") { printUsage(); return 0; }
            else if (arg == "--no-gamepad") g_enableGamepad = false;
            else if (arg == "--debug-input") g_debugInput = true;
        }
        
        printUsage();
        emitDaemonEvent("started", "joycon2mac daemon main entered");
        if (g_debugInput) {
            fprintf(stderr, "[debug-input] targeted tracing enabled: "
                            "[BLE->DEC L/R] + [HID-TX] on stderr, change-triggered only\n");
        }
        
        PairingManager *pairingManager = [PairingManager sharedManager];
        NSString *localMAC = [pairingManager getLocalBluetoothAddress];
        if (localMAC) std::cout << "Local Bluetooth MAC: " << [localMAC UTF8String] << "\n";
        
        // Initialize DriverKit client
        g_driverClient = [[DriverKitClient alloc] init];
        if ([g_driverClient start]) {
            std::cout << "✓ Connected to DriverKit Extension\n";
            emitDaemonEvent("driverReady", "Connected to VirtualJoyConDriver");
        } else {
            std::cout << "✗ Failed to connect to DriverKit Extension\n";
            emitDaemonEvent("driverMissing", "VirtualJoyConDriver not loaded; using CGEvent mouse fallback only");
        }
        g_mouseEmitter = [[MouseEmitter alloc] initWithDriverClient:g_driverClient];

        // Now that g_mouseEmitter + g_bleManager exist, hook up the GUI
        // control channel if a path was passed. Polls at 10 Hz on the main
        // queue, so mouse-mode changes show up within ~100ms.
        if (g_controlFilePath) {
            startControlFilePolling(g_controlFilePath);
        }
        
        std::cout << "Starting BLE manager...\n\n";
        
        BLEManager *bleManager = [[BLEManager alloc] init];
        g_bleManager = bleManager;
        [bleManager setDataCallback:onJoyConData];
        [bleManager setStatusCallback:onJoyConStatus];
        [bleManager setTelemetryCallback:onJoyConTelemetry];
        installShutdownHandler(SIGTERM);
        installShutdownHandler(SIGINT);
        
        std::cout << "Waiting for Bluetooth to power on...\n";
        [[NSRunLoop currentRunLoop] run];
        
        if (g_driverClient) {
            [g_driverClient stop];
        }
        emitDaemonEvent("exiting", "run loop stopped");
        if (g_jsonFile) {
            fclose(g_jsonFile);
            g_jsonFile = nullptr;
        }
    }
    return 0;
}
