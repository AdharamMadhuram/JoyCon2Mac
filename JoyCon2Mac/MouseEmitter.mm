#import "MouseEmitter.h"
#import <ApplicationServices/ApplicationServices.h>

@interface MouseEmitter ()
- (void)postCGMouseDeltaX:(int16_t)deltaX deltaY:(int16_t)deltaY buttons:(uint8_t)buttons scroll:(int8_t)scroll;
@end

@implementation MouseEmitter

- (instancetype)initWithDriverClient:(DriverKitClient *)client {
    self = [super init];
    if (self) {
        _driverClient = client;
        _currentMode = MouseModeOff;
        _hasPreviousRawPosition = NO;
        _previousRawX = 0;
        _previousRawY = 0;
        _previousMouseButtons = 0;
    }
    return self;
}

- (void)processOpticalDataX:(int16_t)rawX y:(int16_t)rawY buttons:(uint32_t)buttons side:(JoyConSide)side joyY:(int16_t)joyY {
    if (_currentMode == MouseModeOff) {
        _hasPreviousRawPosition = NO;
        _previousMouseButtons = 0;
        return;
    }
    
    float multiplier = 1.0f;
    switch (_currentMode) {
        case MouseModeSlow: multiplier = 0.3f; break;
        case MouseModeNormal: multiplier = 0.6f; break;
        case MouseModeFast: multiplier = 1.2f; break;
        default: break;
    }
    
    int32_t deltaX = 0;
    int32_t deltaY = 0;
    if (_hasPreviousRawPosition) {
        deltaX = (int32_t)rawX - (int32_t)_previousRawX;
        deltaY = (int32_t)rawY - (int32_t)_previousRawY;
        if (deltaX > 32767) deltaX -= 65536;
        if (deltaX < -32768) deltaX += 65536;
        if (deltaY > 32767) deltaY -= 65536;
        if (deltaY < -32768) deltaY += 65536;
    }
    _previousRawX = rawX;
    _previousRawY = rawY;
    _hasPreviousRawPosition = YES;

    int16_t finalX = (int16_t)(deltaX * multiplier);
    int16_t finalY = (int16_t)(deltaY * multiplier);
    
    // Map joyY to scroll wheel (assuming stick Y ranges from -2048 to 2048 or similar)
    int8_t scroll = 0;
    if (joyY > 1000) scroll = 1;
    else if (joyY < -1000) scroll = -1;
    
    uint8_t mouseButtons = 0;
    if (side == JoyConSide::Left) {
        if (buttons & 0x0040) mouseButtons |= 1; // L -> Left
        if (buttons & 0x0080) mouseButtons |= 2; // ZL -> Right
    } else {
        if (buttons & 0x4000) mouseButtons |= 1; // R -> Left
        if (buttons & 0x8000) mouseButtons |= 2; // ZR -> Right
    }
    
    struct JoyConMouseReportData mouseReport = {
        .buttons = mouseButtons,
        .deltaX = finalX,
        .deltaY = finalY,
        .scroll = scroll
    };

    if (_driverClient && _driverClient.isRunning) {
        [_driverClient postMouseReport:mouseReport];
    } else {
        [self postCGMouseDeltaX:finalX deltaY:finalY buttons:mouseButtons scroll:scroll];
    }
}

- (void)postCGMouseDeltaX:(int16_t)deltaX deltaY:(int16_t)deltaY buttons:(uint8_t)buttons scroll:(int8_t)scroll {
    CGEventRef currentEvent = CGEventCreate(NULL);
    CGPoint location = currentEvent ? CGEventGetLocation(currentEvent) : CGPointZero;
    if (currentEvent) {
        CFRelease(currentEvent);
    }

    if (deltaX != 0 || deltaY != 0) {
        CGPoint target = CGPointMake(location.x + deltaX, location.y + deltaY);
        CGEventRef move = CGEventCreateMouseEvent(NULL, kCGEventMouseMoved, target, kCGMouseButtonLeft);
        if (move) {
            CGEventPost(kCGHIDEventTap, move);
            CFRelease(move);
            location = target;
        }
    }

    uint8_t changed = buttons ^ _previousMouseButtons;
    if (changed & 0x01) {
        CGEventType type = (buttons & 0x01) ? kCGEventLeftMouseDown : kCGEventLeftMouseUp;
        CGEventRef event = CGEventCreateMouseEvent(NULL, type, location, kCGMouseButtonLeft);
        if (event) {
            CGEventPost(kCGHIDEventTap, event);
            CFRelease(event);
        }
    }
    if (changed & 0x02) {
        CGEventType type = (buttons & 0x02) ? kCGEventRightMouseDown : kCGEventRightMouseUp;
        CGEventRef event = CGEventCreateMouseEvent(NULL, type, location, kCGMouseButtonRight);
        if (event) {
            CGEventPost(kCGHIDEventTap, event);
            CFRelease(event);
        }
    }

    if (scroll != 0) {
        CGEventRef event = CGEventCreateScrollWheelEvent(NULL, kCGScrollEventUnitLine, 1, scroll);
        if (event) {
            CGEventPost(kCGHIDEventTap, event);
            CFRelease(event);
        }
    }

    _previousMouseButtons = buttons;
}

@end
