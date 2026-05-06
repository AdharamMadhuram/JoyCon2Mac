import SwiftUI

struct MouseView: View {
    @EnvironmentObject var daemonBridge: DaemonBridge

    // UI-only sliders. These are cosmetic — the daemon hard-codes the
    // joycon2cpp sensitivity values (1.0 / 0.6 / 0.3). Keeping them here
    // so the settings screen doesn't look empty; they aren't wired to the
    // daemon yet.
    @State private var slowSensitivity: Double = 0.3
    @State private var normalSensitivity: Double = 0.6
    @State private var fastSensitivity: Double = 1.0
    @State private var scrollSpeed: Double = 1.0

    private var leftController: ControllerState? {
        daemonBridge.controllers.first(where: { $0.side == "left" })
    }
    private var rightController: ControllerState? {
        daemonBridge.controllers.first(where: { $0.side == "right" })
    }
    // Source / mode live on the first controller. Any controller works —
    // the daemon is the authority, the `controllers[*].mouseSource` field
    // is just a mirror and both rows get updated together when the user
    // changes the picker.
    private var mouseMode: MouseMode {
        daemonBridge.controllers.first?.mouseMode ?? .off
    }
    private var mouseSource: MouseSource {
        daemonBridge.controllers.first?.mouseSource ?? .auto
    }
    private var activeSide: String {
        daemonBridge.controllers.first?.mouseActiveSide ?? "right"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                Divider()
                modePicker

                Divider()
                sourcePicker

                Divider()
                sensitivitySliders

                Divider()
                buttonMapping

                Divider()
                testArea

                Spacer()
            }
            .padding()
        }
    }

    private var header: some View {
        HStack {
            Text("Mouse Configuration")
                .font(.title)
                .fontWeight(.bold)

            Spacer()

            Button(action: {
                daemonBridge.toggleMouseMode()
            }) {
                HStack {
                    Image(systemName: "computermouse.fill")
                    Text("Cycle Mode")
                }
            }
            .buttonStyle(.bordered)
        }
    }

    private var modePicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Mouse Mode")
                .font(.headline)

            // Binding goes directly through setMouseMode() which forwards
            // to the daemon's control channel. Picker tag ordering matches
            // the daemon-authoritative enum (OFF / FAST / NORMAL / SLOW).
            Picker("Mode", selection: Binding<MouseMode>(
                get: { mouseMode },
                set: { daemonBridge.setMouseMode($0) }
            )) {
                Text("Off").tag(MouseMode.off)
                Text("Slow").tag(MouseMode.slow)
                Text("Normal").tag(MouseMode.normal)
                Text("Fast").tag(MouseMode.fast)
            }
            .pickerStyle(.segmented)

            Text("Press Chat (C) on the Right Joy-Con to cycle modes, or use the segmented control above.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var sourcePicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Mouse Source")
                    .font(.headline)
                Spacer()
                // Active-side pill. Shows which Joy-Con is currently being
                // used as the mouse right now (in Auto it flips whenever the
                // other one is placed on a surface).
                Text("Active: \(activeSide.capitalized)")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(activeSide == "left" ? Color.blue.opacity(0.2) : Color.green.opacity(0.2))
                    .clipShape(Capsule())
            }

            Picker("Source", selection: Binding<MouseSource>(
                get: { mouseSource },
                set: { daemonBridge.setMouseSource($0) }
            )) {
                Text("Auto").tag(MouseSource.auto)
                Text("Left Joy-Con").tag(MouseSource.left)
                Text("Right Joy-Con").tag(MouseSource.right)
            }
            .pickerStyle(.segmented)

            Text("Auto picks whichever Joy-Con is resting on a surface (distance > 0). Switch sides any time without unpairing — the optical baseline resets on every switch so the cursor won't jump.")
                .font(.caption)
                .foregroundColor(.secondary)

            // Per-side surface read-out. distance>0 means the optical
            // sensor has a surface lock (typical ~12). distance==0 means
            // the Joy-Con is lifted / no lock. Auto adopts whichever has
            // distance > 0 consistently.
            HStack(spacing: 14) {
                surfaceBadge(side: "left", distance: leftController?.mouseDistance ?? 0)
                surfaceBadge(side: "right", distance: rightController?.mouseDistance ?? 0)
            }
        }
    }

    private func surfaceBadge(side: String, distance: Int16) -> some View {
        // Byte 0x17 reads non-zero (~12) when the optical sensor has a
        // surface lock, and 0 when it can't see a surface. Verified on
        // hardware: Joy-Con placed on a table reads d=12, lifted reads
        // d=0.
        let onSurface = distance > 0
        let isActive = activeSide == side
        return HStack(spacing: 6) {
            Circle()
                .fill(onSurface ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 9, height: 9)
            Text("\(side.capitalized) · \(onSurface ? "on surface" : "airborne")")
                .font(.caption)
            Text("(d=\(distance))")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(isActive ? Color.accentColor.opacity(0.15) : Color(NSColor.controlBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isActive ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: isActive ? 1.5 : 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var sensitivitySliders: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Sensitivity (UI only — daemon uses joycon2cpp presets)")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                sliderRow(label: "Slow Mode",   value: $slowSensitivity,   range: 0.1...1.0)
                sliderRow(label: "Normal Mode", value: $normalSensitivity, range: 0.1...2.0)
                sliderRow(label: "Fast Mode",   value: $fastSensitivity,   range: 0.5...3.0)
                sliderRow(label: "Scroll Speed",value: $scrollSpeed,       range: 0.5...3.0)
            }
        }
    }

    private func sliderRow(label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(label).frame(width: 110, alignment: .leading)
            Slider(value: value, in: range, step: 0.1)
            Text("\(value.wrappedValue, specifier: "%.1f")x").frame(width: 50, alignment: .trailing)
        }
    }

    private var buttonMapping: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Button Mapping")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                // Mapping depends on which side is the active mouse.
                // joycon2cpp's right layout: R = Left-click, ZR = Right-click, R3 = Middle-click.
                // Matching left layout: L = Left, ZL = Right, L3 = Middle.
                let isLeftMouse = activeSide == "left"
                mappingRow(from: isLeftMouse ? "L"   : "R",   to: "Left Click")
                mappingRow(from: isLeftMouse ? "ZL"  : "ZR",  to: "Right Click")
                mappingRow(from: isLeftMouse ? "L3"  : "R3",  to: "Middle Click")
                mappingRow(from: "Joystick Y", to: "Scroll Wheel")
                mappingRow(from: "Joystick X ± edge", to: "Forward / Back")
            }
        }
    }

    private func mappingRow(from source: String, to target: String) -> some View {
        HStack {
            Text(source).frame(width: 160, alignment: .leading)
            Image(systemName: "arrow.right").foregroundColor(.secondary)
            Text(target).foregroundColor(.blue)
        }
    }

    private var testArea: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Mouse Test Area")
                .font(.headline)

            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(NSColor.controlBackgroundColor))
                    .frame(height: 200)

                // Show the ACTIVE side's optical readout, not just
                // controllers.first which was previously pinned to Left.
                let active = activeSide == "left" ? leftController : rightController
                if let c = active {
                    VStack(spacing: 8) {
                        Text("Optical Sensor · \(activeSide.capitalized)")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        HStack(spacing: 20) {
                            opticalCell(label: "ΔX", value: "\(c.mouseX)")
                            opticalCell(label: "ΔY", value: "\(c.mouseY)")
                            opticalCell(label: "Distance", value: "\(c.mouseDistance)")
                        }

                        Text("Move the active Joy-Con over a surface to test.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else {
                    Text("No controller connected")
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private func opticalCell(label: String, value: String) -> some View {
        VStack {
            Text(label).font(.caption)
            Text(value).font(.title2).monospacedDigit()
        }
    }
}

#Preview {
    MouseView()
        .environmentObject(DaemonBridge.shared)
        .frame(width: 800, height: 600)
}
