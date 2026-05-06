import SwiftUI

struct GamepadView: View {
    @EnvironmentObject var daemonBridge: DaemonBridge

    private var leftController: ControllerState? {
        daemonBridge.controllers.first { $0.side == "left" }
    }

    private var rightController: ControllerState? {
        daemonBridge.controllers.first { $0.side == "right" }
    }

    private var primaryController: ControllerState? {
        leftController ?? rightController ?? daemonBridge.controllers.first
    }

    private var leftButtons: UInt32 {
        leftController?.leftButtons ?? primaryController?.leftButtons ?? 0
    }

    private var rightButtons: UInt32 {
        rightController?.rightButtons ?? primaryController?.rightButtons ?? 0
    }

    var body: some View {
        Group {
            if primaryController == nil {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        controllerSurface
                        shoulderSection
                        railButtons
                        systemButtons
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

    private var controllerSurface: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Combined Output")
                    .font(.headline)
                Spacer()
                Text(connectionSummary)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.35), lineWidth: 1)
                    .background(Color(NSColor.controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                HStack(alignment: .center, spacing: 42) {
                    VStack(spacing: 18) {
                        dpad
                        StickIndicator(
                            title: "Left Stick",
                            x: leftController?.leftStickX ?? primaryController?.leftStickX ?? 0,
                            y: leftController?.leftStickY ?? primaryController?.leftStickY ?? 0,
                            color: .blue
                        )
                    }

                    Spacer()

                    VStack(spacing: 18) {
                        faceButtons
                        StickIndicator(
                            title: "Right Stick",
                            x: rightController?.rightStickX ?? primaryController?.rightStickX ?? 0,
                            y: rightController?.rightStickY ?? primaryController?.rightStickY ?? 0,
                            color: .green
                        )
                    }
                }
                .padding(28)
            }
            .frame(minHeight: 330)
        }
    }

    private var dpad: some View {
        VStack(spacing: 5) {
            ButtonIndicator(isPressed: leftButtons & 0x0002 != 0, label: "↑")
            HStack(spacing: 5) {
                ButtonIndicator(isPressed: leftButtons & 0x0008 != 0, label: "←")
                Color.clear.frame(width: 34, height: 34)
                ButtonIndicator(isPressed: leftButtons & 0x0004 != 0, label: "→")
            }
            ButtonIndicator(isPressed: leftButtons & 0x0001 != 0, label: "↓")
        }
    }

    private var faceButtons: some View {
        VStack(spacing: 5) {
            ButtonIndicator(isPressed: rightButtons & 0x000200 != 0, label: "X", color: .blue)
            HStack(spacing: 5) {
                ButtonIndicator(isPressed: rightButtons & 0x000100 != 0, label: "Y", color: .green)
                Color.clear.frame(width: 34, height: 34)
                ButtonIndicator(isPressed: rightButtons & 0x000800 != 0, label: "A", color: .red)
            }
            ButtonIndicator(isPressed: rightButtons & 0x000400 != 0, label: "B", color: .yellow)
        }
    }

    private var shoulderSection: some View {
        HStack(alignment: .top, spacing: 16) {
            ShoulderGroup(
                title: "Left Shoulder",
                primaryLabel: "L",
                primaryPressed: leftButtons & 0x0040 != 0,
                secondaryLabel: "ZL",
                secondaryPressed: leftButtons & 0x0080 != 0,
                triggerValue: leftController?.triggerL ?? primaryController?.triggerL ?? 0
            )

            ShoulderGroup(
                title: "Right Shoulder",
                primaryLabel: "R",
                primaryPressed: rightButtons & 0x004000 != 0,
                secondaryLabel: "ZR",
                secondaryPressed: rightButtons & 0x008000 != 0,
                triggerValue: rightController?.triggerR ?? primaryController?.triggerR ?? 0
            )
        }
    }

    private var railButtons: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Side Rail Buttons")
                .font(.headline)

            HStack(spacing: 12) {
                ButtonIndicator(isPressed: leftButtons & 0x0020 != 0, label: "SL L", color: .purple)
                ButtonIndicator(isPressed: leftButtons & 0x0010 != 0, label: "SR L", color: .purple)
                ButtonIndicator(isPressed: rightButtons & 0x002000 != 0, label: "SL R", color: .blue)
                ButtonIndicator(isPressed: rightButtons & 0x001000 != 0, label: "SR R", color: .blue)
            }
        }
        .padding(14)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var systemButtons: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("System Buttons")
                .font(.headline)

            HStack(spacing: 12) {
                ButtonIndicator(isPressed: leftButtons & 0x0100 != 0, label: "−", color: .gray)
                ButtonIndicator(isPressed: rightButtons & 0x000002 != 0, label: "+", color: .gray)
                ButtonIndicator(isPressed: leftButtons & 0x2000 != 0, label: "CAP", color: .gray)
                ButtonIndicator(isPressed: rightButtons & 0x000010 != 0, label: "HOME", color: .gray)
                ButtonIndicator(isPressed: leftButtons & 0x0800 != 0, label: "L3", color: .gray)
                ButtonIndicator(isPressed: rightButtons & 0x000004 != 0, label: "R3", color: .gray)
            }
        }
        .padding(14)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var connectionSummary: String {
        let left = leftController.map { "L \($0.packetCount)" } ?? "L missing"
        let right = rightController.map { "R \($0.packetCount)" } ?? "R missing"
        return "\(left) · \(right)"
    }
}

private struct ShoulderGroup: View {
    let title: String
    let primaryLabel: String
    let primaryPressed: Bool
    let secondaryLabel: String
    let secondaryPressed: Bool
    let triggerValue: UInt8

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)

            HStack(spacing: 12) {
                ButtonIndicator(isPressed: primaryPressed, label: primaryLabel, color: .purple)
                ButtonIndicator(isPressed: secondaryPressed, label: secondaryLabel, color: .purple)
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Analog")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(triggerValue)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                ProgressView(value: Double(triggerValue), total: 255)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
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
                    // UI-only axis remap. Y needed flipping on its own —
                    // the decoder emits joycon2cpp's `-y * 32767`, which
                    // games/DS4 want but which the SwiftUI screen-space
                    // rendered upside down. X is already correct as-is:
                    // tilt right → outX positive → dot offsets right.
                    // Keeping this comment because I broke this twice by
                    // negating X "to be consistent".
                    .offset(
                        x: CGFloat(x) / 32767 * 42,
                        y: CGFloat(y) / 32767 * 42
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
            .font(.system(size: label.count > 3 ? 10 : 13, weight: .semibold))
            .foregroundColor(isPressed ? .white : .secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(width: 38, height: 38)
            .background(isPressed ? color : Color.secondary.opacity(0.18))
            .clipShape(Circle())
    }
}

#Preview {
    GamepadView()
        .environmentObject(DaemonBridge.shared)
        .frame(width: 800, height: 600)
}
