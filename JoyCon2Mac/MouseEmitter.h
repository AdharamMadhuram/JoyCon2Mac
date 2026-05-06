#ifndef MOUSE_EMITTER_H
#define MOUSE_EMITTER_H

#import <Foundation/Foundation.h>
#import "DriverKitClient.h"
#include "JoyConDecoder.h"

// Mouse mode cycle matches joycon2cpp/testapp/src/testapp.cpp exactly:
//   0 = OFF, 1 = FAST (sens 1.0), 2 = NORMAL (sens 0.6), 3 = SLOW (sens 0.3)
// Do not reorder these — main.mm and the GUI depend on these raw values.
typedef NS_ENUM(NSInteger, MouseMode) {
    MouseModeOff    = 0,
    MouseModeFast   = 1,
    MouseModeNormal = 2,
    MouseModeSlow   = 3
};

@interface MouseEmitter : NSObject

@property (nonatomic, assign) MouseMode currentMode;
@property (nonatomic, assign) DriverKitClient *driverClient;

// Raw optical history (joycon2cpp: lastOpticalX / lastOpticalY / firstOpticalRead).
@property (nonatomic, assign) BOOL firstOpticalRead;
@property (nonatomic, assign) int16_t lastOpticalX;
@property (nonatomic, assign) int16_t lastOpticalY;

// Scroll accumulator (joycon2cpp: scrollAccumulator, 120 units per wheel click).
@property (nonatomic, assign) float scrollAccumulator;

// Button edge-detect state (joycon2cpp: leftBtnPressed / rightBtnPressed /
// middleBtnPressed / mb4Pressed / mb5Pressed).
@property (nonatomic, assign) BOOL leftBtnPressed;
@property (nonatomic, assign) BOOL rightBtnPressed;
@property (nonatomic, assign) BOOL middleBtnPressed;
@property (nonatomic, assign) BOOL mb4Pressed;
@property (nonatomic, assign) BOOL mb5Pressed;

- (instancetype)initWithDriverClient:(DriverKitClient *)client;

// Feed a fresh Right Joy-Con input buffer. Mirrors the inline ValueChanged
// handler in joycon2cpp/testapp/src/testapp.cpp (single-Joy-Con branch,
// mouse-mode section). buffer may be mutated — we clear the HID bits that
// the mouse consumed so they don't also fire the gamepad report.
- (void)processRightJoyConBuffer:(std::vector<uint8_t> &)buffer
                     buttonState:(uint32_t)btnState
                    stickReading:(StickData)stickData;

@end

#endif // MOUSE_EMITTER_H
