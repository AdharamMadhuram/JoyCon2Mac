#pragma once
#include <vector>
#include <utility>
#include <cstdint>

enum class JoyConSide { Left, Right };
enum class JoyConOrientation { Upright, Sideways };
enum class GyroSource { Both, Left, Right };

// Button masks for Left Joy-Con (buffer[5] << 8 | buffer[6])
constexpr uint32_t BTN_LEFT_DOWN    = 0x0001;
constexpr uint32_t BTN_LEFT_UP      = 0x0002;
constexpr uint32_t BTN_LEFT_RIGHT   = 0x0004;
constexpr uint32_t BTN_LEFT_LEFT    = 0x0008;
constexpr uint32_t BTN_LEFT_SRL     = 0x0010;
constexpr uint32_t BTN_LEFT_SLL     = 0x0020;
constexpr uint32_t BTN_LEFT_L       = 0x0040;
constexpr uint32_t BTN_LEFT_ZL      = 0x0080;
constexpr uint32_t BTN_LEFT_MINUS   = 0x0100;
constexpr uint32_t BTN_LEFT_L3      = 0x0800;
constexpr uint32_t BTN_LEFT_CAPTURE = 0x2000;

// Button masks for Right Joy-Con (buffer[4] << 8 | buffer[5])
constexpr uint32_t BTN_RIGHT_A      = 0x0008;
constexpr uint32_t BTN_RIGHT_B      = 0x0002;
constexpr uint32_t BTN_RIGHT_X      = 0x0004;
constexpr uint32_t BTN_RIGHT_Y      = 0x0001;
constexpr uint32_t BTN_RIGHT_PLUS   = 0x0002;
constexpr uint32_t BTN_RIGHT_R      = 0x0040;
constexpr uint32_t BTN_RIGHT_ZR     = 0x0080;
constexpr uint32_t BTN_RIGHT_R3     = 0x0004;
constexpr uint32_t BTN_RIGHT_HOME   = 0x1000;
constexpr uint32_t BTN_RIGHT_CHAT   = 0x0040;  // Chat button (Switch 2 specific)

struct StickData {
    int16_t x;
    int16_t y;
    uint8_t rx;
    uint8_t ry;
};

struct MotionData {
    float gyroX, gyroY, gyroZ;      // degrees/second
    float accelX, accelY, accelZ;   // G-force
};

struct MouseData {
    int16_t deltaX;
    int16_t deltaY;
    uint16_t distance;  // IR distance to surface
};

struct BatteryData {
    float voltage;      // volts
    float current;      // milliamps
    float temperature;  // celsius
    float percentage;   // 0-100, negative if unavailable
};

// Button extraction
uint32_t ExtractButtonState(const std::vector<uint8_t>& buffer);
uint32_t ExtractButtonState(const std::vector<uint8_t>& buffer, JoyConSide side);

// Joystick decoding
StickData DecodeJoystick(const std::vector<uint8_t>& buffer, JoyConSide side, JoyConOrientation orientation);

// Motion decoding (IMU)
MotionData DecodeMotion(const std::vector<uint8_t>& buffer, JoyConSide side);

// Optical mouse sensor
MouseData DecodeMouse(const std::vector<uint8_t>& buffer);
std::pair<int16_t, int16_t> GetRawOpticalMouse(const std::vector<uint8_t>& buffer);

// Battery and temperature
BatteryData DecodeBattery(const std::vector<uint8_t>& buffer);

// Analog triggers (Joy-Con 2 specific)
std::pair<uint8_t, uint8_t> DecodeAnalogTriggers(const std::vector<uint8_t>& buffer);
