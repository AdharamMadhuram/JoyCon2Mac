import Foundation
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
}
