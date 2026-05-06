#import "DriverKitClient.h"
#import <IOKit/IOKitLib.h>

static BOOL servicePropertyEquals(io_service_t service, CFStringRef key, CFStringRef expected) {
    if (service == IO_OBJECT_NULL) return NO;

    CFTypeRef value = IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0);
    if (!value) return NO;

    BOOL equals = CFGetTypeID(value) == CFStringGetTypeID() && CFEqual(value, expected);
    CFRelease(value);
    return equals;
}

static BOOL isVirtualJoyConService(io_service_t service) {
    return servicePropertyEquals(service, CFSTR("IOUserClass"), CFSTR("VirtualJoyConDriver")) &&
           servicePropertyEquals(service, CFSTR("CFBundleIdentifier"), CFSTR("local.joycon2mac.driver")) &&
           servicePropertyEquals(service, CFSTR("IOUserServerName"), CFSTR("local.joycon2mac.driver"));
}

static io_service_t copyVirtualJoyConServiceFromIterator(io_iterator_t iterator) {
    io_service_t service = IO_OBJECT_NULL;
    while ((service = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        if (isVirtualJoyConService(service)) {
            return service;
        }
        IOObjectRelease(service);
    }
    return IO_OBJECT_NULL;
}

static io_service_t copyVirtualJoyConService(void) {
    io_service_t service = IOServiceGetMatchingService(kIOMasterPortDefault,
                                                       IOServiceNameMatching("VirtualJoyConDriver"));
    if (service != IO_OBJECT_NULL) {
        if (isVirtualJoyConService(service)) {
            return service;
        }
        IOObjectRelease(service);
    }

    service = IOServiceGetMatchingService(kIOMasterPortDefault,
                                          IOServiceMatching("VirtualJoyConDriver"));
    if (service != IO_OBJECT_NULL) {
        if (isVirtualJoyConService(service)) {
            return service;
        }
        IOObjectRelease(service);
    }

    io_iterator_t iterator = IO_OBJECT_NULL;
    kern_return_t kr = IOServiceGetMatchingServices(kIOMasterPortDefault,
                                                    IOServiceMatching("IOUserService"),
                                                    &iterator);
    if (kr != KERN_SUCCESS || iterator == IO_OBJECT_NULL) {
        return IO_OBJECT_NULL;
    }

    service = copyVirtualJoyConServiceFromIterator(iterator);
    IOObjectRelease(iterator);
    return service;
}

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

    _service = copyVirtualJoyConService();
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
    // All masks below match joycon2cpp/testapp/src/JoyConDecoder.cpp
    // (BUTTON_*_MASK_LEFT / _RIGHT). The single ExtractButtonState variant
    // in JoyConDecoder.cpp already produces the 24-bit state these masks
    // are designed against.
    uint32_t hidButtons = 0;

    // Face buttons (Right Joy-Con)
    if (rightButtons & 0x000800) hidButtons |= (1 << 0);      // A
    if (rightButtons & 0x000200) hidButtons |= (1 << 1);      // B
    if (rightButtons & 0x000400) hidButtons |= (1 << 2);      // X
    if (rightButtons & 0x000100) hidButtons |= (1 << 3);      // Y

    // Shoulders
    if (leftButtons  & 0x000040) hidButtons |= (1 << 4);      // L  (BUTTON_L_MASK_LEFT)
    if (rightButtons & 0x004000) hidButtons |= (1 << 5);      // R  (BUTTON_R_MASK_RIGHT)
    if (leftButtons  & 0x000080) hidButtons |= (1 << 6);      // ZL (trigger bit, left)
    if (rightButtons & 0x008000) hidButtons |= (1 << 7);      // ZR (trigger bit, right)

    // System
    if (leftButtons  & 0x000100) hidButtons |= (1 << 8);      // Minus
    if (rightButtons & 0x000002) hidButtons |= (1 << 9);      // Plus
    if (leftButtons  & 0x002000) hidButtons |= (1 << 12);     // Capture
    if (rightButtons & 0x000010) hidButtons |= (1 << 13);     // Home

    // Stick clicks
    if (leftButtons  & 0x000800) hidButtons |= (1 << 10);     // L3 (BUTTON_STICK_MASK_LEFT)
    if (rightButtons & 0x000004) hidButtons |= (1 << 11);     // R3 (BUTTON_STICK_MASK_RIGHT)

    // Side rail (SL/SR on each rail). joycon2cpp exposes these as distinct
    // bits inside the decoded state, so we forward each as its own HID button.
    if (rightButtons & 0x001000) hidButtons |= (1 << 14);     // SR (right rail)
    if (rightButtons & 0x002000) hidButtons |= (1 << 15);     // SL (right rail)
    if (leftButtons  & 0x000020) hidButtons |= (1 << 16);     // SL (left rail)
    if (leftButtons  & 0x000010) hidButtons |= (1 << 17);     // SR (left rail)

    return hidButtons;
}

@end
