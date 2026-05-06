#import "MouseEmitter.h"
#import <ApplicationServices/ApplicationServices.h>
#include <cstdlib>

// Structurally a port of the single-Right-JoyCon mouse handler from
// joycon2cpp/testapp/src/testapp.cpp, extended so the left Joy-Con 2 can
// also drive the mouse. joycon2cpp's reference only wires it up for the
// right side, but both Joy-Con 2 halves carry the same optical sensor at
// packet offset 0x10..0x13 and distance flag at 0x17, so the same decode
// logic applies verbatim.
//
// Constants kept byte-for-byte with joycon2cpp:
//   scroll deadzone 4000, scroll cap 40 per packet, 120 units per wheel
//   click, XY side-button threshold 28000, sensitivities 1.0/0.6/0.3.

@interface MouseEmitter ()
// Per-side optical history. When the active side switches (either the user
// changed the picker or auto-detection flipped because the other Joy-Con
// just landed on a surface) we use the captured LAST value for *that* side,
// not the other side's last value. Using the wrong side's last value is
// where the "spazz out" came from — the delta was effectively (thisX -
// otherX) which is a random huge number.
@property (nonatomic, assign) BOOL firstOpticalReadLeft;
@property (nonatomic, assign) BOOL firstOpticalReadRight;
@property (nonatomic, assign) int16_t lastOpticalXLeft;
@property (nonatomic, assign) int16_t lastOpticalYLeft;
@property (nonatomic, assign) int16_t lastOpticalXRight;
@property (nonatomic, assign) int16_t lastOpticalYRight;

// Shared click / scroll / side-button state. The mouse pointer is a single
// macOS object; it doesn't matter which Joy-Con clicked. We don't want
// clicks to stick down if you switch sides mid-press, so releasing a side
// releases all sticky state (handled in the Auto-switchover branch).
@property (nonatomic, assign) float scrollAccumulator;
@property (nonatomic, assign) BOOL leftBtnPressed;
@property (nonatomic, assign) BOOL rightBtnPressed;
@property (nonatomic, assign) BOOL middleBtnPressed;
@property (nonatomic, assign) BOOL mb4Pressed;
@property (nonatomic, assign) BOOL mb5Pressed;

@property (nonatomic, assign) JoyConSide lastActiveSide;

- (void)sendMoveDeltaX:(int)dx deltaY:(int)dy;
- (void)sendMouseButton:(uint8_t)bit down:(BOOL)down location:(CGPoint)loc;
- (CGPoint)currentCursor;
- (void)sendScrollClicks:(int)clicks;
- (void)sendXButton:(int)which;
- (void)releaseAllMouseButtons;
@end

@implementation MouseEmitter

- (instancetype)initWithDriverClient:(DriverKitClient *)client {
    self = [super init];
    if (self) {
        _driverClient = client;
        _currentMode = MouseModeOff;
        _source = MouseSourceAuto;
        _lastActiveSide = JoyConSide::Right;
        _firstOpticalReadLeft = YES;
        _firstOpticalReadRight = YES;
        _lastOpticalXLeft = 0;
        _lastOpticalYLeft = 0;
        _lastOpticalXRight = 0;
        _lastOpticalYRight = 0;
        _scrollAccumulator = 0.0f;
        _leftBtnPressed = NO;
        _rightBtnPressed = NO;
        _middleBtnPressed = NO;
        _mb4Pressed = NO;
        _mb5Pressed = NO;
    }
    return self;
}

- (void)setCurrentMode:(MouseMode)currentMode {
    if (_currentMode == currentMode) return;
    _currentMode = currentMode;
    // Any transition resets the per-side optical history so the first
    // sample after re-enabling doesn't produce a giant delta (the "pointer
    // teleports across the screen" bug when you toggled OFF -> SLOW).
    _firstOpticalReadLeft = YES;
    _firstOpticalReadRight = YES;
    _scrollAccumulator = 0.0f;
    if (currentMode == MouseModeOff) {
        [self releaseAllMouseButtons];
    }
}

- (void)setSource:(MouseSource)source {
    if (_source == source) return;
    _source = source;
    // Switching between Left / Right / Auto wipes the pending delta history
    // for both sides so we don't compute a stale-vs-fresh delta.
    _firstOpticalReadLeft = YES;
    _firstOpticalReadRight = YES;
    _scrollAccumulator = 0.0f;
    [self releaseAllMouseButtons];
}

- (BOOL)processBuffer:(std::vector<uint8_t> &)buffer
                 side:(JoyConSide)side
          buttonState:(uint32_t)btnState
         stickReading:(StickData)stickData
        mouseDistance:(uint16_t)mouseDistance {
    if (_currentMode == MouseModeOff) {
        return NO;
    }

    // Pick the side that "owns" this packet. Auto uses the classical rule:
    // a Joy-Con on a surface reports a non-zero distance at byte 0x17, one
    // being held in the air reports 0. If both are non-zero, keep whichever
    // we were using last (avoid ping-ponging). If both are zero and we have
    // no history, default to Right — joycon2cpp's original pick.
    JoyConSide activeSide = _lastActiveSide;
    switch (_source) {
        case MouseSourceLeft:  activeSide = JoyConSide::Left;  break;
        case MouseSourceRight: activeSide = JoyConSide::Right; break;
        case MouseSourceAuto:
        default: {
            if (mouseDistance != 0) {
                // This side is on a surface. Adopt it if the other side
                // isn't already owning the pointer while also on a surface.
                if (side != _lastActiveSide) {
                    activeSide = side;
                }
            }
            break;
        }
    }

    if (side != activeSide) {
        // Not the active side — don't consume the packet. Update the
        // inactive side's optical baseline so if we switch to it later the
        // first delta is sane, and leave the gamepad path untouched.
        if (side == JoyConSide::Left) {
            _firstOpticalReadLeft = YES;
        } else {
            _firstOpticalReadRight = YES;
        }
        return NO;
    }

    if (activeSide != _lastActiveSide) {
        // Auto just promoted a different side. Drop any sticky clicks so
        // a press that never released on the old side doesn't leak over.
        [self releaseAllMouseButtons];
        _scrollAccumulator = 0.0f;
        _lastActiveSide = activeSide;
    }

    BOOL isLeft = (activeSide == JoyConSide::Left);

    // --- 1. Optical mouse movement (joycon2cpp testapp.cpp) ---
    std::pair<int16_t, int16_t> raw = GetRawOpticalMouse(buffer);
    int16_t rawX = raw.first;
    int16_t rawY = raw.second;

    BOOL *firstReadPtr  = isLeft ? &_firstOpticalReadLeft  : &_firstOpticalReadRight;
    int16_t *lastXPtr   = isLeft ? &_lastOpticalXLeft      : &_lastOpticalXRight;
    int16_t *lastYPtr   = isLeft ? &_lastOpticalYLeft      : &_lastOpticalYRight;

    if (*firstReadPtr) {
        *lastXPtr = rawX;
        *lastYPtr = rawY;
        *firstReadPtr = NO;
    } else {
        int16_t dx = (int16_t)(rawX - *lastXPtr);
        int16_t dy = (int16_t)(rawY - *lastYPtr);
        *lastXPtr = rawX;
        *lastYPtr = rawY;

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

    // --- 2. Mouse buttons ---
    // joycon2cpp maps R (0x004000) → left, ZR (0x008000) → right, R3
    // (0x000004) → middle on the RIGHT Joy-Con. The left Joy-Con's
    // matching buttons live in the lower 16 bits: L (0x0040), ZL (0x0080),
    // L3 (0x0800).
    uint32_t leftMask, rightMask, middleMask;
    if (isLeft) {
        leftMask   = 0x0040;    // L
        rightMask  = 0x0080;    // ZL
        middleMask = 0x0800;    // L3
    } else {
        leftMask   = 0x004000;  // R
        rightMask  = 0x008000;  // ZR
        middleMask = 0x000004;  // R3
    }

    BOOL mouseLeftNow   = (btnState & leftMask)   != 0;
    BOOL mouseRightNow  = (btnState & rightMask)  != 0;
    BOOL mouseMiddleNow = (btnState & middleMask) != 0;

    CGPoint loc = [self currentCursor];
    if (mouseLeftNow != _leftBtnPressed) {
        [self sendMouseButton:0x01 down:mouseLeftNow location:loc];
        _leftBtnPressed = mouseLeftNow;
    }
    if (mouseRightNow != _rightBtnPressed) {
        [self sendMouseButton:0x02 down:mouseRightNow location:loc];
        _rightBtnPressed = mouseRightNow;
    }
    if (mouseMiddleNow != _middleBtnPressed) {
        [self sendMouseButton:0x04 down:mouseMiddleNow location:loc];
        _middleBtnPressed = mouseMiddleNow;
    }

    // --- 3. Stick scrolling + side buttons (joycon2cpp constants) ---
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

    // --- 4. Suppress consumed inputs in the buffer for the gamepad path ---
    //     The caller will re-extract buttons/stick from this stripped
    //     buffer, so the virtual gamepad never sees the mouse clicks.
    //     Per-side: left Joy-Con's bit layout is in the low byte (buffer[6]
    //     for L/ZL, buffer[5] for L3 which is 0x0800 = buffer[5] & 0x08).
    //     Right's bits live in buffer[4]/buffer[5] per joycon2cpp.
    if (isLeft) {
        if (buffer.size() >= 7) {
            buffer[6] &= ~0x40;   // L
            buffer[6] &= ~0x80;   // ZL
            buffer[5] &= ~0x08;   // L3 (0x0800 in the 24-bit state)
        }
        if (buffer.size() >= 13) {
            // Left stick bytes at 10..12, neutral = 00 08 80 (same pattern
            // joycon2cpp uses for the right stick at 13..15 — the byte
            // layout is identical, only the offset differs).
            buffer[10] = 0x00;
            buffer[11] = 0x08;
            buffer[12] = 0x80;
        }
    } else {
        if (buffer.size() >= 6) {
            buffer[4] &= ~0x40;   // R
            buffer[4] &= ~0x80;   // ZR
            buffer[5] &= ~0x04;   // R3
        }
        if (buffer.size() >= 16) {
            buffer[13] = 0x00;
            buffer[14] = 0x08;
            buffer[15] = 0x80;
        }
    }

    return YES;
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

- (void)releaseAllMouseButtons {
    CGPoint loc = [self currentCursor];
    if (_leftBtnPressed) {
        [self sendMouseButton:0x01 down:NO location:loc];
        _leftBtnPressed = NO;
    }
    if (_rightBtnPressed) {
        [self sendMouseButton:0x02 down:NO location:loc];
        _rightBtnPressed = NO;
    }
    if (_middleBtnPressed) {
        [self sendMouseButton:0x04 down:NO location:loc];
        _middleBtnPressed = NO;
    }
    _mb4Pressed = NO;
    _mb5Pressed = NO;
}

@end
