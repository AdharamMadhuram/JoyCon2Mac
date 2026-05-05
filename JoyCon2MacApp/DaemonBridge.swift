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

// Design notes (frozen-UI postmortem)
//
// The UI was freezing because the main thread was doing:
//   1. File I/O (tailing daemon.jsonl every 100 ms)
//   2. JSON parsing for ~240 state events per second
//   3. Appending to a Published string (invalidating every view)
//   4. SwiftUI view updates
//
// Throttling step 3 in isolation does NOT help: steps 1-2 still thrash the
// main run loop. SwiftUI cannot repaint. Apple's Combine / Concurrency docs
// (https://developer.apple.com/documentation/swiftui/managing-model-data-in-your-app)
// explicitly recommend running data ingest on a background queue and
// publishing to main via a throttled pipeline.
//
// So the real fix is architectural:
//   - Log tailing + JSON parsing run on a dedicated serial background queue.
//   - State events are gated at 15 Hz per side inside that queue (so we only
//     do expensive work once per 66 ms).
//   - Only the gated, pre-built ControllerState is hopped onto main.
//   - Telemetry log lines go to TelemetryStore, which batch-flushes to main
//     every 200 ms. Settings/Logs views are the only subscribers.
class DaemonBridge: ObservableObject {
    static let shared = DaemonBridge()

    @Published var controllers: [ControllerState] = []
    @Published var nfcTags: [NFCTag] = []
    @Published var isDaemonRunning = false
    // Kept for source-compat with older views. Never mutated from the
    // packet firehose now; only on driver-install result.
    @Published var driverInstallStatus: String = ""
    @Published var stateRevision: UInt64 = 0

    // Background queue that owns parsing, file tailing, and throttling.
    // Nothing on this queue touches @Published state directly.
    private let ingestQueue = DispatchQueue(label: "local.joycon2mac.ingest", qos: .userInitiated)

    private var daemonProcess: Process?
    private var daemonApplication: NSRunningApplication?
    private var outputPipe: Pipe?
    private var pendingOutput = ""
    // Per-controller rate limiter (accessed only on ingestQueue).
    private var lastIngestTime: [String: Date] = [:]
    private let controllerUpdateInterval: TimeInterval = 1.0 / 15.0
    private var shouldRestartAfterTermination = false
    private var logPollTimer: DispatchSourceTimer?
    private var daemonLogPath: URL?
    private var daemonLogOffset: UInt64 = 0
    // Diagnostic counters bumped on ingestQueue; snapshotted for logs.
    private var ingestPacketCountLeft: UInt64 = 0
    private var ingestPacketCountRight: UInt64 = 0
    private var ingestPacketDropLeft: UInt64 = 0
    private var ingestPacketDropRight: UInt64 = 0

    private init() {
        startDaemon()
    }

    deinit {
        stopDaemon()
    }

    // MARK: - Lifecycle

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
        ingestQueue.async { [weak self] in
            self?.lastIngestTime.removeAll()
        }

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
            // NEVER parse on this callback's queue directly; dispatch to
            // ingest queue so the main thread never sees this work.
            self?.ingestQueue.async {
                self?.parseDaemonOutputOnIngestQueue(output)
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
            ingestQueue.async { [weak self] in
                self?.lastIngestTime.removeAll()
                self?.ingestPacketCountLeft = 0
                self?.ingestPacketCountRight = 0
                self?.ingestPacketDropLeft = 0
                self?.ingestPacketDropRight = 0
            }

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
            return
        }

        guard let process = daemonProcess else {
            outputPipe = nil
            stopLogPolling()
            markControllersDisconnected(status: "daemonStopped")
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

    // MARK: - Log tailing (background)

    private func startLogPolling() {
        stopLogPolling()
        let timer = DispatchSource.makeTimerSource(queue: ingestQueue)
        timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
        timer.setEventHandler { [weak self] in
            self?.pollDaemonLogOnIngestQueue()
        }
        logPollTimer = timer
        timer.resume()
    }

    private func stopLogPolling() {
        logPollTimer?.cancel()
        logPollTimer = nil
    }

    private func pollDaemonLogOnIngestQueue() {
        // Runs on ingestQueue.
        if let daemonApplication, daemonApplication.isTerminated {
            DispatchQueue.main.async { [weak self] in self?.handleDaemonTerminated() }
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
                parseDaemonOutputOnIngestQueue(output)
            }
        } catch {
            try? handle.close()
        }
    }

    // MARK: - Parsing (background)

    private func parseDaemonOutputOnIngestQueue(_ output: String) {
        // Runs on ingestQueue.
        //
        // Careful: on bursty input, doing `pendingOutput += output` followed
        // by repeated `range(of: "\n")` + `removeSubrange(...)` is O(n^2) on
        // Swift strings. A 50-line batch of ~120-byte JSONL records becomes
        // ~millions of char copies, which is what was stalling the ingest
        // queue and occasionally freezing the UI.
        //
        // Instead: split the incoming chunk on newlines first (linear), and
        // only carry the trailing partial line across batches.
        let combined = pendingOutput + output
        var lines = combined.components(separatedBy: "\n")
        // Last element is whatever came after the final '\n' (may be empty
        // if the daemon flushed a full line, or a partial line mid-write).
        pendingOutput = lines.removeLast()

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                parseDaemonLineOnIngestQueue(trimmed)
            }
        }

        // Defensive: if a pathological write left us with a very long
        // partial line, clamp it rather than let it grow unbounded.
        if pendingOutput.count > 64 * 1024 {
            pendingOutput = ""
        }
    }

    private func parseDaemonLineOnIngestQueue(_ line: String) {
        guard line.hasPrefix("{"), let data = line.data(using: .utf8) else {
            TelemetryStore.shared.append(line)
            return
        }

        // Fast path: peek at "event" without full JSON parse so we can drop
        // state packets that are inside the 15 Hz throttle window.
        let maybeState = line.contains("\"event\":\"state\"")
        if maybeState {
            let side = extractStateSide(in: line) ?? "left"
            let now = Date()
            if let last = lastIngestTime[side], now.timeIntervalSince(last) < controllerUpdateInterval {
                if side == "right" { ingestPacketDropRight &+= 1 } else { ingestPacketDropLeft &+= 1 }
                return
            }
            lastIngestTime[side] = now
            if side == "right" { ingestPacketCountRight &+= 1 } else { ingestPacketCountLeft &+= 1 }
        }

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = object["event"] as? String else {
            TelemetryStore.shared.append(line)
            return
        }

        switch event {
        case "daemon":
            let status = stringValue(object["status"], default: "unknown")
            let detail = stringValue(object["detail"], default: "")
            TelemetryStore.shared.append("[daemon] \(status)\(detail.isEmpty ? "" : " - \(detail)")")
            DispatchQueue.main.async { [weak self] in
                if status == "started" { self?.isDaemonRunning = true }
                else if status == "exiting" { self?.isDaemonRunning = false }
            }
        case "telemetry":
            let side = stringValue(object["side"], default: "left")
            let phase = stringValue(object["phase"], default: "unknown")
            let detail = stringValue(object["detail"], default: "")
            let name = stringValue(object["name"], default: "")
            TelemetryStore.shared.append("[\(side)] \(phase)\(name.isEmpty ? "" : " \(name)")\(detail.isEmpty ? "" : " - \(detail)")")
        case "controller":
            let snapshot = buildControllerStatus(from: object)
            pendingStatusSnapshots[snapshot.side] = snapshot
            scheduleMainApplyLocked()
        case "state":
            let snapshot = buildControllerState(from: object)
            pendingStateSnapshots[snapshot.id] = snapshot
            scheduleMainApplyLocked()
        case "nfc":
            guard let uid = object["uid"] as? String else { return }
            let payloadHex = object["payload"] as? String ?? ""
            let tag = NFCTag(
                uid: uid,
                type: object["type"] as? String ?? "Vendor",
                data: Data(payloadHex.utf8),
                timestamp: Date()
            )
            DispatchQueue.main.async { [weak self] in self?.nfcTags.insert(tag, at: 0) }
        default:
            return
        }
    }

    // Cheap extraction of "side" from a state JSON line without full decode.
    private func extractStateSide(in line: String) -> String? {
        if line.contains("\"side\":\"right\"") { return "right" }
        if line.contains("\"side\":\"left\"") { return "left" }
        return nil
    }

    // MARK: - Snapshot builders (background)

    private func buildControllerState(from object: [String: Any]) -> ControllerState {
        let side = stringValue(object["side"], default: "left")
        let normalizedSide = side == "right" ? "right" : "left"
        return ControllerState(
            id: normalizedSide,
            side: normalizedSide,
            name: normalizedSide == "right" ? "Joy-Con R" : "Joy-Con L",
            macAddress: normalizedSide == "right" ? "Right BLE peripheral" : "Left BLE peripheral",
            isConnected: true,
            status: "streaming",
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
    }

    private struct ControllerStatusSnapshot {
        let side: String
        let status: String
        let message: String
        let name: String
        let isConnected: Bool
    }

    private func buildControllerStatus(from object: [String: Any]) -> ControllerStatusSnapshot {
        let side = stringValue(object["side"], default: "left")
        let normalizedSide = side == "right" ? "right" : "left"
        let rawStatus = stringValue(object["status"], default: "scanning")
        let name = stringValue(
            object["name"],
            default: normalizedSide == "right" ? "Joy-Con R" : "Joy-Con L"
        )
        let message = stringValue(object["message"], default: "")
        let connectedStatuses = ["bleConnected", "servicesReady", "initializing", "ready", "streaming", "commandTimeout"]
        return ControllerStatusSnapshot(
            side: normalizedSide,
            status: rawStatus,
            message: message,
            name: name,
            isConnected: connectedStatuses.contains(rawStatus)
        )
    }

    // MARK: - Main-thread appliers
    //
    // We coalesce snapshots on the ingest queue into a small dictionary and
    // flush to the Published array at most every 50 ms. That's 20 Hz UI
    // refresh — still feels live but caps SwiftUI re-render pressure.
    private var pendingStateSnapshots: [String: ControllerState] = [:]
    private var pendingStatusSnapshots: [String: ControllerStatusSnapshot] = [:]
    private var mainApplyScheduled: Bool = false
    private let mainApplyInterval: TimeInterval = 0.05

    private func scheduleMainApplyLocked() {
        // Called on ingestQueue.
        if mainApplyScheduled { return }
        mainApplyScheduled = true
        let deadline = DispatchTime.now() + mainApplyInterval
        DispatchQueue.main.asyncAfter(deadline: deadline) { [weak self] in
            self?.flushPendingToMain()
        }
    }

    private func flushPendingToMain() {
        // Called on main. Move ingest-side pending dicts over in one hop.
        let (states, statuses): ([String: ControllerState], [String: ControllerStatusSnapshot]) = ingestQueue.sync {
            let s = pendingStateSnapshots
            let u = pendingStatusSnapshots
            pendingStateSnapshots.removeAll(keepingCapacity: true)
            pendingStatusSnapshots.removeAll(keepingCapacity: true)
            mainApplyScheduled = false
            return (s, u)
        }

        if states.isEmpty && statuses.isEmpty { return }

        var updated = controllers
        var changed = false

        for (_, status) in statuses {
            if let index = updated.firstIndex(where: { $0.id == status.side }) {
                if updated[index].isConnected != status.isConnected {
                    updated[index].isConnected = status.isConnected
                    changed = true
                }
                if shouldReplaceStatus(current: updated[index].status, incoming: status.status) {
                    updated[index].status = status.status
                    changed = true
                }
                if !status.name.isEmpty {
                    updated[index].name = status.side == "right" ? "Joy-Con R" : "Joy-Con L"
                    updated[index].macAddress = status.message.isEmpty ? status.name : status.message
                    changed = true
                }
            } else {
                updated.append(
                    ControllerState(
                        id: status.side,
                        side: status.side,
                        name: status.side == "right" ? "Joy-Con R" : "Joy-Con L",
                        macAddress: status.message.isEmpty ? status.name : status.message,
                        isConnected: status.isConnected,
                        status: status.status,
                        batteryVoltage: 0, batteryCurrent: 0, batteryTemperature: 0, batteryPercentage: -1,
                        buttons: 0, leftButtons: 0, rightButtons: 0,
                        leftStickX: 0, leftStickY: 0, rightStickX: 0, rightStickY: 0,
                        gyroX: 0, gyroY: 0, gyroZ: 0,
                        accelX: 0, accelY: 0, accelZ: 0,
                        mouseX: 0, mouseY: 0, mouseDistance: 0,
                        triggerL: 0, triggerR: 0,
                        packetCount: 0, mouseMode: .off, rssi: 0
                    )
                )
                updated.sort { $0.id < $1.id }
                changed = true
            }
        }

        for (_, snapshot) in states {
            var merged = snapshot
            if let index = updated.firstIndex(where: { $0.id == merged.id }) {
                if updated[index].status == "ready" { merged.status = "ready" }
                updated[index] = merged
            } else {
                updated.append(merged)
                updated.sort { $0.id < $1.id }
            }
            changed = true
        }

        if changed {
            controllers = updated
            stateRevision &+= 1
        }
    }

    // MARK: - Misc

    func toggleMouseMode() {
        if let controller = controllers.first {
            let nextRaw = (controller.mouseMode.rawValue + 1) % 4
            let newMode = MouseMode(rawValue: nextRaw) ?? .off
            var updated = controllers
            updated[0].mouseMode = newMode
            controllers = updated
            stateRevision &+= 1
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

    // Expose counters for diagnostic overlay.
    func ingestDiagnostics() -> (leftKept: UInt64, rightKept: UInt64, leftDropped: UInt64, rightDropped: UInt64) {
        ingestQueue.sync {
            (ingestPacketCountLeft, ingestPacketCountRight, ingestPacketDropLeft, ingestPacketDropRight)
        }
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

    private func markControllersDisconnected(status: String) {
        var updated = controllers
        for index in updated.indices {
            updated[index].isConnected = false
            updated[index].status = status
        }
        controllers = updated
        stateRevision &+= 1
    }

    private func handleDaemonTerminated() {
        daemonApplication = nil
        daemonProcess = nil
        outputPipe = nil
        stopLogPolling()
        isDaemonRunning = false
        TelemetryStore.shared.append("[daemon] helper process terminated")
        if shouldRestartAfterTermination {
            shouldRestartAfterTermination = false
            startDaemon()
        } else {
            markControllersDisconnected(status: "daemonStopped")
        }
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
