import SwiftUI

struct GyroView: View {
    @EnvironmentObject var daemonBridge: DaemonBridge

    var body: some View {
        Group {
            if daemonBridge.controllers.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 18) {
                        ForEach(daemonBridge.controllers) { controller in
                            GyroPanel(controller: controller)
                        }
                    }
                    .padding(20)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "gyroscope")
                .font(.system(size: 48, weight: .medium))
                .foregroundColor(.secondary)
            Text("No Controller Connected")
                .font(.title3)
                .fontWeight(.semibold)
            Text("The gyro and accelerometer streams light up as soon as a Joy-Con starts sending IMU packets.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct GyroPanel: View {
    @ObservedObject var controller: Controller

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: controller.side == "right" ? "r.circle.fill" : "l.circle.fill")
                    .foregroundColor(controller.side == "right" ? .red : .blue)
                Text(controller.name)
                    .font(.headline)
                Spacer()
                Text("Packets \(controller.packetCount)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Gyroscope (°/s)")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                HStack(spacing: 20) {
                    MotionBar(label: "Pitch X", value: controller.gyroX, range: -360...360, color: .red)
                    MotionBar(label: "Roll Y", value: controller.gyroY, range: -360...360, color: .green)
                    MotionBar(label: "Yaw Z", value: controller.gyroZ, range: -360...360, color: .blue)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("Accelerometer (G)")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                HStack(spacing: 20) {
                    MotionBar(label: "X", value: controller.accelX, range: -2...2, color: .red)
                    MotionBar(label: "Y", value: controller.accelY, range: -2...2, color: .green)
                    MotionBar(label: "Z", value: controller.accelZ, range: -2...2, color: .blue)
                }
            }

            Divider()

            Rectangle3D(pitch: controller.gyroX, roll: controller.gyroY, yaw: controller.gyroZ)
                .frame(maxWidth: .infinity, minHeight: 180, maxHeight: 220)
        }
        .padding(16)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

private struct MotionBar: View {
    let label: String
    let value: Double
    let range: ClosedRange<Double>
    let color: Color

    private var normalized: Double {
        let clamped = max(range.lowerBound, min(range.upperBound, value))
        return (clamped - range.lowerBound) / (range.upperBound - range.lowerBound)
    }

    var body: some View {
        VStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.2))
                    .frame(height: 18)
                Rectangle()
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 1, height: 18)
                    .offset(x: 100)
                Circle()
                    .fill(color)
                    .frame(width: 14, height: 14)
                    .offset(x: max(0, min(188, normalized * 188)))
            }
            .frame(maxWidth: 200)
            Text(String(format: "%.1f", value))
                .font(.caption2)
                .foregroundColor(.secondary)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
    }
}

// Lightweight 3D orientation preview that updates smoothly.
private struct Rectangle3D: View {
    let pitch: Double
    let roll: Double
    let yaw: Double

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(
                    LinearGradient(
                        colors: [.blue, .purple],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 110, height: 190)
                .rotation3DEffect(.degrees(pitch / 8), axis: (x: 1, y: 0, z: 0))
                .rotation3DEffect(.degrees(roll / 8), axis: (x: 0, y: 1, z: 0))
                .rotation3DEffect(.degrees(yaw / 8), axis: (x: 0, y: 0, z: 1))
                .shadow(radius: 8)
            Text("↑")
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(.white.opacity(0.8))
                .offset(y: -70)
                .rotation3DEffect(.degrees(pitch / 8), axis: (x: 1, y: 0, z: 0))
                .rotation3DEffect(.degrees(roll / 8), axis: (x: 0, y: 1, z: 0))
                .rotation3DEffect(.degrees(yaw / 8), axis: (x: 0, y: 0, z: 1))
        }
    }
}

#Preview {
    GyroView()
        .environmentObject(DaemonBridge.shared)
        .frame(width: 800, height: 600)
}
