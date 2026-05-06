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

// ---------------------------------------------------------------------------
// Packed wire formats for the three HID report types.
//
// reportId = 1 : composite gamepad (buttons + dpad hat + two sticks + triggers)
// reportId = 2 : mouse (buttons, dx, dy, wheel)
// reportId = 3 : vendor-defined NFC blob
// Byte layouts MUST match the descriptor byte-for-byte or macOS rejects the
// reports silently. See VirtualCompositeDescriptor below for the authoritative
// descriptor.
// ---------------------------------------------------------------------------
struct JoyConHIDGamepadReport {
    uint8_t  reportId;
    uint32_t buttons;
    uint8_t  dpad;      // 4-bit hat switch, upper 4 bits padding
    int16_t  x;         // left stick X
    int16_t  y;         // left stick Y
    int16_t  z;         // right stick X
    int16_t  rz;        // right stick Y
    uint8_t  l2;        // left analog trigger
    uint8_t  r2;        // right analog trigger
} __attribute__((packed));

struct JoyConHIDMouseReport {
    uint8_t reportId;   // 2
    uint8_t buttons;    // bits 0/1/2 = left/right/middle
    int16_t x;
    int16_t y;
    int8_t  wheel;
} __attribute__((packed));

struct JoyConHIDNFCReport {
    uint8_t reportId;   // 3
    uint8_t status;
    uint8_t tagId[7];
    uint8_t payload[32];
} __attribute__((packed));

enum : uint64_t {
    kVirtualJoyConSelectorGamepad = 0,
    kVirtualJoyConSelectorMouse   = 1,
    kVirtualJoyConSelectorNFC     = 2,
    kVirtualJoyConSelectorCount   = 3
};

// Bridging singleton between the UserClient (which receives report data from
// the daemon) and the live HID device (which owns the IOHIDDevice nub). Set
// by VirtualJoyConHIDDevice::Start and cleared in Stop, so the UserClient
// always dispatches to the most recent device. The alternative — storing a
// pointer inside the UserClient instance — falls over during re-pair/relaunch
// because the DEXT framework tears down and recreates the HID device without
// recreating the UserClient.
static VirtualJoyConHIDDevice * gLiveHIDDevice = nullptr;

// ---------------------------------------------------------------------------
// Composite HID descriptor: gamepad (ID 1) + mouse (ID 2) + NFC vendor (ID 3)
// ---------------------------------------------------------------------------
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

    // Analog Triggers (Rx, Ry -> L2/R2) - 8 bit
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

    // Mouse Buttons (3)
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

    // Mouse Wheel
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

// ===========================================================================
// VirtualJoyConDriver — root service matching on IOUserResources
// ===========================================================================

bool VirtualJoyConDriver::init() {
    return super::init();
}

void VirtualJoyConDriver::free() {
    super::free();
}

kern_return_t VirtualJoyConDriver::Start_Impl(IOService * provider) {
    os_log(OS_LOG_DEFAULT, "VirtualJoyConDriver::Start enter");

    // SUPERDISPATCH bypasses the IIG RPC table so the call resolves to the
    // actual base-class Start instead of looping back through our own
    // override. Without it we got EXC_BAD_ACCESS / SIGBUS from stack
    // overflow — the dext crashed before RegisterService ran. Karabiner's
    // IMPL(...) macro expands to the same SUPERDISPATCH pattern.
    kern_return_t ret = Start(provider, SUPERDISPATCH);
    if (ret != kIOReturnSuccess) {
        os_log(OS_LOG_DEFAULT, "VirtualJoyConDriver::super::Start failed 0x%x", ret);
        return ret;
    }

    ret = RegisterService();
    os_log(OS_LOG_DEFAULT, "VirtualJoyConDriver::RegisterService returned 0x%x", ret);
    if (ret != kIOReturnSuccess) {
        return ret;
    }
    os_log(OS_LOG_DEFAULT, "VirtualJoyConDriver::Start success, waiting for UserClient");
    return kIOReturnSuccess;
}

kern_return_t VirtualJoyConDriver::Stop_Impl(IOService * provider) {
    os_log(OS_LOG_DEFAULT, "VirtualJoyConDriver::Stop");
    return Stop(provider, SUPERDISPATCH);
}

kern_return_t VirtualJoyConDriver::NewUserClient_Impl(uint32_t type, IOUserClient ** userClient) {
    if (!userClient) {
        return kIOReturnBadArgument;
    }

    // The Info.plist defines a UserClientProperties child personality with
    // IOUserClass=VirtualJoyConUserClient; Create() looks that up and
    // instantiates the right class on our behalf.
    IOService * service = nullptr;
    kern_return_t ret = Create(this, "UserClientProperties", &service);
    if (ret != kIOReturnSuccess) {
        os_log(OS_LOG_DEFAULT, "VirtualJoyConDriver::Create UserClient failed 0x%x", ret);
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

// ===========================================================================
// VirtualJoyConHIDDevice — the actual HID device published to the system
// ===========================================================================

bool VirtualJoyConHIDDevice::init() {
    return super::init();
}

void VirtualJoyConHIDDevice::free() {
    super::free();
}

kern_return_t VirtualJoyConHIDDevice::Start_Impl(IOService * provider) {
    os_log(OS_LOG_DEFAULT, "VirtualJoyConHIDDevice::Start");

    kern_return_t ret = Start(provider, SUPERDISPATCH);
    if (ret != kIOReturnSuccess) {
        os_log(OS_LOG_DEFAULT, "VirtualJoyConHIDDevice::super::Start failed 0x%x", ret);
        return ret;
    }

    // Publish as an HID device. AppleUserHIDDevice (the kernel half) calls
    // into our newDeviceDescription() / newReportDescriptor() from here, so
    // by the time RegisterService returns we have a live /dev/input entry.
    ret = RegisterService();
    if (ret != kIOReturnSuccess) {
        os_log(OS_LOG_DEFAULT, "VirtualJoyConHIDDevice::RegisterService failed 0x%x", ret);
        return ret;
    }

    // Expose ourselves so the UserClient can route reports through us. No
    // retain needed — the UserClient holds a reference to the provider
    // chain that keeps us alive while it's open.
    gLiveHIDDevice = this;
    os_log(OS_LOG_DEFAULT, "VirtualJoyConHIDDevice ready");
    return kIOReturnSuccess;
}

kern_return_t VirtualJoyConHIDDevice::Stop_Impl(IOService * provider) {
    os_log(OS_LOG_DEFAULT, "VirtualJoyConHIDDevice::Stop");
    if (gLiveHIDDevice == this) {
        gLiveHIDDevice = nullptr;
    }
    return Stop(provider, SUPERDISPATCH);
}

OSData * VirtualJoyConHIDDevice::newReportDescriptor() {
    return OSData::withBytes(VirtualCompositeDescriptor, sizeof(VirtualCompositeDescriptor));
}

OSDictionary * VirtualJoyConHIDDevice::newDeviceDescription() {
    OSDictionary * description = OSDictionary::withCapacity(8);
    if (!description) {
        return nullptr;
    }

    OSNumber * vendor       = OSNumber::withNumber(static_cast<uint32_t>(0x057E), 32); // Nintendo
    OSNumber * product      = OSNumber::withNumber(static_cast<uint32_t>(0x2066), 32); // Joy-Con 2 pair (custom)
    OSNumber * version      = OSNumber::withNumber(static_cast<uint32_t>(1), 32);
    OSString * transport    = OSString::withCString("Virtual");
    OSString * manufacturer = OSString::withCString("JoyCon2Mac");
    OSString * productName  = OSString::withCString("Joy-Con 2 (Virtual)");

    if (vendor)       { description->setObject(kIOHIDVendorIDKey,       vendor);       vendor->release(); }
    if (product)      { description->setObject(kIOHIDProductIDKey,      product);      product->release(); }
    if (version)      { description->setObject(kIOHIDVersionNumberKey,  version);      version->release(); }
    if (transport)    { description->setObject(kIOHIDTransportKey,      transport);    transport->release(); }
    if (manufacturer) { description->setObject(kIOHIDManufacturerKey,   manufacturer); manufacturer->release(); }
    if (productName)  { description->setObject(kIOHIDProductKey,        productName);  productName->release(); }

    return description;
}

kern_return_t VirtualJoyConHIDDevice::setReport(IOMemoryDescriptor * report, IOHIDReportType reportType, IOOptionBits options, uint32_t completionTimeout, OSAction * action) {
    return kIOReturnUnsupported;
}

kern_return_t VirtualJoyConHIDDevice::getReport(IOMemoryDescriptor * report, IOHIDReportType reportType, IOOptionBits options, uint32_t completionTimeout, OSAction * action) {
    return kIOReturnUnsupported;
}

kern_return_t VirtualJoyConHIDDevice::dispatchGamepadReport(JoyConReportData reportData) {
    JoyConHIDGamepadReport report = {};
    report.reportId = 1;
    report.buttons  = reportData.buttons & 0x3FFFF; // 18 bits max
    report.dpad     = reportData.dpad;
    report.x        = reportData.stickLX;
    report.y        = reportData.stickLY;
    report.z        = reportData.stickRX;
    report.rz       = reportData.stickRY;
    report.l2       = reportData.triggerL;
    report.r2       = reportData.triggerR;

    IOBufferMemoryDescriptor * md = nullptr;
    kern_return_t ret = IOBufferMemoryDescriptor::Create(kIOMemoryDirectionInOut, sizeof(report), 0, &md);
    if (ret == kIOReturnSuccess && md != nullptr) {
        IOAddressSegment range = {};
        if (md->GetAddressRange(&range) == kIOReturnSuccess &&
            range.address != 0 && range.length >= sizeof(report)) {
            memcpy((void *)range.address, &report, sizeof(report));
            md->SetLength(sizeof(report));
            ret = handleReport(0, md, sizeof(report), kIOHIDReportTypeInput, 0);
        }
        md->release();
    }
    return ret;
}

kern_return_t VirtualJoyConHIDDevice::dispatchMouseReport(JoyConMouseReportData reportData) {
    JoyConHIDMouseReport report = {};
    report.reportId = 2;
    report.buttons  = reportData.buttons;
    report.x        = reportData.deltaX;
    report.y        = reportData.deltaY;
    report.wheel    = reportData.scroll;

    IOBufferMemoryDescriptor * md = nullptr;
    kern_return_t ret = IOBufferMemoryDescriptor::Create(kIOMemoryDirectionInOut, sizeof(report), 0, &md);
    if (ret == kIOReturnSuccess && md != nullptr) {
        IOAddressSegment range = {};
        if (md->GetAddressRange(&range) == kIOReturnSuccess &&
            range.address != 0 && range.length >= sizeof(report)) {
            memcpy((void *)range.address, &report, sizeof(report));
            md->SetLength(sizeof(report));
            ret = handleReport(0, md, sizeof(report), kIOHIDReportTypeInput, 0);
        }
        md->release();
    }
    return ret;
}

kern_return_t VirtualJoyConHIDDevice::dispatchNFCReport(JoyConNFCReportData reportData) {
    JoyConHIDNFCReport report = {};
    report.reportId = 3;
    report.status   = reportData.status;
    memcpy(report.tagId,   reportData.tagId,   7);
    memcpy(report.payload, reportData.payload, 32);

    IOBufferMemoryDescriptor * md = nullptr;
    kern_return_t ret = IOBufferMemoryDescriptor::Create(kIOMemoryDirectionInOut, sizeof(report), 0, &md);
    if (ret == kIOReturnSuccess && md != nullptr) {
        IOAddressSegment range = {};
        if (md->GetAddressRange(&range) == kIOReturnSuccess &&
            range.address != 0 && range.length >= sizeof(report)) {
            memcpy((void *)range.address, &report, sizeof(report));
            md->SetLength(sizeof(report));
            ret = handleReport(0, md, sizeof(report), kIOHIDReportTypeInput, 0);
        }
        md->release();
    }
    return ret;
}

// ===========================================================================
// VirtualJoyConUserClient — bridges the daemon to the HID device
// ===========================================================================
//
// Lazily creates the VirtualJoyConHIDDevice on first use instead of at Start.
// That way a user just running the app without pairing doesn't cause an
// empty virtual gamepad to show up in every game's controller picker.

bool VirtualJoyConUserClient::init() {
    return super::init();
}

void VirtualJoyConUserClient::free() {
    super::free();
}

kern_return_t VirtualJoyConUserClient::Start_Impl(IOService * provider) {
    os_log(OS_LOG_DEFAULT, "VirtualJoyConUserClient::Start");
    return Start(provider, SUPERDISPATCH);
}

kern_return_t VirtualJoyConUserClient::Stop_Impl(IOService * provider) {
    return Stop(provider, SUPERDISPATCH);
}

// Helper: ensure the HID device exists, lazy-creating it on first call. This
// is the Karabiner pattern: the UserClient owns instantiation of the HID
// subdevice so the root service stays passive. Safe to call repeatedly —
// subsequent calls short-circuit on the gLiveHIDDevice bridging pointer.
static kern_return_t ensureHIDDevice(VirtualJoyConUserClient * self) {
    if (gLiveHIDDevice != nullptr) {
        return kIOReturnSuccess;
    }
    if (!self) {
        return kIOReturnBadArgument;
    }

    IOService * created = nullptr;
    kern_return_t kr = self->Create(self, "HIDDeviceProperties", &created);
    if (kr != kIOReturnSuccess) {
        os_log(OS_LOG_DEFAULT,
               "VirtualJoyConUserClient: Create(HIDDeviceProperties) failed 0x%x", kr);
        return kr;
    }
    // Ownership now lives in the IORegistry via the parent chain. The
    // HIDDevice sets gLiveHIDDevice from its own Start, so we don't need
    // to cast here — just release our extra reference. Mirrors Karabiner's
    // VirtualHIDDeviceUserClient creation path.
    VirtualJoyConHIDDevice * dev = OSDynamicCast(VirtualJoyConHIDDevice, created);
    if (!dev) {
        os_log(OS_LOG_DEFAULT,
               "VirtualJoyConUserClient: HID device class mismatch after Create");
        if (created) created->release();
        return kIOReturnUnsupported;
    }
    // Release our transient reference — the framework keeps the device alive.
    dev->release();
    return kIOReturnSuccess;
}

static kern_return_t PostGamepadReport(OSObject * target, void * reference, IOUserClientMethodArguments * arguments) {
    VirtualJoyConUserClient * client = OSDynamicCast(VirtualJoyConUserClient, target);
    if (!client || !arguments || !arguments->structureInput) {
        return kIOReturnBadArgument;
    }
    kern_return_t kr = ensureHIDDevice(client);
    if (kr != kIOReturnSuccess) {
        return kr;
    }
    VirtualJoyConHIDDevice * device = gLiveHIDDevice;
    if (!device) {
        return kIOReturnNotAttached;
    }
    const void * bytes = arguments->structureInput->getBytesNoCopy(0, sizeof(JoyConReportData));
    if (!bytes) {
        return kIOReturnBadArgument;
    }
    JoyConReportData report = {};
    memcpy(&report, bytes, sizeof(report));
    return device->dispatchGamepadReport(report);
}

static kern_return_t PostMouseReport(OSObject * target, void * reference, IOUserClientMethodArguments * arguments) {
    VirtualJoyConUserClient * client = OSDynamicCast(VirtualJoyConUserClient, target);
    if (!client || !arguments || !arguments->structureInput) {
        return kIOReturnBadArgument;
    }
    kern_return_t kr = ensureHIDDevice(client);
    if (kr != kIOReturnSuccess) {
        return kr;
    }
    VirtualJoyConHIDDevice * device = gLiveHIDDevice;
    if (!device) {
        return kIOReturnNotAttached;
    }
    const void * bytes = arguments->structureInput->getBytesNoCopy(0, sizeof(JoyConMouseReportData));
    if (!bytes) {
        return kIOReturnBadArgument;
    }
    JoyConMouseReportData report = {};
    memcpy(&report, bytes, sizeof(report));
    return device->dispatchMouseReport(report);
}

static kern_return_t PostNFCReport(OSObject * target, void * reference, IOUserClientMethodArguments * arguments) {
    VirtualJoyConUserClient * client = OSDynamicCast(VirtualJoyConUserClient, target);
    if (!client || !arguments || !arguments->structureInput) {
        return kIOReturnBadArgument;
    }
    kern_return_t kr = ensureHIDDevice(client);
    if (kr != kIOReturnSuccess) {
        return kr;
    }
    VirtualJoyConHIDDevice * device = gLiveHIDDevice;
    if (!device) {
        return kIOReturnNotAttached;
    }
    const void * bytes = arguments->structureInput->getBytesNoCopy(0, sizeof(JoyConNFCReportData));
    if (!bytes) {
        return kIOReturnBadArgument;
    }
    JoyConNFCReportData report = {};
    memcpy(&report, bytes, sizeof(report));
    return device->dispatchNFCReport(report);
}

kern_return_t VirtualJoyConUserClient::ExternalMethod(
    uint64_t selector,
    IOUserClientMethodArguments * arguments,
    const IOUserClientMethodDispatch * dispatch,
    OSObject * target,
    void * reference) {
    static const IOUserClientMethodDispatch dispatchTable[kVirtualJoyConSelectorCount] = {
        { PostGamepadReport, 0, 0, sizeof(JoyConReportData),      0, 0 },
        { PostMouseReport,   0, 0, sizeof(JoyConMouseReportData), 0, 0 },
        { PostNFCReport,     0, 0, sizeof(JoyConNFCReportData),   0, 0 },
    };

    if (selector >= kVirtualJoyConSelectorCount) {
        return kIOReturnUnsupported;
    }
    return super::ExternalMethod(selector, arguments, &dispatchTable[selector], this, nullptr);
}
