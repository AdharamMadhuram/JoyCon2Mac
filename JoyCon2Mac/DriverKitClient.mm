#import "DriverKitClient.h"
#import <IOKit/IOKitLib.h>

@interface DriverKitClient ()
@property (nonatomic, assign) io_service_t service;
@property (nonatomic, assign) io_connect_t connection;
@property (nonatomic, assign) BOOL isRunning;
@end

@implementation DriverKitClient

- (instancetype)init {
    self = [super init];
    if (self) {
        _service = IO_OBJECT_NULL;
        _connection = IO_OBJECT_NULL;
        _isRunning = NO;
    }
    return self;
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-missing-super-calls"
- (void)dealloc {
    [self stop];
}
#pragma clang diagnostic pop

- (BOOL)start {
    if (_isRunning) return YES;
    
    CFMutableDictionaryRef matchingDict = IOServiceMatching("VirtualJoyConDriver");
    if (!matchingDict) return NO;
    
    _service = IOServiceGetMatchingService(kIOMasterPortDefault, matchingDict);
    if (_service == IO_OBJECT_NULL) {
        NSLog(@"[DriverKitClient] ✗ VirtualJoyConDriver not found. Is the extension loaded?");
        return NO;
    }
    
    kern_return_t ret = IOServiceOpen(_service, mach_task_self(), 0, &_connection);
    if (ret != KERN_SUCCESS) {
        NSLog(@"[DriverKitClient] ✗ Failed to open connection: 0x%x", ret);
        IOObjectRelease(_service);
        _service = IO_OBJECT_NULL;
        return NO;
    }
    
    _isRunning = YES;
    NSLog(@"[DriverKitClient] ✓ Connected to VirtualJoyConDriver");
    return YES;
}

- (void)stop {
    if (_connection != IO_OBJECT_NULL) {
        IOServiceClose(_connection);
        _connection = IO_OBJECT_NULL;
    }
    if (_service != IO_OBJECT_NULL) {
        IOObjectRelease(_service);
        _service = IO_OBJECT_NULL;
    }
    _isRunning = NO;
}

- (void)postGamepadReport:(struct JoyConReportData)report {
    if (!_isRunning || _connection == IO_OBJECT_NULL) return;
    
    size_t outputSize = 0;
    // Method selector 0 for postGamepadReport
    kern_return_t ret = IOConnectCallStructMethod(_connection, 0, &report, sizeof(report), NULL, &outputSize);
    if (ret != KERN_SUCCESS) {
        static int errorCount = 0;
        if (errorCount++ % 120 == 0) NSLog(@"[DriverKitClient] Failed to post gamepad report: 0x%x", ret);
    }
}

- (void)postMouseReport:(struct JoyConMouseReportData)report {
    if (!_isRunning || _connection == IO_OBJECT_NULL) return;
    
    size_t outputSize = 0;
    // Method selector 1 for postMouseReport
    kern_return_t ret = IOConnectCallStructMethod(_connection, 1, &report, sizeof(report), NULL, &outputSize);
    if (ret != KERN_SUCCESS) {
        static int errorCount = 0;
        if (errorCount++ % 120 == 0) NSLog(@"[DriverKitClient] Failed to post mouse report: 0x%x", ret);
    }
}

- (void)postNFCReport:(struct JoyConNFCReportData)report {
    if (!_isRunning || _connection == IO_OBJECT_NULL) return;
    
    size_t outputSize = 0;
    // Method selector 2 for postNFCReport
    kern_return_t ret = IOConnectCallStructMethod(_connection, 2, &report, sizeof(report), NULL, &outputSize);
    if (ret != KERN_SUCCESS) {
        static int errorCount = 0;
        if (errorCount++ % 120 == 0) NSLog(@"[DriverKitClient] Failed to post NFC report: 0x%x", ret);
    }
}

+ (uint32_t)convertButtonsToHID:(uint32_t)leftButtons rightButtons:(uint32_t)rightButtons dpadUp:(BOOL)up dpadDown:(BOOL)down dpadLeft:(BOOL)left dpadRight:(BOOL)right {
    (void)up;
    (void)down;
    (void)left;
    (void)right;
    uint32_t hidButtons = 0;
    
    // Face buttons
    if (rightButtons & 0x000800) hidButtons |= (1 << 0);      // A
    if (rightButtons & 0x000200) hidButtons |= (1 << 1);      // B
    if (rightButtons & 0x000400) hidButtons |= (1 << 2);      // X
    if (rightButtons & 0x000100) hidButtons |= (1 << 3);      // Y
    
    // Shoulders
    if (leftButtons & 0x0040) hidButtons |= (1 << 4);         // L
    if (rightButtons & 0x004000) hidButtons |= (1 << 5);      // R
    if (leftButtons & 0x0080) hidButtons |= (1 << 6);         // ZL
    if (rightButtons & 0x008000) hidButtons |= (1 << 7);      // ZR
    
    // System
    if (leftButtons & 0x0100) hidButtons |= (1 << 8);         // Minus
    if (rightButtons & 0x000002) hidButtons |= (1 << 9);      // Plus
    if (leftButtons & 0x2000) hidButtons |= (1 << 12);        // Capture
    if (rightButtons & 0x000010) hidButtons |= (1 << 13);     // Home
    
    // Stick clicks
    if (leftButtons & 0x0800) hidButtons |= (1 << 10);        // L3
    if (rightButtons & 0x000004) hidButtons |= (1 << 11);     // R3

    // Side rail buttons. Joy2Win exposes these as R4/R5/L4/L5; keep them as
    // distinct HID buttons so games can bind them directly.
    if (rightButtons & 0x001000) hidButtons |= (1 << 14);     // SRR
    if (rightButtons & 0x002000) hidButtons |= (1 << 15);     // SLR
    if (leftButtons & 0x0020) hidButtons |= (1 << 16);        // SLL
    if (leftButtons & 0x0010) hidButtons |= (1 << 17);        // SRL

    return hidButtons;
}

@end
