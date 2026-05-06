#include "JoyConDecoder.h"
#include <cmath>
#include <algorithm>
#include <cstdint>
#include <cstdio>

// Helper function to convert two bytes to signed 16-bit integer
static int16_t to_signed_16(uint8_t lsb, uint8_t msb) {
    return static_cast<int16_t>((msb << 8) | lsb);
}

uint32_t ExtractButtonState(const std::vector<uint8_t>& buffer) {
    // joycon2cpp ExtractButtonState (single form): 24-bit state built from
    // bytes [3..5] of the input report. Same function body as
    // joycon2cpp/testapp/src/JoyConDecoder.cpp.
    if (buffer.size() < 6) return 0;
    return (buffer[3] << 16) | (buffer[4] << 8) | buffer[5];
}

uint32_t ExtractButtonState(const std::vector<uint8_t>& buffer, JoyConSide side) {
    // Side-aware variant: joycon2cpp's GenerateDS4Report uses
    //   btnOffset = isLeft ? 4 : 3
    //   state = (buffer[btnOffset] << 16) | (buffer[btnOffset+1] << 8)
    //         | buffer[btnOffset+2]
    // so left Joy-Con state starts one byte later than right. That's how
    // joycon2cpp lines up the BUTTON_*_MASK_LEFT / _RIGHT bit numbers with
    // the actual packet, so we mirror it exactly.
    int btnOffset = (side == JoyConSide::Left) ? 4 : 3;
    if (buffer.size() < static_cast<size_t>(btnOffset + 3)) return 0;
    return (uint32_t(buffer[btnOffset]) << 16)
         | (uint32_t(buffer[btnOffset + 1]) << 8)
         |  uint32_t(buffer[btnOffset + 2]);
}

StickData DecodeJoystick(const std::vector<uint8_t>& buffer, JoyConSide side, JoyConOrientation orientation) {
    // Exact port of joycon2cpp/testapp/src/JoyConDecoder.cpp DecodeJoystick.
    // Do not "improve" this — joycon2cpp is the reference that's known to
    // work on real Switch 2 Joy-Cons. Any calibration deviation (Joy2Win
    // centers/spans, extra axis negation, deadzone tweak) reintroduces the
    // mirrored/frozen-stick bugs we hit before.
    if (buffer.size() < 16) {
        return { 0, 0, 0, 0 };
    }

    bool isLeft = (side == JoyConSide::Left);
    bool upright = (orientation == JoyConOrientation::Upright);

    const uint8_t* data = isLeft ? &buffer[10] : &buffer[13];

    int x_raw = ((data[1] & 0x0F) << 8) | data[0];
    int y_raw = (data[2] << 4) | ((data[1] & 0xF0) >> 4);

    float x = (x_raw - 2048) / 2048.0f;
    float y = (y_raw - 2048) / 2048.0f;

    if (!upright) {
        float tx = x, ty = y;
        x = isLeft ? -ty : ty;
        y = isLeft ? tx : -tx;
    }

    const float deadzone = 0.08f;
    if (std::abs(x) < deadzone && std::abs(y) < deadzone) {
        return { 0, 0, 0, 0 };
    }

    x = std::clamp(x * 1.7f, -1.0f, 1.0f);
    y = std::clamp(y * 1.7f, -1.0f, 1.0f);

    int16_t outX = static_cast<int16_t>(x * 32767);
    int16_t outY = static_cast<int16_t>(-y * 32767);

    return { outX, outY, 0, 0 };
}

MotionData DecodeMotion(const std::vector<uint8_t>& buffer, JoyConSide side) {
    // IMU layout and scaling from joycon2cpp README and testapp:
    //   Accel X/Y/Z at 0x30/0x32/0x34, scale 4096 raw = 1 G
    //   Gyro  X/Y/Z at 0x36/0x38/0x3A, scale 48000 raw = 360°/s
    // joycon2cpp ships raw int16 into DS4 reports; for our UI we surface
    // engineering units.
    if (buffer.size() < 0x3C) {
        return { 0, 0, 0, 0, 0, 0 };
    }

    (void)side;

    int16_t raw_accel_x = to_signed_16(buffer[0x30], buffer[0x31]);
    int16_t raw_accel_y = to_signed_16(buffer[0x32], buffer[0x33]);
    int16_t raw_accel_z = to_signed_16(buffer[0x34], buffer[0x35]);

    int16_t raw_gyro_x = to_signed_16(buffer[0x36], buffer[0x37]);
    int16_t raw_gyro_y = to_signed_16(buffer[0x38], buffer[0x39]);
    int16_t raw_gyro_z = to_signed_16(buffer[0x3A], buffer[0x3B]);

    const float accel_factor = 1.0f / 4096.0f;
    const float gyro_factor  = 360.0f / 48000.0f;

    MotionData motion;
    motion.accelX = raw_accel_x * accel_factor;
    motion.accelY = raw_accel_y * accel_factor;
    motion.accelZ = raw_accel_z * accel_factor;

    motion.gyroX = raw_gyro_x * gyro_factor;
    motion.gyroY = raw_gyro_y * gyro_factor;
    motion.gyroZ = raw_gyro_z * gyro_factor;

    return motion;
}

MouseData DecodeMouse(const std::vector<uint8_t>& buffer) {
    if (buffer.size() < 0x18) {
        return { 0, 0, 0 };
    }

    // Mouse raw X/Y at 0x10 and 0x12 (Joy2Win datas[16:20], joycon2cpp GetRawOpticalMouse)
    int16_t deltaX = to_signed_16(buffer[0x10], buffer[0x11]);
    int16_t deltaY = to_signed_16(buffer[0x12], buffer[0x13]);
    
    // IR distance / surface state at mouseDatas[7] == packet offset 0x17
    uint16_t distance = buffer[0x17];

    return { deltaX, deltaY, distance };
}

std::pair<int16_t, int16_t> GetRawOpticalMouse(const std::vector<uint8_t>& buffer) {
    if (buffer.size() < 0x18) return { 0, 0 };
    int16_t raw_x = to_signed_16(buffer[0x10], buffer[0x11]);
    int16_t raw_y = to_signed_16(buffer[0x12], buffer[0x13]);
    return { raw_x, raw_y };
}

BatteryData DecodeBattery(const std::vector<uint8_t>& buffer) {
    if (buffer.size() < 0x30) {
        return { 0, 0, 0, -1 };
    }

    // Battery voltage at 0x1C (1000 = 1V)
    uint16_t voltage_raw = (buffer[0x1D] << 8) | buffer[0x1C];
    float voltage = voltage_raw / 1000.0f;
    if (voltage < 3.0f || voltage > 5.5f) {
        voltage = 0.0f;
    }

    // Battery current at 0x1E (100 = 1mA)
    uint16_t current_raw = (buffer[0x1F] << 8) | buffer[0x1E];
    float current = current_raw / 100.0f;

    // Temperature at 0x2E (25°C + raw/127)
    uint16_t temp_raw = (buffer[0x2F] << 8) | buffer[0x2E];
    float temperature = 25.0f + (temp_raw / 127.0f);

    float percentage = -1.0f;
    if (buffer.size() > 0x20) {
        uint16_t level_raw = (buffer[0x20] << 8) | buffer[0x1F];
        if (level_raw > 0) {
            percentage = std::clamp((level_raw * 100.0f) / 4095.0f, 0.0f, 100.0f);
        }
    }

    return { voltage, current, temperature, percentage };
}

std::pair<uint8_t, uint8_t> DecodeAnalogTriggers(const std::vector<uint8_t>& buffer) {
    if (buffer.size() < 0x3E) {
        return { 0, 0 };
    }

    // Analog triggers at 0x3C and 0x3D (Joy-Con 2 specific)
    uint8_t triggerL = buffer[0x3C];
    uint8_t triggerR = buffer[0x3D];

    return { triggerL, triggerR };
}
