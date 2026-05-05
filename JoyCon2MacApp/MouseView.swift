import SwiftUI

struct MouseView: View {
    @EnvironmentObject var daemonBridge: DaemonBridge

    var body: some View {
        Group {
            if daemonBridge.controllers.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header
                        ForEach(daemonBridge.controllers) { controller in
                            MousePanel(controller: controller)
                        }
                        mappingSection
                    }
                    .padding(20)
                }
            }
        }
    }

    private var header: some View {
        HStack {
            Text("Mouse Output")
                .font(.title2)
                .fontWeight(.semibold)
            Spacer()
            Button {
                daemonBridge.toggleMouseMode()
            } label: {
                Label("Cycle Mode", systemImage: "computermouse.fill")
            }
            .buttonStyle(.bordered)
        }
    }

    private var mappingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Button Mapping")
                .font(.headline)
            MappingRow(source: "L Button (Left Joy-Con)", target: "Left Click")
            MappingRow(source: "ZL Button (Left Joy-Con)", target: "Right Click")
            MappingRow(source: "R Button (Right Joy-Con)", target: "Left Click")
            MappingRow(source: "ZR Button (Right Joy-Con)", target: "Right Click")
            MappingRow(source: "Stick Click (L3 / R3)", target: "Middle Click")
            MappingRow(source: "Stick Y-Axis", target: "Scroll Wheel")
            MappingRow(source: "Capture (Left) / Chat / C (Right)", target: "Toggle Mouse Mode")
        }
        .padding(14)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "computermouse")
                .font(.system(size: 48, weight: .medium))
                .foregroundColor(.secondary)
            Text("No Controller Connected")
                .font(.title3)
                .fontWeight(.semibold)
            Text("Lay the Joy-Con on its side and press Capture (Left) or Chat / C (Right) to cycle mouse modes.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct MousePanel: View {
    @ObservedObject var controller: Controller

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: controller.side == "right" ? "r.circle.fill" : "l.circle.fill")
                    .foregroundColor(controller.side == "right" ? .red : .blue)
                Text(controller.name).font(.headline)
                Spacer()
                modeBadge(controller.mouseMode)
            }

            HStack(spacing: 14) {
                StatTile(title: "ΔX", value: "\(controller.mouseX)", color: .accentColor)
                StatTile(title: "ΔY", value: "\(controller.mouseY)", color: .accentColor)
                StatTile(title: "Distance", value: "\(controller.mouseDistance)", color: .orange)
            }

            Text("Distance is the IR sensor's estimate of how far the Joy-Con is from the surface. 0 usually means touching; larger values mean lifted.")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(14)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func modeBadge(_ mode: MouseMode) -> some View {
        let color: Color = {
            switch mode {
            case .off: return .secondary
            case .slow: return .green
            case .normal: return .blue
            case .fast: return .orange
            }
        }()
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text("Mode: \(mode.description)")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color(NSColor.windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct StatTile: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.title3)
                .fontWeight(.semibold)
                .monospacedDigit()
                .foregroundColor(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(NSColor.windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct MappingRow: View {
    let source: String
    let target: String

    var body: some View {
        HStack {
            Text(source)
                .font(.caption)
            Spacer()
            Image(systemName: "arrow.right")
                .foregroundColor(.secondary)
            Text(target)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.accentColor)
        }
    }
}

#Preview {
    MouseView()
        .environmentObject(DaemonBridge.shared)
        .frame(width: 800, height: 600)
}
