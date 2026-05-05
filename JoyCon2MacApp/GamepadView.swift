import SwiftUI

struct GamepadView: View {
    @EnvironmentObject var daemonBridge: DaemonBridge

    private var leftController: Controller? {
        daemonBridge.controllers.first { $0.side == "left" }
    }

    private var rightController: Controller? {
        daemonBridge.controllers.first { $0.side == "right" }
    }

    var body: some View {
        Group {
            if leftController == nil && rightController == nil {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if let left = leftController {
                            LeftGamepadSection(controller: left)
                        }
                        if let right = rightController {
                            RightGamepadSection(controller: right)
                        }
                        CombinedFooter(left: leftController, right: rightController)
                    }
                    .padding(20)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "gamecontroller")
                .font(.system(size: 48, weight: .medium))
                .foregroundColor(.secondary)
            Text("No Controller Connected")
                .font(.title3)
                .fontWeight(.semibold)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Left Joy-Con

private struct LeftGamepadSection: View {
    @ObservedObject var controller: Controller

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "l.circle.fill").foregroundColor(.blue)
                Text("Left Joy-Con").font(.headline)
                Spacer()
                Text("Packets \(controller.packetCount)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }

            HStack(alignment: .center, spacing: 32) {
                VStack(spacing: 14) {
                    DpadCluster(buttons: controller.leftButtons)
                    StickIndicator(
                        title: "Left Stick",
                        x: controller.leftStickX,
                        y: controller.leftStickY,
                        color: .blue
                    )
                }

                Spacer()

                VStack(alignment: .leading, spacing: 10) {
                    shoulderRow(label: "L", mask: 0x0040, analog: controller.triggerL)
                    shoulderRow(label: "ZL", mask: 0x0080, analog: nil)
                    Divider().frame(maxWidth: 160)
                    smallButton(label: "SL", mask: 0x0020)
                    smallButton(label: "SR", mask: 0x0010)
                    smallButton(label: "L3", mask: 0x0800)
                    Divider().frame(maxWidth: 160)
                    smallButton(label: "−", mask: 0x0100)
                    smallButton(label: "Capture", mask: 0x2000)
                }
            }
        }
        .padding(16)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func shoulderRow(label: String, mask: UInt32, analog: UInt8?) -> some View {
        HStack(spacing: 10) {
            ButtonIndicator(
                isPressed: (controller.leftButtons & mask) != 0,
                label: label,
                color: .purple
            )
            if let analog {
                ProgressView(value: Double(analog), total: 255)
                    .frame(maxWidth: 120)
                Text("\(analog)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private func smallButton(label: String, mask: UInt32) -> some View {
        ButtonIndicator(
            isPressed: (controller.leftButtons & mask) != 0,
            label: label,
            color: .gray
        )
    }
}

// MARK: - Right Joy-Con

private struct RightGamepadSection: View {
    @ObservedObject var controller: Controller

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "r.circle.fill").foregroundColor(.red)
                Text("Right Joy-Con").font(.headline)
                Spacer()
                Text("Packets \(controller.packetCount)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }

            HStack(alignment: .center, spacing: 32) {
                VStack(spacing: 14) {
                    FaceButtons(buttons: controller.rightButtons)
                    StickIndicator(
                        title: "Right Stick",
                        x: controller.rightStickX,
                        y: controller.rightStickY,
                        color: .green
                    )
                }

                Spacer()

                VStack(alignment: .leading, spacing: 10) {
                    shoulderRow(label: "R", mask: 0x004000, analog: controller.triggerR)
                    shoulderRow(label: "ZR", mask: 0x008000, analog: nil)
                    Divider().frame(maxWidth: 160)
                    smallButton(label: "SL", mask: 0x002000)
                    smallButton(label: "SR", mask: 0x001000)
                    smallButton(label: "R3", mask: 0x000004)
                    Divider().frame(maxWidth: 160)
                    smallButton(label: "+", mask: 0x000002)
                    smallButton(label: "Home", mask: 0x000010)
                    // Switch 2 introduced the Chat / C button on the Right Joy-Con.
                    // joycon2cpp treats mask 0x000040 as the Chat/C press; this
                    // is the same bit that used to mean "R" on Switch 1 right.
                    smallButton(label: "Chat (C)", mask: 0x000040)
                }
            }
        }
        .padding(16)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func shoulderRow(label: String, mask: UInt32, analog: UInt8?) -> some View {
        HStack(spacing: 10) {
            ButtonIndicator(
                isPressed: (controller.rightButtons & mask) != 0,
                label: label,
                color: .purple
            )
            if let analog {
                ProgressView(value: Double(analog), total: 255)
                    .frame(maxWidth: 120)
                Text("\(analog)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private func smallButton(label: String, mask: UInt32) -> some View {
        ButtonIndicator(
            isPressed: (controller.rightButtons & mask) != 0,
            label: label,
            color: .gray
        )
    }
}

// MARK: - Combined footer

private struct CombinedFooter: View {
    let left: Controller?
    let right: Controller?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "link")
            Text("Combined Gamepad HID")
                .font(.subheadline)
                .fontWeight(.medium)
            Spacer()
            Text(summary)
                .font(.caption)
                .foregroundColor(.secondary)
                .monospacedDigit()
        }
        .padding(12)
        .background(Color(NSColor.windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var summary: String {
        let leftPackets = left.map(\.packetCount).map { "L \($0)" } ?? "L missing"
        let rightPackets = right.map(\.packetCount).map { "R \($0)" } ?? "R missing"
        return "\(leftPackets) · \(rightPackets)"
    }
}

// MARK: - D-pad and face buttons

private struct DpadCluster: View {
    let buttons: UInt32

    var body: some View {
        VStack(spacing: 5) {
            ButtonIndicator(isPressed: buttons & 0x0002 != 0, label: "↑")
            HStack(spacing: 5) {
                ButtonIndicator(isPressed: buttons & 0x0008 != 0, label: "←")
                Color.clear.frame(width: 34, height: 34)
                ButtonIndicator(isPressed: buttons & 0x0004 != 0, label: "→")
            }
            ButtonIndicator(isPressed: buttons & 0x0001 != 0, label: "↓")
        }
    }
}

private struct FaceButtons: View {
    let buttons: UInt32

    var body: some View {
        VStack(spacing: 5) {
            ButtonIndicator(isPressed: buttons & 0x000200 != 0, label: "X", color: .blue)
            HStack(spacing: 5) {
                ButtonIndicator(isPressed: buttons & 0x000100 != 0, label: "Y", color: .green)
                Color.clear.frame(width: 34, height: 34)
                ButtonIndicator(isPressed: buttons & 0x000800 != 0, label: "A", color: .red)
            }
            ButtonIndicator(isPressed: buttons & 0x000400 != 0, label: "B", color: .yellow)
        }
    }
}

private struct StickIndicator: View {
    let title: String
    let x: Int16
    let y: Int16
    let color: Color

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.16))
                    .frame(width: 108, height: 108)
                Circle()
                    .stroke(color.opacity(0.35), lineWidth: 1)
                    .frame(width: 108, height: 108)
                Circle()
                    .fill(color)
                    .frame(width: 18, height: 18)
                    .offset(
                        x: CGFloat(x) / 32767 * 42,
                        y: CGFloat(-y) / 32767 * 42
                    )
            }

            VStack(spacing: 1) {
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("\(x), \(y)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
        }
    }
}

struct ButtonIndicator: View {
    let isPressed: Bool
    let label: String
    var color: Color = .blue

    var body: some View {
        Text(label)
            .font(.system(size: label.count > 4 ? 10 : 13, weight: .semibold))
            .foregroundColor(isPressed ? .white : .secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(width: 52, height: 30)
            .background(isPressed ? color : Color.secondary.opacity(0.18))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

#Preview {
    GamepadView()
        .environmentObject(DaemonBridge.shared)
        .frame(width: 900, height: 700)
}
