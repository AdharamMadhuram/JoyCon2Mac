#ifndef MOUSE_EMITTER_H
#define MOUSE_EMITTER_H

#import <Foundation/Foundation.h>
#import "DriverKitClient.h"
#include "JoyConDecoder.h"

typedef NS_ENUM(NSInteger, MouseMode) {
    MouseModeOff = 0,
    MouseModeSlow = 1,
    MouseModeNormal = 2,
    MouseModeFast = 3
};

@interface MouseEmitter : NSObject

@property (nonatomic, assign) MouseMode currentMode;
@property (nonatomic, assign) DriverKitClient *driverClient;
@property (nonatomic, assign) BOOL hasPreviousRawPosition;
@property (nonatomic, assign) int16_t previousRawX;
@property (nonatomic, assign) int16_t previousRawY;
@property (nonatomic, assign) uint8_t previousMouseButtons;

- (instancetype)initWithDriverClient:(DriverKitClient *)client;

- (void)processOpticalDataX:(int16_t)rawX y:(int16_t)rawY buttons:(uint32_t)buttons side:(JoyConSide)side joyY:(int16_t)joyY;

@end

#endif // MOUSE_EMITTER_H
