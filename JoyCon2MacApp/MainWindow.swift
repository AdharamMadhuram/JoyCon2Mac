import SwiftUI

private enum AppSection: String, CaseIterable, Identifiable {
    case controllers = "Controllers"
    case gamepad = "Gamepad"
    case mouse = "Mouse"
    case gyro = "Gyro"
    case nfc = "NFC"
    case settings = "Settings"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .controllers: return "gamecontroller"
        case .gamepad: return "dpad"
        case .mouse: return "computermouse"
        case .gyro: return "gyroscope"
        case .nfc: return "wave.3.right"
        case .settings: return "gearshape"
        }
    }

    var subtitle: String {
        switch self {
        case .controllers: return "Bluetooth connection, battery, and packet status"
        case .gamepad: return "Combined HID gamepad report"
        case .mouse: return "Optical sensor mouse output"
        case .gyro: return "IMU motion telemetry"
        case .nfc: return "Vendor NFC report stream"
        case .settings: return "Driver and app preferences"
        }
    }
}

struct MainWindow: View {
    @EnvironmentObject var daemonBridge: DaemonBridge
    @State private var selectedSection: AppSection = .controllers

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(selected: $selectedSection)

            Divider()

            VStack(spacing: 0) {
                TopBar(selected: selectedSection)
                Divider()
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(minWidth: 960, minHeight: 640)
    }

    @ViewBuilder
    private var content: some View {
        switch selectedSection {
        case .controllers:
            ControllersView()
        case .gamepad:
            GamepadView()
        case .mouse:
            MouseView()
        case .gyro:
            GyroView()
        case .nfc:
            NFCView()
        case .settings:
            SettingsView()
        }
    }
}

// Sidebar is deliberately isolated from per-packet daemon state so its hit
// targets stay responsive. It only reads the controller count and the
// daemon-running flag, which only flip a few times per session.
private struct Sidebar: View {
    @Binding var selected: AppSection
    @EnvironmentObject var daemonBridge: DaemonBridge

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text("JoyCon2Mac")
                        .font(.headline)
                    Text("Local Driver")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)

            VStack(spacing: 4) {
                ForEach(AppSection.allCases) { section in
                    SidebarButton(
                        section: section,
                        isSelected: selected == section
                    ) {
                        selected = section
                    }
                }
            }
            .padding(.horizontal, 8)

            Spacer()

            VStack(alignment: .leading, spacing: 8) {
                statusRow(
                    title: daemonBridge.isDaemonRunning ? "Daemon running" : "Daemon stopped",
                    color: daemonBridge.isDaemonRunning ? .green : .red
                )
                statusRow(
                    title: "\(connectedControllerCount) active controller\(connectedControllerCount == 1 ? "" : "s")",
                    color: connectedControllerCount == 0 ? .secondary : .accentColor
                )
            }
            .padding(12)
        }
        .frame(width: 200)
        .background(Color(NSColor.controlBackgroundColor))
    }

    private var connectedControllerCount: Int {
        daemonBridge.controllers.filter { $0.isConnected }.count
    }

    private func statusRow(title: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

private struct SidebarButton: View {
    let section: AppSection
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                Image(systemName: section.icon)
                    .frame(width: 20)
                Text(section.rawValue)
                Spacer()
            }
            .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
            .foregroundColor(isSelected ? .primary : .secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct TopBar: View {
    let selected: AppSection
    @EnvironmentObject var daemonBridge: DaemonBridge

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(selected.rawValue)
                    .font(.title2)
                    .fontWeight(.semibold)
                Text(selected.subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button {
                daemonBridge.isDaemonRunning ? daemonBridge.stopDaemon() : daemonBridge.startDaemon()
            } label: {
                Label(daemonBridge.isDaemonRunning ? "Stop" : "Start",
                      systemImage: daemonBridge.isDaemonRunning ? "stop.fill" : "play.fill")
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

#Preview {
    MainWindow()
        .environmentObject(DaemonBridge.shared)
}
