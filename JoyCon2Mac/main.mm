#import <Foundation/Foundation.h>
#import "BLEManager.h"
#import "PairingManager.h"
#import "DriverKitClient.h"
#import "MouseEmitter.h"
#include "JoyConDecoder.h"
#include <iostream>
#include <iomanip>
#include <sstream>
#include <signal.h>

// Global state for tracking controller data
struct ControllerState {
    uint32_t buttons = 0;
    uint32_t leftButtons = 0;
    uint32_t rightButtons = 0;
    StickData leftStick = {0, 0, 0, 0};
    StickData rightStick = {0, 0, 0, 0};
    MotionData motion = {0, 0, 0, 0, 0, 0};
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
static FILE *g_jsonFile = nullptr;
static NSDate *g_lastPrintTime = nil;
static NSDate *g_lastJSONLeftTime = nil;
static NSDate *g_lastJSONRightTime = nil;
static DriverKitClient *g_driverClient = nil;
static MouseEmitter *g_mouseEmitter = nil;
static BLEManager *g_bleManager = nil;

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
    std::cout << "  Gyro:  X=" << std::fixed << std::setprecision(2) << g_state.motion.gyroX 
              << "° Y=" << g_state.motion.gyroY << "° Z=" << g_state.motion.gyroZ << "°/s\n";
    std::cout << "  Accel: X=" << g_state.motion.accelX 
              << "G Y=" << g_state.motion.accelY << "G Z=" << g_state.motion.accelZ << "G\n";
    
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
    if (lastJSONTime && [now timeIntervalSinceDate:lastJSONTime] < 0.05) {
        return;
    }
    if (side == JoyConSide::Right) {
        g_lastJSONRightTime = now;
    } else {
        g_lastJSONLeftTime = now;
    }

    const char *sideName = side == JoyConSide::Right ? "right" : "left";
    StickData sideStick = side == JoyConSide::Right ? g_state.rightStick : g_state.leftStick;
    int mouseMode = g_mouseEmitter ? (int)g_mouseEmitter.currentMode : 0;

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
        << "\"gyroX\":" << g_state.motion.gyroX << ","
        << "\"gyroY\":" << g_state.motion.gyroY << ","
        << "\"gyroZ\":" << g_state.motion.gyroZ << ","
        << "\"accelX\":" << g_state.motion.accelX << ","
        << "\"accelY\":" << g_state.motion.accelY << ","
        << "\"accelZ\":" << g_state.motion.accelZ << ","
        << "\"mouseX\":" << g_state.mouse.deltaX << ","
        << "\"mouseY\":" << g_state.mouse.deltaY << ","
        << "\"mouseDistance\":" << g_state.mouse.distance << ","
        << "\"batteryVoltage\":" << g_state.battery.voltage << ","
        << "\"batteryCurrent\":" << g_state.battery.current << ","
        << "\"batteryTemperature\":" << g_state.battery.temperature << ","
        << "\"batteryPercentage\":" << g_state.battery.percentage << ","
        << "\"triggerL\":" << (int)g_state.triggerL << ","
        << "\"triggerR\":" << (int)g_state.triggerR << ","
        << "\"mouseMode\":" << mouseMode
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
    } else {
        g_state.rightButtons = sideButtons;
        g_state.rightStick = DecodeJoystick(buffer, JoyConSide::Right, JoyConOrientation::Upright);
    }

    g_state.buttons = sideButtons;
    g_state.motion = DecodeMotion(buffer, side);
    g_state.mouse = DecodeMouse(buffer);
    g_state.battery = DecodeBattery(buffer);
    auto triggers = DecodeAnalogTriggers(buffer);
    g_state.triggerL = triggers.first;
    g_state.triggerR = triggers.second;
    
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

    // Mouse mode runs only for Right Joy-Con packets, matching the single-
    // Joy-Con branch of joycon2cpp/testapp/src/testapp.cpp. For Left we
    // skip straight to the gamepad report.
    std::vector<uint8_t> workingBuffer = buffer;
    if (side == JoyConSide::Right &&
        g_mouseEmitter &&
        g_mouseEmitter.currentMode != MouseModeOff) {
        StickData rStick = g_state.rightStick;
        [g_mouseEmitter processRightJoyConBuffer:workingBuffer
                                     buttonState:sideButtons
                                    stickReading:rStick];
        // processRightJoyConBuffer zeroed the HID bits it consumed. Re-decode
        // the gamepad-relevant fields from the modified buffer so the virtual
        // gamepad doesn't also see the mouse-mode presses.
        sideButtons       = ExtractButtonState(workingBuffer, JoyConSide::Right);
        g_state.rightButtons = sideButtons;
        g_state.rightStick   = DecodeJoystick(workingBuffer, JoyConSide::Right, JoyConOrientation::Upright);
        g_state.buttons      = sideButtons;
    }

    if (g_enableGamepad && g_driverClient) {
        // Send Gamepad Report
        bool up = g_state.leftButtons & 0x0002;
        bool down = g_state.leftButtons & 0x0001;
        bool left = g_state.leftButtons & 0x0008;
        bool right = g_state.leftButtons & 0x0004;

        struct JoyConReportData report;
        report.buttons = [DriverKitClient convertButtonsToHID:g_state.leftButtons rightButtons:g_state.rightButtons dpadUp:up dpadDown:down dpadLeft:left dpadRight:right];
        report.dpad = makeHIDDpad(up, down, left, right);
        report.stickLX = g_state.leftStick.x;
        report.stickLY = -g_state.leftStick.y;
        report.stickRX = g_state.rightStick.x;
        report.stickRY = -g_state.rightStick.y;
        report.triggerL = g_state.triggerL;
        report.triggerR = g_state.triggerR;
        
        [g_driverClient postGamepadReport:report];
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
            else if (arg == "-h" || arg == "--help") { printUsage(); return 0; }
            else if (arg == "--no-gamepad") g_enableGamepad = false;
        }
        
        printUsage();
        emitDaemonEvent("started", "joycon2mac daemon main entered");
        
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
