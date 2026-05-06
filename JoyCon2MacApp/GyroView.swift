import SwiftUI

// Joy-Con axis convention (from joycon2cpp README + Nintendo HID docs).
// Looking at a Joy-Con held upright with the SR/SL rail on the right side:
//
//   +X  points along the long axis of the controller (up, toward SR/SL).
//   +Y  points across the rail (right, away from the rail side).
//   +Z  points out of the face (toward the user).
//
// So when the Joy-Con sits flat face-up on a table:
//   accel ≈ (0, 0, +1 G)
// If you tilt the top of the controller forward (pitch down toward you):
//   gyro X briefly goes negative, accel X trends toward -1 G.
// If you roll it to the right (rail goes down):
//   gyro Y briefly goes positive, accel Y trends toward +1 G.
//
// The previous GyroView used angular velocity as if it were orientation,
// which is why the 3D cube only flicked and then snapped back. Real
// orientation needs integration of gyro + a gravity correction from accel.
// We use a small complementary filter on the main thread — tiny state,
// no heavyweight math library needed.

struct GyroView: View {
    @EnvironmentObject var daemonBridge: DaemonBridge
    @State private var showRawValues = false

    var controller: ControllerState? {
        daemonBridge.controllers.first
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                HStack {
                    Text("Motion Sensors")
                        .font(.title)
                        .fontWeight(.bold)
                    Spacer()
                    Toggle("Show Raw Values", isOn: $showRawValues)
                }

                Divider()

                if let controller = controller {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("3D Orientation")
                            .font(.headline)

                        ZStack {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color(NSColor.controlBackgroundColor))
                                .frame(height: 300)

                            JoyConOrientationView(
                                accelX: controller.accelX,
                                accelY: controller.accelY,
                                accelZ: controller.accelZ,
                                gyroX: controller.gyroX,
                                gyroY: controller.gyroY,
                                gyroZ: controller.gyroZ
                            )
                            .frame(height: 280)
                        }
                    }

                    Divider()

                    // Label gyro axes by the physical motion each represents
                    // for an upright Joy-Con. Pitch = rotation around X
                    // (tilt top forward/back), Roll = around Y (tilt rail
                    // side up/down), Yaw = around Z (spin on table).
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Gyroscope (°/s)")
                            .font(.headline)

                        HStack(spacing: 40) {
                            MotionBar(label: "Pitch (X)",
                                      value: controller.gyroX,
                                      range: -360...360, color: .red)
                            MotionBar(label: "Roll (Y)",
                                      value: controller.gyroY,
                                      range: -360...360, color: .green)
                            MotionBar(label: "Yaw (Z)",
                                      value: controller.gyroZ,
                                      range: -360...360, color: .blue)
                        }
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 16) {
                        Text("Accelerometer (G)")
                            .font(.headline)

                        HStack(spacing: 40) {
                            MotionBar(label: "X", value: controller.accelX,
                                      range: -2...2, color: .red)
                            MotionBar(label: "Y", value: controller.accelY,
                                      range: -2...2, color: .green)
                            MotionBar(label: "Z", value: controller.accelZ,
                                      range: -2...2, color: .blue)
                        }
                    }

                    if showRawValues {
                        Divider()
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Raw Values")
                                .font(.headline)

                            Grid(alignment: .leading,
                                 horizontalSpacing: 20, verticalSpacing: 8) {
                                GridRow {
                                    Text("Gyro X (pitch rate):")
                                        .foregroundColor(.secondary)
                                    Text("\(controller.gyroX, specifier: "%.2f")°/s")
                                }
                                GridRow {
                                    Text("Gyro Y (roll rate):")
                                        .foregroundColor(.secondary)
                                    Text("\(controller.gyroY, specifier: "%.2f")°/s")
                                }
                                GridRow {
                                    Text("Gyro Z (yaw rate):")
                                        .foregroundColor(.secondary)
                                    Text("\(controller.gyroZ, specifier: "%.2f")°/s")
                                }
                                GridRow { Text("") ; Text("") }
                                GridRow {
                                    Text("Accel X:")
                                        .foregroundColor(.secondary)
                                    Text("\(controller.accelX, specifier: "%.3f")G")
                                }
                                GridRow {
                                    Text("Accel Y:")
                                        .foregroundColor(.secondary)
                                    Text("\(controller.accelY, specifier: "%.3f")G")
                                }
                                GridRow {
                                    Text("Accel Z:")
                                        .foregroundColor(.secondary)
                                    Text("\(controller.accelZ, specifier: "%.3f")G")
                                }
                            }
                            .padding()
                            .background(Color(NSColor.controlBackgroundColor))
                            .cornerRadius(8)
                        }
                    }
                } else {
                    VStack(spacing: 20) {
                        Image(systemName: "gyroscope")
                            .font(.system(size: 64))
                            .foregroundColor(.secondary)
                        Text("No Controller Connected")
                            .font(.title2)
                    }
                    .frame(height: 400)
                }

                Spacer()
            }
            .padding()
        }
    }
}

struct MotionBar: View {
    let label: String
    let value: Double
    let range: ClosedRange<Double>
    let color: Color

    var normalizedValue: Double {
        let clamped = max(range.lowerBound, min(range.upperBound, value))
        return (clamped - range.lowerBound) / (range.upperBound - range.lowerBound)
    }

    var body: some View {
        VStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.2))
                    .frame(width: 200, height: 20)

                Rectangle()
                    .fill(Color.secondary.opacity(0.5))
                    .frame(width: 1, height: 20)
                    .offset(x: 100)

                Circle()
                    .fill(color)
                    .frame(width: 16, height: 16)
                    .offset(x: normalizedValue * 200 - 8)
            }

            Text("\(value, specifier: "%.2f")")
                .font(.caption)
        }
    }
}

// MARK: - Orientation visualiser
//
// Why this is its own view: we need persistent state (accumulated roll /
// pitch / yaw) across frames, plus a baseline timestamp for gyro
// integration. Using @State directly on GyroView would mean the filter
// restarts every time the parent re-renders, which at 20 Hz is every
// frame. Keeping it local here lets SwiftUI re-render the cheap container
// without touching the filter state.

private final class OrientationFilter: ObservableObject {
    // Euler angles the cube is currently drawn at, in degrees.
    @Published var pitch: Double = 0
    @Published var roll: Double = 0
    @Published var yaw: Double = 0

    private var lastTimestamp: TimeInterval?

    // Complementary filter weight. Accelerometer is the long-term truth for
    // pitch + roll, gyro is the short-term truth. 0.98 gyro / 0.02 accel
    // keeps the cube smooth while still correcting drift within a second
    // or two. Yaw has no gravity reference, so it's pure gyro integration
    // and will drift — that's expected for a 6-axis IMU.
    private let alpha: Double = 0.98

    func update(accelX: Double, accelY: Double, accelZ: Double,
                gyroX: Double, gyroY: Double, gyroZ: Double) {
        let now = CACurrentMediaTime()
        let dt: Double
        if let last = lastTimestamp {
            dt = min(0.1, max(0.0, now - last))
        } else {
            dt = 0.0
        }
        lastTimestamp = now

        // Gyro readings are °/s in the Joy-Con body frame. Integrate
        // directly — small-angle assumption is fine at 20 Hz refresh.
        let gyroPitch = pitch + gyroX * dt
        let gyroRoll  = roll  + gyroY * dt
        let gyroYaw   = yaw   + gyroZ * dt

        // Derive pitch + roll from the gravity vector.
        //   pitch = atan2(-accelY, sqrt(accelX^2 + accelZ^2))
        //   roll  = atan2( accelX, accelZ)
        // converted to degrees. These match the joycon2cpp body frame where
        // +Z is out of the face and +X is up the long axis.
        let magnitude = sqrt(accelX * accelX + accelY * accelY + accelZ * accelZ)
        if magnitude > 0.25 && magnitude < 4.0 {
            let accPitch = atan2(-accelY, sqrt(accelX * accelX + accelZ * accelZ)) * 180.0 / .pi
            let accRoll  = atan2(accelX, accelZ) * 180.0 / .pi
            pitch = alpha * gyroPitch + (1.0 - alpha) * accPitch
            roll  = alpha * gyroRoll  + (1.0 - alpha) * accRoll
        } else {
            // Controller is in free-fall or measurement is junk; fall back
            // to pure gyro for this tick.
            pitch = gyroPitch
            roll  = gyroRoll
        }
        yaw = gyroYaw
    }
}

struct JoyConOrientationView: View {
    let accelX: Double
    let accelY: Double
    let accelZ: Double
    let gyroX: Double
    let gyroY: Double
    let gyroZ: Double

    @StateObject private var filter = OrientationFilter()

    var body: some View {
        // Apply rotations without implicit animations. The previous crash
        // was a dangling NSWindowTransformAnimation when the window closed
        // mid-animation — at 20 Hz we want the new value to draw directly,
        // not animate to it.
        ZStack {
            RoundedRectangle(cornerRadius: 20)
                .fill(
                    LinearGradient(
                        colors: [.blue, .blue.opacity(0.6)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 100, height: 200)
                .overlay(
                    VStack {
                        Text("↑")
                            .font(.title)
                            .foregroundColor(.white)
                        Spacer()
                    }
                    .frame(width: 100, height: 200)
                )
                .shadow(radius: 10)
                .rotation3DEffect(.degrees(filter.pitch),
                                  axis: (x: 1, y: 0, z: 0))
                .rotation3DEffect(.degrees(-filter.roll),
                                  axis: (x: 0, y: 1, z: 0))
                .rotation3DEffect(.degrees(filter.yaw),
                                  axis: (x: 0, y: 0, z: 1))
                .animation(nil, value: filter.pitch)
                .animation(nil, value: filter.roll)
                .animation(nil, value: filter.yaw)
        }
        .onChange(of: gyroX) { _ in updateFilter() }
        .onChange(of: gyroY) { _ in updateFilter() }
        .onChange(of: gyroZ) { _ in updateFilter() }
        .onChange(of: accelX) { _ in updateFilter() }
        .onChange(of: accelY) { _ in updateFilter() }
        .onChange(of: accelZ) { _ in updateFilter() }
    }

    private func updateFilter() {
        filter.update(accelX: accelX, accelY: accelY, accelZ: accelZ,
                      gyroX: gyroX, gyroY: gyroY, gyroZ: gyroZ)
    }
}

#Preview {
    GyroView()
        .environmentObject(DaemonBridge.shared)
        .frame(width: 800, height: 600)
}
