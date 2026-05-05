#include "VirtualJoyConDriver.h"
#include <os/log.h>
#include <string.h>
#include <DriverKit/IOBufferMemoryDescriptor.h>
#include <DriverKit/IOLib.h>
#include <DriverKit/IOMemoryDescriptor.h>
#include <DriverKit/OSData.h>
#include <DriverKit/OSDictionary.h>
#include <DriverKit/OSNumber.h>
#include <DriverKit/OSString.h>
#include <DriverKit/OSAction.h>
#include <DriverKit/IOUserClient.h>
#include <HIDDriverKit/IOHIDDeviceKeys.h>
#include <HIDDriverKit/IOHIDDeviceTypes.h>
#include <HIDDriverKit/IOHIDUsageTables.h>

struct JoyConHIDGamepadReport {
    uint8_t reportId;
    uint32_t buttons;
    uint8_t dpad; // 4-way hat switch
    int16_t x;
    int16_t y;
    int16_t z; // Right stick X
    int16_t rz; // Right stick Y
    uint8_t l2; // Left Trigger Analog
    uint8_t r2; // Right Trigger Analog
} __attribute__((packed));

struct JoyConHIDMouseReport {
    uint8_t reportId; // 2
    uint8_t buttons;  // 3 buttons: Left, Right, Middle (mapped to bits 0,1,2)
    int16_t x;
    int16_t y;
    int8_t wheel;
} __attribute__((packed));

struct JoyConHIDNFCReport {
    uint8_t reportId; // 3
    uint8_t status;
    uint8_t tagId[7];
    uint8_t payload[32];
} __attribute__((packed));

enum : uint64_t {
    kVirtualJoyConSelectorGamepad = 0,
    kVirtualJoyConSelectorMouse = 1,
    kVirtualJoyConSelectorNFC = 2,
    kVirtualJoyConSelectorCount = 3
};

static VirtualJoyConDriver * gVirtualJoyConOwner = nullptr;

// Composite HID Descriptor (Gamepad + Mouse + Vendor Defined NFC)
const uint8_t VirtualCompositeDescriptor[] = {
    // --- GAMEPAD (Report ID 1) ---
    0x05, 0x01,        // Usage Page (Generic Desktop Ctrls)
    0x09, 0x05,        // Usage (Game Pad)
    0xA1, 0x01,        // Collection (Application)
    0x85, 0x01,        //   Report ID (1)
    
    // Buttons (18 bits)
    0x05, 0x09,        //   Usage Page (Button)
    0x19, 0x01,        //   Usage Minimum (0x01)
    0x29, 0x12,        //   Usage Maximum (0x12)
    0x15, 0x00,        //   Logical Minimum (0)
    0x25, 0x01,        //   Logical Maximum (1)
    0x95, 0x12,        //   Report Count (18)
    0x75, 0x01,        //   Report Size (1)
    0x81, 0x02,        //   Input (Data,Var,Abs)
    
    // Padding (14 bits) -> Aligns to uint32_t buttons
    0x95, 0x01,        //   Report Count (1)
    0x75, 0x0E,        //   Report Size (14)
    0x81, 0x03,        //   Input (Const,Var,Abs)

    // Hat Switch (D-Pad) (1 nibble)
    0x05, 0x01,        //   Usage Page (Generic Desktop Ctrls)
    0x09, 0x39,        //   Usage (Hat switch)
    0x15, 0x00,        //   Logical Minimum (0)
    0x25, 0x07,        //   Logical Maximum (7)
    0x35, 0x00,        //   Physical Minimum (0)
    0x46, 0x3B, 0x01,  //   Physical Maximum (315)
    0x65, 0x14,        //   Unit (System: English Rotation, Length: Centimeter)
    0x95, 0x01,        //   Report Count (1)
    0x75, 0x04,        //   Report Size (4)
    0x81, 0x42,        //   Input (Data,Var,Abs,Null State)
    
    // Padding (1 nibble) -> Aligns Hat Switch to 1 byte
    0x95, 0x01,        //   Report Count (1)
    0x75, 0x04,        //   Report Size (4)
    0x81, 0x03,        //   Input (Const,Var,Abs)
    
    // Left & Right Sticks (4 axes: X, Y, Z, Rz) - 16 bit
    0x05, 0x01,        //   Usage Page (Generic Desktop Ctrls)
    0x09, 0x30,        //   Usage (X)
    0x09, 0x31,        //   Usage (Y)
    0x09, 0x32,        //   Usage (Z)
    0x09, 0x35,        //   Usage (Rz)
    0x16, 0x00, 0x80,  //   Logical Minimum (-32768)
    0x26, 0xFF, 0x7F,  //   Logical Maximum (32767)
    0x36, 0x00, 0x80,  //   Physical Minimum (-32768)
    0x46, 0xFF, 0x7F,  //   Physical Maximum (32767)
    0x95, 0x04,        //   Report Count (4)
    0x75, 0x10,        //   Report Size (16)
    0x81, 0x02,        //   Input (Data,Var,Abs)

    // Analog Triggers (2 axes: Rx, Ry mapping to L2/R2) - 8 bit
    0x09, 0x33,        //   Usage (Rx)
    0x09, 0x34,        //   Usage (Ry)
    0x15, 0x00,        //   Logical Minimum (0)
    0x26, 0xFF, 0x00,  //   Logical Maximum (255)
    0x35, 0x00,        //   Physical Minimum (0)
    0x46, 0xFF, 0x00,  //   Physical Maximum (255)
    0x95, 0x02,        //   Report Count (2)
    0x75, 0x08,        //   Report Size (8)
    0x81, 0x02,        //   Input (Data,Var,Abs)

    0xC0,              // End Collection

    // --- MOUSE (Report ID 2) ---
    0x05, 0x01,        // Usage Page (Generic Desktop)
    0x09, 0x02,        // Usage (Mouse)
    0xA1, 0x01,        // Collection (Application)
    0x85, 0x02,        //   Report ID (2)
    0x09, 0x01,        //   Usage (Pointer)
    0xA1, 0x00,        //   Collection (Physical)
    
    // Mouse Buttons (3 buttons)
    0x05, 0x09,        //     Usage Page (Button)
    0x19, 0x01,        //     Usage Minimum (1)
    0x29, 0x03,        //     Usage Maximum (3)
    0x15, 0x00,        //     Logical Minimum (0)
    0x25, 0x01,        //     Logical Maximum (1)
    0x95, 0x03,        //     Report Count (3)
    0x75, 0x01,        //     Report Size (1)
    0x81, 0x02,        //     Input (Data,Var,Abs)
    
    // Padding (5 bits)
    0x95, 0x01,        //     Report Count (1)
    0x75, 0x05,        //     Report Size (5)
    0x81, 0x03,        //     Input (Const,Var,Abs)
    
    // Mouse X/Y (16-bit relative)
    0x05, 0x01,        //     Usage Page (Generic Desktop)
    0x09, 0x30,        //     Usage (X)
    0x09, 0x31,        //     Usage (Y)
    0x16, 0x00, 0x80,  //     Logical Minimum (-32768)
    0x26, 0xFF, 0x7F,  //     Logical Maximum (32767)
    0x95, 0x02,        //     Report Count (2)
    0x75, 0x10,        //     Report Size (16)
    0x81, 0x06,        //     Input (Data,Var,Rel)
    
    // Mouse Wheel (8-bit relative)
    0x09, 0x38,        //     Usage (Wheel)
    0x15, 0x81,        //     Logical Minimum (-127)
    0x25, 0x7F,        //     Logical Maximum (127)
    0x95, 0x01,        //     Report Count (1)
    0x75, 0x08,        //     Report Size (8)
    0x81, 0x06,        //     Input (Data,Var,Rel)

    0xC0,              //   End Collection
    0xC0,              // End Collection

    // --- NFC (Vendor Defined - Report ID 3) ---
    0x06, 0x00, 0xFF,  // Usage Page (Vendor Defined 0xFF00)
    0x09, 0x01,        // Usage (0x01)
    0xA1, 0x01,        // Collection (Application)
    0x85, 0x03,        //   Report ID (3)
    
    // Status (1 byte)
    0x09, 0x02,        //   Usage (0x02)
    0x15, 0x00,        //   Logical Minimum (0)
    0x26, 0xFF, 0x00,  //   Logical Maximum (255)
    0x95, 0x01,        //   Report Count (1)
    0x75, 0x08,        //   Report Size (8)
    0x81, 0x02,        //   Input (Data,Var,Abs)
    
    // Tag ID (7 bytes)
    0x09, 0x03,        //   Usage (0x03)
    0x95, 0x07,        //   Report Count (7)
    0x75, 0x08,        //   Report Size (8)
    0x81, 0x02,        //   Input (Data,Var,Abs)
    
    // Payload (32 bytes)
    0x09, 0x04,        //   Usage (0x04)
    0x95, 0x20,        //   Report Count (32)
    0x75, 0x08,        //   Report Size (8)
    0x81, 0x02,        //   Input (Data,Var,Abs)
    
    0xC0               // End Collection
};

bool VirtualJoyConDriver::init() {
    if (!super::init()) {
        return false;
    }
    return true;
}

void VirtualJoyConDriver::free() {
    super::free();
}

kern_return_t VirtualJoyConDriver::Start_Impl(IOService * provider) {
    kern_return_t ret;
    os_log(OS_LOG_DEFAULT, "VirtualJoyConDriver::Start called");

    ret = super::Start(provider);
    if (ret != kIOReturnSuccess) {
        return ret;
    }

    if (!gVirtualJoyConOwner) {
        gVirtualJoyConOwner = this;
        retain();
    }

    // Register ourselves with IOUserClient so our companion app can connect
    ret = RegisterService();
    if (ret != kIOReturnSuccess) {
        os_log(OS_LOG_DEFAULT, "VirtualJoyConDriver::RegisterService failed");
        if (gVirtualJoyConOwner == this) {
            gVirtualJoyConOwner = nullptr;
            release();
        }
        return ret;
    }

    os_log(OS_LOG_DEFAULT, "VirtualJoyConDriver successfully started");
    return kIOReturnSuccess;
}

kern_return_t VirtualJoyConDriver::Stop_Impl(IOService * provider) {
    os_log(OS_LOG_DEFAULT, "VirtualJoyConDriver::Stop called");
    if (gVirtualJoyConOwner == this) {
        gVirtualJoyConOwner = nullptr;
        release();
    }
    return super::Stop(provider);
}

kern_return_t VirtualJoyConDriver::NewUserClient_Impl(uint32_t type, IOUserClient ** userClient) {
    if (!userClient) {
        return kIOReturnBadArgument;
    }

    IOService * service = nullptr;
    kern_return_t ret = Create(this, "UserClientProperties", &service);
    if (ret != kIOReturnSuccess) {
        os_log(OS_LOG_DEFAULT, "VirtualJoyConDriver::Create user client failed: 0x%x", ret);
        return ret;
    }

    VirtualJoyConUserClient * client = OSDynamicCast(VirtualJoyConUserClient, service);
    if (!client) {
        if (service) {
            service->release();
        }
        return kIOReturnUnsupported;
    }

    *userClient = client;
    return kIOReturnSuccess;
}

OSData * VirtualJoyConDriver::newReportDescriptor() {
    os_log(OS_LOG_DEFAULT, "VirtualJoyConDriver returns Composite Report Descriptor");
    return OSData::withBytes(VirtualCompositeDescriptor, sizeof(VirtualCompositeDescriptor));
}

OSDictionary * VirtualJoyConDriver::newDeviceDescription() {
    OSDictionary * description = OSDictionary::withCapacity(8);
    if (!description) {
        return nullptr;
    }

    OSNumber * vendor = OSNumber::withNumber(1363, 32);
    OSNumber * product = OSNumber::withNumber(8192, 32);
    OSNumber * version = OSNumber::withNumber(1, 32);
    OSString * transport = OSString::withCString("Virtual");
    OSString * manufacturer = OSString::withCString("JoyCon2Mac");
    OSString * productName = OSString::withCString("Virtual Joy-Con 2 Composite");

    if (vendor) {
        description->setObject(kIOHIDVendorIDKey, vendor);
        vendor->release();
    }
    if (product) {
        description->setObject(kIOHIDProductIDKey, product);
        product->release();
    }
    if (version) {
        description->setObject(kIOHIDVersionNumberKey, version);
        version->release();
    }
    if (transport) {
        description->setObject(kIOHIDTransportKey, transport);
        transport->release();
    }
    if (manufacturer) {
        description->setObject(kIOHIDManufacturerKey, manufacturer);
        manufacturer->release();
    }
    if (productName) {
        description->setObject(kIOHIDProductKey, productName);
        productName->release();
    }

    return description;
}

kern_return_t VirtualJoyConDriver::setReport(IOMemoryDescriptor * report, IOHIDReportType reportType, IOOptionBits options, uint32_t completionTimeout, OSAction * action) {
    return kIOReturnUnsupported;
}

kern_return_t VirtualJoyConDriver::getReport(IOMemoryDescriptor * report, IOHIDReportType reportType, IOOptionBits options, uint32_t completionTimeout, OSAction * action) {
    return kIOReturnUnsupported;
}

// -----------------------------------------------------------------------------
// GAMEPAD REPORT
// -----------------------------------------------------------------------------
kern_return_t VirtualJoyConDriver::dispatchGamepadReport(JoyConReportData reportData) {
    JoyConHIDGamepadReport report = {};
    report.reportId = 1;

    // Convert our internal representation over to the exact HID byte boundaries
    report.buttons = reportData.buttons & 0x3FFFF; // Mask to 18 buttons max
    
    report.dpad = reportData.dpad;

    report.x = reportData.stickLX;
    report.y = reportData.stickLY;
    report.z = reportData.stickRX;
    report.rz = reportData.stickRY;
    report.l2 = reportData.triggerL;
    report.r2 = reportData.triggerR;

    // Allocate memory for the report and dispatch to System
    IOBufferMemoryDescriptor* memoryDescriptor = nullptr;
    kern_return_t ret = IOBufferMemoryDescriptor::Create(kIOMemoryDirectionInOut, sizeof(JoyConHIDGamepadReport), 0, &memoryDescriptor);

    if (ret == kIOReturnSuccess && memoryDescriptor != nullptr) {
        IOAddressSegment range = {};
        if (memoryDescriptor->GetAddressRange(&range) == kIOReturnSuccess &&
            range.address != 0 &&
            range.length >= sizeof(JoyConHIDGamepadReport)) {
            memcpy((void*)range.address, &report, sizeof(JoyConHIDGamepadReport));
            memoryDescriptor->SetLength(sizeof(JoyConHIDGamepadReport));
            ret = this->handleReport(0, memoryDescriptor, sizeof(JoyConHIDGamepadReport), kIOHIDReportTypeInput, 0);
        }
        memoryDescriptor->release();
    }
    
    return ret;
}

// -----------------------------------------------------------------------------
// MOUSE REPORT
// -----------------------------------------------------------------------------
kern_return_t VirtualJoyConDriver::dispatchMouseReport(JoyConMouseReportData reportData) {
    JoyConHIDMouseReport report = {};
    report.reportId = 2;
    
    report.buttons = reportData.buttons;
    report.x = reportData.deltaX;
    report.y = reportData.deltaY;
    report.wheel = reportData.scroll;

    IOBufferMemoryDescriptor* memoryDescriptor = nullptr;
    kern_return_t ret = IOBufferMemoryDescriptor::Create(kIOMemoryDirectionInOut, sizeof(JoyConHIDMouseReport), 0, &memoryDescriptor);

    if (ret == kIOReturnSuccess && memoryDescriptor != nullptr) {
        IOAddressSegment range = {};
        if (memoryDescriptor->GetAddressRange(&range) == kIOReturnSuccess &&
            range.address != 0 &&
            range.length >= sizeof(JoyConHIDMouseReport)) {
            memcpy((void*)range.address, &report, sizeof(JoyConHIDMouseReport));
            memoryDescriptor->SetLength(sizeof(JoyConHIDMouseReport));
            ret = this->handleReport(0, memoryDescriptor, sizeof(JoyConHIDMouseReport), kIOHIDReportTypeInput, 0);
        }
        memoryDescriptor->release();
    }
    
    return ret;
}

// -----------------------------------------------------------------------------
// NFC REPORT
// -----------------------------------------------------------------------------
kern_return_t VirtualJoyConDriver::dispatchNFCReport(JoyConNFCReportData reportData) {
    JoyConHIDNFCReport report = {};
    report.reportId = 3;
    
    report.status = reportData.status;
    memcpy(report.tagId, reportData.tagId, 7);
    memcpy(report.payload, reportData.payload, 32);

    IOBufferMemoryDescriptor* memoryDescriptor = nullptr;
    kern_return_t ret = IOBufferMemoryDescriptor::Create(kIOMemoryDirectionInOut, sizeof(JoyConHIDNFCReport), 0, &memoryDescriptor);

    if (ret == kIOReturnSuccess && memoryDescriptor != nullptr) {
        IOAddressSegment range = {};
        if (memoryDescriptor->GetAddressRange(&range) == kIOReturnSuccess &&
            range.address != 0 &&
            range.length >= sizeof(JoyConHIDNFCReport)) {
            memcpy((void*)range.address, &report, sizeof(JoyConHIDNFCReport));
            memoryDescriptor->SetLength(sizeof(JoyConHIDNFCReport));
            ret = this->handleReport(0, memoryDescriptor, sizeof(JoyConHIDNFCReport), kIOHIDReportTypeInput, 0);
        }
        memoryDescriptor->release();
    }
    
    return ret;
}

// -----------------------------------------------------------------------------
// USER CLIENT
// -----------------------------------------------------------------------------
bool VirtualJoyConUserClient::init() {
    if (!super::init()) {
        return false;
    }
    return true;
}

void VirtualJoyConUserClient::free() {
    super::free();
}

kern_return_t VirtualJoyConUserClient::Start_Impl(IOService * provider) {
    if (!gVirtualJoyConOwner) {
        return kIOReturnBadArgument;
    }
    return super::Start(provider);
}

kern_return_t VirtualJoyConUserClient::Stop_Impl(IOService * provider) {
    return super::Stop(provider);
}

static kern_return_t PostGamepadReport(OSObject * target, void * reference, IOUserClientMethodArguments * arguments) {
    VirtualJoyConUserClient * client = OSDynamicCast(VirtualJoyConUserClient, target);
    if (!client || !arguments || !arguments->structureInput) {
        return kIOReturnBadArgument;
    }

    const void * bytes = arguments->structureInput->getBytesNoCopy(0, sizeof(JoyConReportData));
    if (!bytes) {
        return kIOReturnBadArgument;
    }

    VirtualJoyConDriver * owner = gVirtualJoyConOwner;
    if (!owner) {
        return kIOReturnNotAttached;
    }

    JoyConReportData report = {};
    memcpy(&report, bytes, sizeof(report));
    return owner->dispatchGamepadReport(report);
}

static kern_return_t PostMouseReport(OSObject * target, void * reference, IOUserClientMethodArguments * arguments) {
    VirtualJoyConUserClient * client = OSDynamicCast(VirtualJoyConUserClient, target);
    if (!client || !arguments || !arguments->structureInput) {
        return kIOReturnBadArgument;
    }

    const void * bytes = arguments->structureInput->getBytesNoCopy(0, sizeof(JoyConMouseReportData));
    if (!bytes) {
        return kIOReturnBadArgument;
    }

    VirtualJoyConDriver * owner = gVirtualJoyConOwner;
    if (!owner) {
        return kIOReturnNotAttached;
    }

    JoyConMouseReportData report = {};
    memcpy(&report, bytes, sizeof(report));
    return owner->dispatchMouseReport(report);
}

static kern_return_t PostNFCReport(OSObject * target, void * reference, IOUserClientMethodArguments * arguments) {
    VirtualJoyConUserClient * client = OSDynamicCast(VirtualJoyConUserClient, target);
    if (!client || !arguments || !arguments->structureInput) {
        return kIOReturnBadArgument;
    }

    const void * bytes = arguments->structureInput->getBytesNoCopy(0, sizeof(JoyConNFCReportData));
    if (!bytes) {
        return kIOReturnBadArgument;
    }

    VirtualJoyConDriver * owner = gVirtualJoyConOwner;
    if (!owner) {
        return kIOReturnNotAttached;
    }

    JoyConNFCReportData report = {};
    memcpy(&report, bytes, sizeof(report));
    return owner->dispatchNFCReport(report);
}

kern_return_t VirtualJoyConUserClient::ExternalMethod(
    uint64_t selector,
    IOUserClientMethodArguments * arguments,
    const IOUserClientMethodDispatch * dispatch,
    OSObject * target,
    void * reference) {
    static const IOUserClientMethodDispatch dispatchTable[kVirtualJoyConSelectorCount] = {
        { PostGamepadReport, 0, 0, sizeof(JoyConReportData), 0, 0 },
        { PostMouseReport, 0, 0, sizeof(JoyConMouseReportData), 0, 0 },
        { PostNFCReport, 0, 0, sizeof(JoyConNFCReportData), 0, 0 },
    };

    if (selector >= kVirtualJoyConSelectorCount) {
        return kIOReturnUnsupported;
    }

    return super::ExternalMethod(selector, arguments, &dispatchTable[selector], this, nullptr);
}
