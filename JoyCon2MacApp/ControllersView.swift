import SwiftUI

struct ControllersView: View {
    @EnvironmentObject var daemonBridge: DaemonBridge

    private let columns = [
        GridItem(.adaptive(minimum: 300, maximum: 420), spacing: 14, alignment: .top)
    ]

    var body: some View {
        Group {
            if daemonBridge.controllers.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                        ForEach(daemonBridge.controllers) { controller in
                            ControllerCard(controller: controller)
                        }
                    }
                    .padding(20)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 48, weight: .medium))
                .foregroundColor(.secondary)

            Text("No Controllers Connected")
                .font(.title3)
                .fontWeight(.semibold)

            Text("Hold SYNC on each Joy-Con 2.")
                .font(.body)
                .foregroundColor(.secondary)

            Button {
                daemonBridge.restartDaemon()
            } label: {
                Label("Restart Scan", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ControllerCard: View {
    let controller: ControllerState

    private var batteryPercentage: Double {
        if controller.batteryPercentage >= 0 {
            // Joy2Win uses the raw level at packet bytes 31/32, but on this
            // hardware a charge-grip-full controller commonly reports about
            // 89-90. Treat that top band as full instead of showing a false
            // partial charge.
            if controller.batteryPercentage >= 88 {
                return 100
            }
            return controller.batteryPercentage
        }
        let minVoltage = 3.0
        let maxVoltage = 4.2
        let percentage = (controller.batteryVoltage - minVoltage) / (maxVoltage - minVoltage) * 100
        return max(0, min(100, percentage))
    }

    private var batteryColor: Color {
        if batteryPercentage > 50 { return .green }
        if batteryPercentage > 20 { return .orange }
        return .red
    }

    private var statusText: String {
        switch controller.status {
        case "scanning": return "Scanning"
        case "queued": return "Queued"
        case "connecting": return "Connecting"
        case "bleConnected": return "BLE linked"
        case "servicesReady": return "Services ready"
        case "initializing": return "Initializing"
        case "ready": return "Ready"
        case "streaming": return "Streaming"
        case "commandTimeout": return "Command timeout"
        case "connectFailed": return "Connect failed"
        case "writeFailed": return "Write failed"
        case "disconnected": return "Disconnected"
        case "daemonStopped": return "Daemon stopped"
        default: return controller.isConnected ? "BLE Active" : "Offline"
        }
    }

    private var statusColor: Color {
        switch controller.status {
        case "ready": return .green
        case "streaming", "bleConnected", "servicesReady", "initializing", "connecting", "queued": return .blue
        case "commandTimeout": return .orange
        case "connectFailed", "writeFailed", "disconnected", "daemonStopped": return .red
        default: return controller.isConnected ? .green : .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: controller.side == "right" ? "r.circle.fill" : "l.circle.fill")
                    .font(.title2)
                    .foregroundColor(.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(controller.name)
                        .font(.headline)
                    Text(controller.macAddress)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                ConnectionBadge(title: statusText, color: statusColor)
            }

            Divider()

            HStack(spacing: 16) {
                MetricTile(
                    title: "Battery",
                    value: controller.batteryPercentage >= 0 ? "\(Int(batteryPercentage))%" : "Unknown",
                    detail: validBatteryVoltageText,
                    icon: batteryIcon,
                    color: batteryColor
                )

                MetricTile(
                    title: "Temp",
                    value: "\(Int(controller.batteryTemperature))°C",
                    detail: "\(Int(controller.batteryCurrent))mA",
                    icon: "thermometer.medium",
                    color: .orange
                )
            }

            HStack(spacing: 16) {
                MetricTile(
                    title: "Packets",
                    value: "\(controller.packetCount)",
                    detail: controller.side.capitalized,
                    icon: "waveform.path.ecg",
                    color: .blue
                )

                MetricTile(
                    title: "Mouse",
                    value: controller.mouseMode.description,
                    // When mouse is on, show which Joy-Con is currently
                    // driving the pointer ("active: left/right"), plus
                    // this side's distance so you can tell at a glance
                    // which controller is on a surface.
                    detail: controller.mouseMode == .off
                        ? "Distance \(controller.mouseDistance)"
                        : "Active: \(controller.mouseActiveSide.capitalized) · d=\(controller.mouseDistance)",
                    icon: "computermouse",
                    color: controller.mouseMode == .off ? .secondary : .accentColor
                )
            }
        }
        .padding(14)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var batteryIcon: String {
        if batteryPercentage > 75 { return "battery.100" }
        if batteryPercentage > 50 { return "battery.75" }
        if batteryPercentage > 25 { return "battery.50" }
        return "battery.25"
    }

    private var validBatteryVoltageText: String {
        guard controller.batteryVoltage >= 3.0, controller.batteryVoltage <= 5.5 else {
            return batteryPercentage >= 100 ? "Full" : "No voltage"
        }
        return String(format: "%.2fV", controller.batteryVoltage)
    }
}

private struct ConnectionBadge: View {
    let title: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color(NSColor.windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct MetricTile: View {
    let title: String
    let value: String
    let detail: String
    let icon: String
    let color: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(color)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(value)
                    .font(.headline)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
    }
}

#Preview {
    ControllersView()
        .environmentObject(DaemonBridge.shared)
        .frame(width: 800, height: 600)
}
