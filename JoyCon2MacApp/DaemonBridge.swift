import Foundation
import Combine
import AppKit
import Darwin

enum MouseMode: Int {
    case off = 0
    case slow = 1
    case normal = 2
    case fast = 3

    var description: String {
        switch self {
        case .off: return "Off"
        case .slow: return "Slow"
        case .normal: return "Normal"
        case .fast: return "Fast"
        }
    }

    var multiplier: Double {
        switch self {
        case .off: return 0.0
        case .slow: return 0.3
        case .normal: return 0.6
        case .fast: return 1.2
        }
    }
}

// Per-controller state object. Views bind only to the controller they care
// about, so a high-frequency update on the left Joy-Con no longer invalidates
// everything listening to DaemonBridge. This is what was freezing the UI.
final class Controller: ObservableObject, Identifiable {
    let id: String
    @Published var side: String
    @Published var name: String
    @Published var macAddress: String
    @Published var isConnected: Bool = false
    @Published var status: String = "scanning"
    @Published var batteryVoltage: Double = 0
    @Published var batteryCurrent: Double = 0
    @Published var batteryTemperature: Double = 0
    @Published var batteryPercentage: Double = -1
    @Published var buttons: UInt32 = 0
    @Published var leftButtons: UInt32 = 0
    @Published var rightButtons: UInt32 = 0
    @Published var leftStickX: Int16 = 0
    @Published var leftStickY: Int16 = 0
    @Published var rightStickX: Int16 = 0
    @Published var rightStickY: Int16 = 0
    @Published var gyroX: Double = 0
    @Published var gyroY: Double = 0
    @Published var gyroZ: Double = 0
    @Published var accelX: Double = 0
    @Published var accelY: Double = 0
    @Published var accelZ: Double = 0
    @Published var mouseX: Int16 = 0
    @Published var mouseY: Int16 = 0
    @Published var mouseDistance: Int16 = 0
    @Published var triggerL: UInt8 = 0
    @Published var triggerR: UInt8 = 0
    @Published var packetCount: UInt32 = 0
    @Published var mouseMode: MouseMode = .off
    @Published var rssi: Int = 0

    // Raw floats for stick visualisation (already deadzoned and clamped by
    // the decoder). Views use these directly instead of re-dividing.
    var leftStickFloatX: Double { Double(leftStickX) / 32767.0 }
    var leftStickFloatY: Double { Double(leftStickY) / 32767.0 }
    var rightStickFloatX: Double { Double(rightStickX) / 32767.0 }
    var rightStickFloatY: Double { Double(rightStickY) / 32767.0 }

    init(side: String) {
        self.id = side
        self.side = side
        self.name = side == "right" ? "Joy-Con R" : "Joy-Con L"
        self.macAddress = side == "right" ? "Right BLE peripheral" : "Left BLE peripheral"
    }
}

struct NFCTag: Identifiable {
    let id = UUID()
    var uid: String
    var type: String
    var data: Data
    var timestamp: Date
}

class DaemonBridge: ObservableObject {
    static let shared = DaemonBridge()

    // List of controllers is @Published only for add/remove; individual
    // per-controller state lives on each Controller object so a 120 Hz
    // packet stream does not invalidate the whole app.
    @Published var controllers: [Controller] = []
    @Published var nfcTags: [NFCTag] = []
    @Published var isDaemonRunning = false

    private var daemonProcess: Process?
    private var daemonApplication: NSRunningApplication?
    private var outputPipe: Pipe?
    private var pendingOutput = ""
    private var lastControllerUpdate: [String: Date] = [:]
    private var shouldRestartAfterTermination = false
    private var logPollTimer: Timer?

    private init() {
        startDaemon()
    }

    deinit {
        stopDaemon()
    }

    func startDaemon() {
        if let daemonProcess, daemonProcess.isRunning {
            isDaemonRunning = true
            return
        }
        if let daemonApplication, !daemonApplication.isTerminated {
            isDaemonRunning = true
            return
        }
        shouldRestartAfterTermination = false
        daemonProcess = nil
        controllers.removeAll()
        lastControllerUpdate.removeAll()

        if startBundledDaemonApp() {
            return
        }

        let process = Process()
        let pipe = Pipe()

        let bundledDaemon = Bundle.main.resourceURL?.appendingPathComponent("joycon2mac")
        let siblingDaemon = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("joycon2mac")
        let devDaemon = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("build/bin/joycon2mac")

        let daemonPath: URL
        if let bundledDaemon = bundledDaemon,
           FileManager.default.isExecutableFile(atPath: bundledDaemon.path) {
            daemonPath = bundledDaemon
        } else if FileManager.default.isExecutableFile(atPath: siblingDaemon.path) {
            daemonPath = siblingDaemon
        } else {
            daemonPath = devDaemon
        }

        process.executableURL = daemonPath
        process.arguments = ["--json"]
        process.standardOutput = pipe
        process.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            guard let output = String(data: data, encoding: .utf8) else {
                return
            }

            DispatchQueue.main.async {
                self?.parseDaemonOutput(output)
            }
        }

        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                let shouldRestart = self?.shouldRestartAfterTermination ?? false
                self?.shouldRestartAfterTermination = false
                self?.daemonProcess = nil
                self?.daemonApplication = nil
                self?.outputPipe = nil
                self?.stopLogPolling()
                self?.isDaemonRunning = false
                self?.lastControllerUpdate.removeAll()
                if shouldRestart {
                    self?.startDaemon()
                } else {
                    self?.markControllersDisconnected(status: "daemonStopped")
                }
            }
        }

        do {
            try process.run()
            daemonProcess = process
            outputPipe = pipe
            isDaemonRunning = true
        } catch {
            TelemetryStore.shared.append("Failed to start daemon: \(error)")
        }
    }

    private func startBundledDaemonApp() -> Bool {
        guard let helperApp = Bundle.main.resourceURL?.appendingPathComponent("JoyCon2MacDaemon.app"),
              FileManager.default.fileExists(atPath: helperApp.path) else {
            return false
        }

        do {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: "local.joycon2mac.daemon") {
                Darwin.kill(app.processIdentifier, SIGKILL)
            }

            let supportDir = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("JoyCon2Mac", isDirectory: true)
            try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
            let logPath = supportDir.appendingPathComponent("daemon.jsonl")
            try Data().write(to: logPath, options: .atomic)
            TelemetryStore.shared.setLogPath(logPath)
            daemonLogPath = logPath
            daemonLogOffset = 0
            controllers.removeAll()
            lastControllerUpdate.removeAll()

            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.createsNewApplicationInstance = true
            configuration.arguments = ["--json", "--json-file", logPath.path]

            isDaemonRunning = true
            startLogPolling()

            NSWorkspace.shared.openApplication(at: helperApp, configuration: configuration) { [weak self] app, error in
                DispatchQueue.main.async {
                    if let error {
                        TelemetryStore.shared.append("Failed to start helper daemon: \(error)")
                        self?.isDaemonRunning = false
                        self?.stopLogPolling()
                        self?.markControllersDisconnected(status: "daemonStopped")
                        return
                    }
                    self?.daemonApplication = app
                }
            }
            return true
        } catch {
            TelemetryStore.shared.append("Failed to prepare daemon log: \(error)")
            return false
        }
    }

    func stopDaemon() {
        isDaemonRunning = false
        outputPipe?.fileHandleForReading.readabilityHandler = nil

        if let daemonApplication {
            let pid = daemonApplication.processIdentifier
            Darwin.kill(pid, SIGTERM)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if Darwin.kill(pid, 0) == 0 {
                    Darwin.kill(pid, SIGKILL)
                }
            }
            self.daemonApplication = nil
            stopLogPolling()
            markControllersDisconnected(status: "daemonStopped")
            lastControllerUpdate.removeAll()
            return
        }

        guard let process = daemonProcess else {
            outputPipe = nil
            stopLogPolling()
            markControllersDisconnected(status: "daemonStopped")
            lastControllerUpdate.removeAll()
            return
        }

        if process.isRunning {
            process.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2.0) { [weak process] in
                if let process, process.isRunning {
                    process.interrupt()
                }
            }
        }
    }

    func restartDaemon() {
        if daemonApplication != nil {
            shouldRestartAfterTermination = true
            stopDaemon()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                if self?.shouldRestartAfterTermination == true {
                    self?.shouldRestartAfterTermination = false
                    self?.startDaemon()
                }
            }
        } else if let process = daemonProcess, process.isRunning {
            shouldRestartAfterTermination = true
            stopDaemon()
        } else {
            startDaemon()
        }
    }

    // MARK: - Daemon log tailing (helper app writes JSON Lines to disk)

    private var daemonLogPath: URL?
    private var daemonLogOffset: UInt64 = 0

    private func startLogPolling() {
        logPollTimer?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.pollDaemonLog()
        }
        logPollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopLogPolling() {
        logPollTimer?.invalidate()
        logPollTimer = nil
    }

    private func pollDaemonLog() {
        if let daemonApplication, daemonApplication.isTerminated {
            handleDaemonTerminated()
            return
        }

        guard let daemonLogPath else { return }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: daemonLogPath.path),
              let fileSize = attributes[.size] as? UInt64 else {
            return
        }
        if fileSize < daemonLogOffset {
            daemonLogOffset = 0
        }
        guard fileSize > daemonLogOffset,
              let handle = try? FileHandle(forReadingFrom: daemonLogPath) else {
            return
        }
        do {
            try handle.seek(toOffset: daemonLogOffset)
            let data = handle.readDataToEndOfFile()
            daemonLogOffset = try handle.offset()
            try handle.close()
            if let output = String(data: data, encoding: .utf8), !output.isEmpty {
                parseDaemonOutput(output)
            }
        } catch {
            try? handle.close()
        }
    }

    func toggleMouseMode() {
        if let controller = controllers.first {
            let nextRaw = (controller.mouseMode.rawValue + 1) % 4
            controller.mouseMode = MouseMode(rawValue: nextRaw) ?? .off
        }
    }

    func scanNFC() {
        TelemetryStore.shared.append("NFC scan requested. Waiting for daemon NFC tag reports.")
    }

    var telemetryLogPath: String {
        TelemetryStore.shared.telemetryLogPath
    }

    func revealTelemetryLog() {
        TelemetryStore.shared.revealLog()
    }

    func copyTelemetryToClipboard() {
        TelemetryStore.shared.copyToClipboard()
    }

    func clearTelemetryView() {
        TelemetryStore.shared.clear()
    }

    func installAndLoadDriver() {
        let embeddedDextURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents")
            .appendingPathComponent("Library")
            .appendingPathComponent("SystemExtensions")
            .appendingPathComponent("VirtualJoyConDriver.dext")

        guard FileManager.default.fileExists(atPath: embeddedDextURL.path) else {
            let msg = "Driver extension is missing from Contents/Library/SystemExtensions."
            TelemetryStore.shared.updateDriverStatus(msg)
            TelemetryStore.shared.append(msg)
            return
        }

        TelemetryStore.shared.updateDriverStatus("Submitting driver activation request...")
        TelemetryStore.shared.append("Activating DriverKit extension from \(embeddedDextURL.path)")

        DriverExtensionInstaller.shared.activate { [weak self] status, shouldRestartDaemon in
            DispatchQueue.main.async {
                TelemetryStore.shared.updateDriverStatus(status)
                TelemetryStore.shared.append("[driver] \(status)")
                if shouldRestartDaemon {
                    self?.restartDaemon()
                }
            }
        }
    }

    // MARK: - Output parsing

    private func parseDaemonOutput(_ output: String) {
        pendingOutput += output

        while let newlineRange = pendingOutput.range(of: "\n") {
            let line = String(pendingOutput[..<newlineRange.lowerBound])
            pendingOutput.removeSubrange(...newlineRange.lowerBound)
            parseDaemonLine(line.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private func parseDaemonLine(_ line: String) {
        guard line.hasPrefix("{"), let data = line.data(using: .utf8) else {
            TelemetryStore.shared.append(line)
            return
        }

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = object["event"] as? String else {
            TelemetryStore.shared.append(line)
            return
        }

        switch event {
        case "daemon":
            updateDaemonStatus(from: object)
        case "telemetry":
            appendTelemetry(from: object)
        case "controller":
            updateControllerStatus(from: object)
        case "state":
            updateController(from: object)
        case "nfc":
            appendNFCTag(from: object)
        default:
            return
        }
    }

    private func markControllersDisconnected(status: String) {
        for controller in controllers {
            controller.isConnected = false
            controller.status = status
        }
    }

    private func handleDaemonTerminated() {
        daemonApplication = nil
        daemonProcess = nil
        outputPipe = nil
        stopLogPolling()
        isDaemonRunning = false
        lastControllerUpdate.removeAll()
        TelemetryStore.shared.append("[daemon] helper process terminated")
        if shouldRestartAfterTermination {
            shouldRestartAfterTermination = false
            startDaemon()
        } else {
            markControllersDisconnected(status: "daemonStopped")
        }
    }

    private func updateDaemonStatus(from object: [String: Any]) {
        let status = stringValue(object["status"], default: "unknown")
        let detail = stringValue(object["detail"], default: "")
        TelemetryStore.shared.append("[daemon] \(status)\(detail.isEmpty ? "" : " - \(detail)")")
        if status == "started" {
            isDaemonRunning = true
        } else if status == "exiting" {
            isDaemonRunning = false
        }
    }

    private func appendTelemetry(from object: [String: Any]) {
        let side = stringValue(object["side"], default: "left")
        let phase = stringValue(object["phase"], default: "unknown")
        let detail = stringValue(object["detail"], default: "")
        let name = stringValue(object["name"], default: "")
        let line = "[\(side)] \(phase)\(name.isEmpty ? "" : " \(name)")\(detail.isEmpty ? "" : " - \(detail)")"
        TelemetryStore.shared.append(line)
    }

    private func statusRank(_ status: String) -> Int {
        switch status {
        case "daemonStopped": return -1
        case "scanning": return 0
        case "queued": return 1
        case "connecting": return 2
        case "bleConnected": return 3
        case "servicesReady": return 4
        case "initializing": return 5
        case "commandTimeout", "writeFailed": return 6
        case "streaming": return 7
        case "ready": return 8
        case "connectFailed", "disconnected": return 100
        default: return 0
        }
    }

    private func shouldReplaceStatus(current: String, incoming: String) -> Bool {
        if ["connectFailed", "disconnected", "daemonStopped"].contains(incoming) {
            return true
        }
        if current == "daemonStopped" {
            return true
        }
        return statusRank(incoming) >= statusRank(current)
    }

    private func getOrCreateController(side: String) -> Controller {
        if let existing = controllers.first(where: { $0.id == side }) {
            return existing
        }
        let controller = Controller(side: side)
        controllers.append(controller)
        controllers.sort { $0.id < $1.id }
        return controller
    }

    private func updateController(from object: [String: Any]) {
        let side = stringValue(object["side"], default: "left")
        let normalizedSide = side == "right" ? "right" : "left"
        let now = Date()
        if let lastUpdate = lastControllerUpdate[normalizedSide],
           now.timeIntervalSince(lastUpdate) < 0.033 {
            // ~30 fps cap, per-side. Enough to feel live but light on SwiftUI.
            return
        }
        lastControllerUpdate[normalizedSide] = now
        let controller = getOrCreateController(side: normalizedSide)
        // Upgrade the status to streaming/ready if state packets are flowing.
        if controller.status != "ready" {
            controller.status = "streaming"
        }
        controller.isConnected = true
        controller.batteryVoltage = doubleValue(object["batteryVoltage"])
        controller.batteryCurrent = doubleValue(object["batteryCurrent"])
        controller.batteryTemperature = doubleValue(object["batteryTemperature"])
        controller.batteryPercentage = doubleValue(object["batteryPercentage"], default: -1)
        controller.buttons = uint32Value(object["buttons"])
        controller.leftButtons = uint32Value(object["leftButtons"])
        controller.rightButtons = uint32Value(object["rightButtons"])
        controller.leftStickX = int16Value(object["leftStickX"])
        controller.leftStickY = int16Value(object["leftStickY"])
        controller.rightStickX = int16Value(object["rightStickX"])
        controller.rightStickY = int16Value(object["rightStickY"])
        controller.gyroX = doubleValue(object["gyroX"])
        controller.gyroY = doubleValue(object["gyroY"])
        controller.gyroZ = doubleValue(object["gyroZ"])
        controller.accelX = doubleValue(object["accelX"])
        controller.accelY = doubleValue(object["accelY"])
        controller.accelZ = doubleValue(object["accelZ"])
        controller.mouseX = int16Value(object["mouseX"])
        controller.mouseY = int16Value(object["mouseY"])
        controller.mouseDistance = int16Value(object["mouseDistance"])
        controller.triggerL = uint8Value(object["triggerL"])
        controller.triggerR = uint8Value(object["triggerR"])
        controller.packetCount = uint32Value(object["packetCount"])
        controller.mouseMode = MouseMode(rawValue: intValue(object["mouseMode"])) ?? .off
        controller.rssi = intValue(object["rssi"], default: 0)
    }

    private func updateControllerStatus(from object: [String: Any]) {
        let side = stringValue(object["side"], default: "left")
        let normalizedSide = side == "right" ? "right" : "left"
        let rawStatus = stringValue(object["status"], default: "scanning")
        let message = stringValue(object["message"], default: "")
        let connectedStatuses = ["bleConnected", "servicesReady", "initializing", "ready", "streaming", "commandTimeout"]
        let isConnected = connectedStatuses.contains(rawStatus)

        let controller = getOrCreateController(side: normalizedSide)
        controller.isConnected = isConnected
        if shouldReplaceStatus(current: controller.status, incoming: rawStatus) {
            controller.status = rawStatus
        }
        if !message.isEmpty {
            controller.macAddress = message
        }
    }

    private func appendNFCTag(from object: [String: Any]) {
        guard let uid = object["uid"] as? String else {
            return
        }

        let payloadHex = object["payload"] as? String ?? ""
        nfcTags.insert(
            NFCTag(
                uid: uid,
                type: object["type"] as? String ?? "Vendor",
                data: Data(payloadHex.utf8),
                timestamp: Date()
            ),
            at: 0
        )
    }

    private func stringValue(_ value: Any?, default defaultValue: String) -> String {
        value as? String ?? defaultValue
    }

    private func intValue(_ value: Any?, default defaultValue: Int = 0) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) ?? defaultValue }
        return defaultValue
    }

    private func uint32Value(_ value: Any?) -> UInt32 {
        UInt32(max(0, intValue(value)))
    }

    private func uint8Value(_ value: Any?) -> UInt8 {
        UInt8(max(0, min(255, intValue(value))))
    }

    private func int16Value(_ value: Any?) -> Int16 {
        Int16(max(Int(Int16.min), min(Int(Int16.max), intValue(value))))
    }

    private func doubleValue(_ value: Any?, default defaultValue: Double = 0) -> Double {
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) ?? defaultValue }
        return defaultValue
    }
}
