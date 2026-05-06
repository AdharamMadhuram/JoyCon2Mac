#import "MouseEmitter.h"
#import <ApplicationServices/ApplicationServices.h>
#include <cstdlib>

// Direct port of the mouse-mode handler from
// joycon2cpp/testapp/src/testapp.cpp (single-Joy-Con, Right side). Keep the
// structure and constants identical to the reference — scroll deadzone 4000,
// scroll cap 40 per packet, 120 units per wheel click, XY threshold 28000,
// sensitivities 1.0 / 0.6 / 0.3 for FAST / NORMAL / SLOW.

@interface MouseEmitter ()
- (void)sendMoveDeltaX:(int)dx deltaY:(int)dy;
- (void)sendMouseButton:(uint8_t)bit down:(BOOL)down location:(CGPoint)loc;
- (CGPoint)currentCursor;
- (void)sendScrollClicks:(int)clicks;
- (void)sendXButton:(int)which;
@end

@implementation MouseEmitter

- (instancetype)initWithDriverClient:(DriverKitClient *)client {
    self = [super init];
    if (self) {
        _driverClient = client;
        _currentMode = MouseModeOff;
        _firstOpticalRead = YES;
        _lastOpticalX = 0;
        _lastOpticalY = 0;
        _scrollAccumulator = 0.0f;
        _leftBtnPressed = NO;
        _rightBtnPressed = NO;
        _middleBtnPressed = NO;
        _mb4Pressed = NO;
        _mb5Pressed = NO;
    }
    return self;
}

- (void)processRightJoyConBuffer:(std::vector<uint8_t> &)buffer
                     buttonState:(uint32_t)btnState
                    stickReading:(StickData)stickData {
    if (_currentMode == MouseModeOff) {
        _firstOpticalRead = YES;
        return;
    }

    // --- 1. Optical mouse movement (joycon2cpp testapp.cpp §“Optical Mouse Movement”) ---
    std::pair<int16_t, int16_t> raw = GetRawOpticalMouse(buffer);
    int16_t rawX = raw.first;
    int16_t rawY = raw.second;
    if (_firstOpticalRead) {
        _lastOpticalX = rawX;
        _lastOpticalY = rawY;
        _firstOpticalRead = NO;
    } else {
        int16_t dx = (int16_t)(rawX - _lastOpticalX);
        int16_t dy = (int16_t)(rawY - _lastOpticalY);
        _lastOpticalX = rawX;
        _lastOpticalY = rawY;

        if (dx != 0 || dy != 0) {
            float sensitivity = 1.0f;
            switch (_currentMode) {
                case MouseModeFast:   sensitivity = 1.0f; break;
                case MouseModeNormal: sensitivity = 0.6f; break;
                case MouseModeSlow:   sensitivity = 0.3f; break;
                default: break;
            }
            int moveX = (int)(dx * sensitivity);
            int moveY = (int)(dy * sensitivity);
            [self sendMoveDeltaX:moveX deltaY:moveY];
        }
    }

    // --- 2. Mouse buttons (R = Left, ZR = Right, R3 = Middle) ---
    //     joycon2cpp masks: R 0x004000, ZR 0x008000, R3 0x000004.
    BOOL rPressed     = (btnState & 0x004000) != 0;
    BOOL zrPressed    = (btnState & 0x008000) != 0;
    BOOL stickPressed = (btnState & 0x000004) != 0;

    CGPoint loc = [self currentCursor];
    if (rPressed != _leftBtnPressed) {
        [self sendMouseButton:0x01 down:rPressed location:loc];
        _leftBtnPressed = rPressed;
    }
    if (zrPressed != _rightBtnPressed) {
        [self sendMouseButton:0x02 down:zrPressed location:loc];
        _rightBtnPressed = zrPressed;
    }
    if (stickPressed != _middleBtnPressed) {
        [self sendMouseButton:0x04 down:stickPressed location:loc];
        _middleBtnPressed = stickPressed;
    }

    // --- 3. Stick scrolling + side buttons ---
    //     Deadzone 4000, max speed 40 per packet, 120 accumulator per click.
    const int SCROLL_DEADZONE = 4000;
    if (std::abs((int)stickData.y) > SCROLL_DEADZONE) {
        float intensity = (std::abs((int)stickData.y) - SCROLL_DEADZONE) /
                          (32767.0f - SCROLL_DEADZONE);
        float speed = intensity * 40.0f;
        if (stickData.y > 0) _scrollAccumulator -= speed; // Up
        else                 _scrollAccumulator += speed; // Down

        if (std::fabs(_scrollAccumulator) >= 120.0f) {
            int clicks = (int)(_scrollAccumulator / 120.0f);
            _scrollAccumulator -= clicks * 120.0f;
            [self sendScrollClicks:clicks];
        }
    } else {
        _scrollAccumulator = 0.0f;
    }

    const int BUTTON_THRESHOLD = 28000;
    if (stickData.x < -BUTTON_THRESHOLD) {
        if (!_mb4Pressed) {
            [self sendXButton:1]; // Back
            _mb4Pressed = YES;
        }
    } else {
        _mb4Pressed = NO;
    }
    if (stickData.x > BUTTON_THRESHOLD) {
        if (!_mb5Pressed) {
            [self sendXButton:2]; // Forward
            _mb5Pressed = YES;
        }
    } else {
        _mb5Pressed = NO;
    }

    // --- 4. Suppress consumed inputs in the buffer before the gamepad report ---
    //     joycon2cpp clears the R/ZR/R3 button bits and resets the right stick
    //     bytes to neutral so the gamepad doesn't also see them.
    if (buffer.size() >= 6) {
        buffer[4] &= ~0x40;   // R
        buffer[4] &= ~0x80;   // ZR
        buffer[5] &= ~0x04;   // Stick click
    }
    if (buffer.size() >= 16) {
        buffer[13] = 0x00;
        buffer[14] = 0x08;
        buffer[15] = 0x80;
    }
}

// MARK: - CGEvent helpers

- (CGPoint)currentCursor {
    CGEventRef e = CGEventCreate(NULL);
    CGPoint p = e ? CGEventGetLocation(e) : CGPointZero;
    if (e) CFRelease(e);
    return p;
}

- (void)sendMoveDeltaX:(int)dx deltaY:(int)dy {
    if (dx == 0 && dy == 0) return;
    CGPoint loc = [self currentCursor];
    CGPoint target = CGPointMake(loc.x + dx, loc.y + dy);
    CGEventRef ev = CGEventCreateMouseEvent(NULL, kCGEventMouseMoved, target, kCGMouseButtonLeft);
    if (ev) {
        CGEventPost(kCGHIDEventTap, ev);
        CFRelease(ev);
    }
}

- (void)sendMouseButton:(uint8_t)bit down:(BOOL)down location:(CGPoint)loc {
    CGEventType type;
    CGMouseButton button = kCGMouseButtonLeft;
    switch (bit) {
        case 0x01:
            type = down ? kCGEventLeftMouseDown : kCGEventLeftMouseUp;
            button = kCGMouseButtonLeft;
            break;
        case 0x02:
            type = down ? kCGEventRightMouseDown : kCGEventRightMouseUp;
            button = kCGMouseButtonRight;
            break;
        case 0x04:
        default:
            type = down ? kCGEventOtherMouseDown : kCGEventOtherMouseUp;
            button = kCGMouseButtonCenter;
            break;
    }
    CGEventRef ev = CGEventCreateMouseEvent(NULL, type, loc, button);
    if (ev) {
        CGEventPost(kCGHIDEventTap, ev);
        CFRelease(ev);
    }
}

- (void)sendScrollClicks:(int)clicks {
    if (clicks == 0) return;
    CGEventRef ev = CGEventCreateScrollWheelEvent(NULL, kCGScrollEventUnitLine, 1, clicks);
    if (ev) {
        CGEventPost(kCGHIDEventTap, ev);
        CFRelease(ev);
    }
}

- (void)sendXButton:(int)which {
    // macOS maps "back" and "forward" side-buttons to button numbers 3 and 4.
    CGMouseButton button = (which == 1) ? (CGMouseButton)3 : (CGMouseButton)4;
    CGPoint loc = [self currentCursor];
    CGEventRef down = CGEventCreateMouseEvent(NULL, kCGEventOtherMouseDown, loc, button);
    CGEventRef up   = CGEventCreateMouseEvent(NULL, kCGEventOtherMouseUp,   loc, button);
    if (down) { CGEventPost(kCGHIDEventTap, down); CFRelease(down); }
    if (up)   { CGEventPost(kCGHIDEventTap, up);   CFRelease(up); }
}

@end
