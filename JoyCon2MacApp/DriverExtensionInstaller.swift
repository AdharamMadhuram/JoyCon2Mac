import Foundation
import IOKit
import SystemExtensions

final class DriverExtensionInstaller: NSObject, OSSystemExtensionRequestDelegate {
    static let shared = DriverExtensionInstaller()

    private let driverIdentifier = "local.joycon2mac.driver"
    private var currentRequest: OSSystemExtensionRequest?
    private var statusHandler: ((String, Bool) -> Void)?

    private override init() {
        super.init()
    }

    func activate(status: @escaping (String, Bool) -> Void) {
        statusHandler = status

        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: driverIdentifier,
            queue: .main
        )
        request.delegate = self
        currentRequest = request

        status("Submitting SystemExtensions activation request for \(driverIdentifier)...", false)
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func request(_ request: OSSystemExtensionRequest,
                 didFinishWithResult result: OSSystemExtensionRequest.Result) {
        let detail: String
        switch result {
        case .completed:
            detail = "Driver extension activated."
        case .willCompleteAfterReboot:
            detail = "Driver extension accepted; macOS says a reboot is required before it becomes active."
        @unknown default:
            detail = "Driver extension activation finished with result \(result.rawValue)."
        }
        statusHandler?(detail, result == .completed)
        currentRequest = nil
    }

    func request(_ request: OSSystemExtensionRequest,
                 didFailWithError error: Error) {
        // The SystemExtensions framework returns .extensionNotFound (error 4)
        // in several benign situations — most commonly when the app was
        // relaunched while a prior version of the dext is still in the
        // "terminating for upgrade" transition, or when the activation
        // request raced an already-live driver. If the driver is in fact
        // registered and matched in IOKit right now, treat the request as
        // a no-op success instead of surfacing a scary error banner.
        //
        // We intentionally only apply this fallback on the specific error
        // codes that SystemExtensions is known to emit for "already
        // staged / replaced": .extensionNotFound (4) and .requestCanceled
        // (8, fires when our own replace action supersedes a previous
        // activation). For every other error we keep the original
        // behaviour — the user really does need to know if signing,
        // approval, or platform policy blocked the install.
        let nsError = error as NSError
        let isBenign = nsError.domain == "OSSystemExtensionErrorDomain"
            && (nsError.code == OSSystemExtensionError.extensionNotFound.rawValue
                || nsError.code == OSSystemExtensionError.requestCanceled.rawValue)

        if isBenign, isDriverAlreadyLive() {
            statusHandler?("Driver extension activated.", true)
            currentRequest = nil
            return
        }

        statusHandler?("Driver extension activation failed: \(error.localizedDescription)", false)
        currentRequest = nil
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        statusHandler?("Driver extension is waiting for approval in System Settings.", false)
    }

    func request(_ request: OSSystemExtensionRequest,
                 actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        statusHandler?("Replacing existing DriverKit extension with the bundled build...", false)
        return .replace
    }

    // MARK: - IOKit probe
    //
    // Mirrors DriverKitClient's lookup: the dext publishes IOUserService with
    // IOUserClass=VirtualJoyConDriver, IOUserServerName=<bundle id>. If the
    // matching service exists in IOKit right now, the driver is loaded and
    // usable regardless of what the SystemExtensions request delegate reports.
    private func isDriverAlreadyLive() -> Bool {
        // IOServiceMatching on "VirtualJoyConDriver" gives us the specific
        // class, then we cross-check CFBundleIdentifier / IOUserServerName to
        // guard against unrelated services that happened to share the name.
        guard let matching = IOServiceMatching("VirtualJoyConDriver") else {
            return false
        }
        var iterator: io_iterator_t = 0
        let kr = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard kr == KERN_SUCCESS, iterator != 0 else {
            return false
        }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            if isOurDriverService(service) {
                return true
            }
        }
        return false
    }

    private func isOurDriverService(_ service: io_service_t) -> Bool {
        return servicePropertyEquals(service, key: "CFBundleIdentifier", expected: driverIdentifier)
            && servicePropertyEquals(service, key: "IOUserServerName", expected: driverIdentifier)
    }

    private func servicePropertyEquals(_ service: io_service_t,
                                       key: String,
                                       expected: String) -> Bool {
        guard let raw = IORegistryEntryCreateCFProperty(service,
                                                        key as CFString,
                                                        kCFAllocatorDefault,
                                                        0) else {
            return false
        }
        let value = raw.takeRetainedValue()
        guard let str = value as? String else { return false }
        return str == expected
    }
}
