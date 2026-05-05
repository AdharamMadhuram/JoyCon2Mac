import Foundation
import Combine
import AppKit
import Darwin

struct ControllerState: Identifiable {
    let id: String
    var side: String
    var name: String
    var macAddress: String
    var isConnected: Bool
    var status: String
    var batteryVoltage: Double
    var batteryCurrent: Double
    var batteryTemperature: Double
    var batteryPercentage: Double
    var buttons: UInt32
    var leftButtons: UInt32
    var rightButtons: UInt32
    var leftStickX: Int16
    var leftStickY: Int16
    var rightStickX: Int16
    var rightStickY: Int16
    var gyroX: Double
    var gyroY: Double
    var gyroZ: Double
    var accelX: Double
    var accelY: Double
    var accelZ: Double
    var mouseX: Int16
    var mouseY: Int16
    var mouseDistance: Int16
    var triggerL: UInt8
    var triggerR: UInt8
    var packetCount: UInt32
    var mouseMode: MouseMode
    var rssi: Int
}

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

struct NFCTag: Identifiable {
    let id = UUID()
    var uid: String
    var type: String
    var data: Data
    var timestamp: Date
}

// DaemonBridge owns two kinds of state:
//  1. Hot state (controllers, NFC tags) – published, but mutated at most
//     15 Hz per controller so SwiftUI stays responsive.
//  2. Log/telemetry noise – NOT published here. Lives on TelemetryStore so
//     the 100+ lines/sec firehose cannot invalidate controller views.
class DaemonBridge: ObservableObject {
    static let shared = DaemonBridge()

    @Published var controllers: [ControllerState] = []
    @Published var nfcTags: [NFCTag] = []
    @Published var isDaemonRunning = false
    // Kept for source-compat with existing views. These strings are NOT mutated
    // from the packet firehose anymore; they are updated only on state
    // transitions (daemon start/stop, driver install result).
    @Published var daemonOutput: String = ""
    @Published var telemetryLines: [String] = []
    @Published var driverInstallStatus: String = ""
    @Published var stateRevision: UInt64 = 0

    private var daemonProcess: Process?
    private var daemonApplication: NSRunningApplication?
    private var outputPipe: Pipe?
    private var pendingOutput = ""
    // Per-controller rate limiter. 15 Hz is plenty for a live UI and a lot
    // gentler on SwiftUI than the ~120 Hz the daemon actually publishes.
    private var lastControllerUpdate: [String: Date] = [:]
    private let controllerUpdateInterval: TimeInterval = 1.0 / 15.0
    private var shouldRestartAfterTermination = false
    private var logPollTimer: Timer?
    private var daemonLogPath: URL?
    private var daemonLogOffset: UInt64 = 0

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
            daemonLogPath = logPath
            daemonLogOffset = 0
            TelemetryStore.shared.setLogPath(logPath)
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
            let newMode = MouseMode(rawValue: nextRaw) ?? .off
            var updated = controllers
            updated[0].mouseMode = newMode
            controllers = updated
            bumpStateRevision()
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
        // Kept-for-compat fields — also flush to keep any legacy bindings happy.
        daemonOutput = ""
        telemetryLines.removeAll()
    }

    func installAndLoadDriver() {
        let embeddedDextURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents")
            .appendingPathComponent("Library")
            .appendingPathComponent("SystemExtensions")
            .appendingPathComponent("VirtualJoyConDriver.dext")

        guard FileManager.default.fileExists(atPath: embeddedDextURL.path) else {
            let msg = "Driver extension is missing from Contents/Library/SystemExtensions."
            driverInstallStatus = msg
            TelemetryStore.shared.updateDriverStatus(msg)
            TelemetryStore.shared.append(msg)
            return
        }

        let initial = "Submitting driver activation request..."
        driverInstallStatus = initial
        TelemetryStore.shared.updateDriverStatus(initial)
        TelemetryStore.shared.append("Activating DriverKit extension from \(embeddedDextURL.path)")

        DriverExtensionInstaller.shared.activate { [weak self] status, shouldRestartDaemon in
            DispatchQueue.main.async {
                self?.driverInstallStatus = status
                TelemetryStore.shared.updateDriverStatus(status)
                TelemetryStore.shared.append("[driver] \(status)")
                if shouldRestartDaemon {
                    self?.restartDaemon()
                }
            }
        }
    }

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
        var updated = controllers
        for index in updated.indices {
            updated[index].isConnected = false
            updated[index].status = status
        }
        controllers = updated
        bumpStateRevision()
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
        // Firehose goes only to TelemetryStore now. No publisher invalidation on DaemonBridge.
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

    private func updateController(from object: [String: Any]) {
        let side = stringValue(object["side"], default: "left")
        let normalizedSide = side == "right" ? "right" : "left"
        let now = Date()
        if let lastUpdate = lastControllerUpdate[normalizedSide],
           now.timeIntervalSince(lastUpdate) < controllerUpdateInterval {
            return
        }
        lastControllerUpdate[normalizedSide] = now
        let currentStatus = controllers.first(where: { $0.id == normalizedSide })?.status
        let dataStatus = currentStatus == "ready" ? "ready" : (currentStatus ?? "streaming")

        let controller = ControllerState(
            id: normalizedSide,
            side: normalizedSide,
            name: normalizedSide == "right" ? "Joy-Con R" : "Joy-Con L",
            macAddress: normalizedSide == "right" ? "Right BLE peripheral" : "Left BLE peripheral",
            isConnected: true,
            status: dataStatus,
            batteryVoltage: doubleValue(object["batteryVoltage"]),
            batteryCurrent: doubleValue(object["batteryCurrent"]),
            batteryTemperature: doubleValue(object["batteryTemperature"]),
            batteryPercentage: doubleValue(object["batteryPercentage"], default: -1),
            buttons: uint32Value(object["buttons"]),
            leftButtons: uint32Value(object["leftButtons"]),
            rightButtons: uint32Value(object["rightButtons"]),
            leftStickX: int16Value(object["leftStickX"]),
            leftStickY: int16Value(object["leftStickY"]),
            rightStickX: int16Value(object["rightStickX"]),
            rightStickY: int16Value(object["rightStickY"]),
            gyroX: doubleValue(object["gyroX"]),
            gyroY: doubleValue(object["gyroY"]),
            gyroZ: doubleValue(object["gyroZ"]),
            accelX: doubleValue(object["accelX"]),
            accelY: doubleValue(object["accelY"]),
            accelZ: doubleValue(object["accelZ"]),
            mouseX: int16Value(object["mouseX"]),
            mouseY: int16Value(object["mouseY"]),
            mouseDistance: int16Value(object["mouseDistance"]),
            triggerL: uint8Value(object["triggerL"]),
            triggerR: uint8Value(object["triggerR"]),
            packetCount: uint32Value(object["packetCount"]),
            mouseMode: MouseMode(rawValue: intValue(object["mouseMode"])) ?? .off,
            rssi: intValue(object["rssi"], default: 0)
        )

        var updated = controllers
        if let index = updated.firstIndex(where: { $0.id == controller.id }) {
            updated[index] = controller
        } else {
            updated.append(controller)
            updated.sort { $0.id < $1.id }
        }
        controllers = updated
        bumpStateRevision()
    }

    private func updateControllerStatus(from object: [String: Any]) {
        let side = stringValue(object["side"], default: "left")
        let normalizedSide = side == "right" ? "right" : "left"
        let rawStatus = stringValue(object["status"], default: "scanning")
        let name = stringValue(
            object["name"],
            default: normalizedSide == "right" ? "Joy-Con R" : "Joy-Con L"
        )
        let message = stringValue(object["message"], default: "")
        let connectedStatuses = ["bleConnected", "servicesReady", "initializing", "ready", "streaming", "commandTimeout"]
        let isConnected = connectedStatuses.contains(rawStatus)

        var updated = controllers
        if let index = updated.firstIndex(where: { $0.id == normalizedSide }) {
            updated[index].isConnected = isConnected
            if shouldReplaceStatus(current: updated[index].status, incoming: rawStatus) {
                updated[index].status = rawStatus
            }
            if !name.isEmpty {
                updated[index].name = normalizedSide == "right" ? "Joy-Con R" : "Joy-Con L"
                updated[index].macAddress = message.isEmpty ? name : message
            }
            controllers = updated
            bumpStateRevision()
        } else {
            updated.append(
                ControllerState(
                    id: normalizedSide,
                    side: normalizedSide,
                    name: normalizedSide == "right" ? "Joy-Con R" : "Joy-Con L",
                    macAddress: message.isEmpty ? name : message,
                    isConnected: isConnected,
                    status: rawStatus,
                    batteryVoltage: 0,
                    batteryCurrent: 0,
                    batteryTemperature: 0,
                    batteryPercentage: -1,
                    buttons: 0,
                    leftButtons: 0,
                    rightButtons: 0,
                    leftStickX: 0,
                    leftStickY: 0,
                    rightStickX: 0,
                    rightStickY: 0,
                    gyroX: 0,
                    gyroY: 0,
                    gyroZ: 0,
                    accelX: 0,
                    accelY: 0,
                    accelZ: 0,
                    mouseX: 0,
                    mouseY: 0,
                    mouseDistance: 0,
                    triggerL: 0,
                    triggerR: 0,
                    packetCount: 0,
                    mouseMode: .off,
                    rssi: 0
                )
            )
            updated.sort { $0.id < $1.id }
            controllers = updated
            bumpStateRevision()
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

    private func bumpStateRevision() {
        stateRevision &+= 1
    }
}
