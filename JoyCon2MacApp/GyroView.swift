import SwiftUI
import SceneKit

struct GyroView: View {
    @EnvironmentObject var daemonBridge: DaemonBridge
    @State private var showRawValues = false
    
    var controller: ControllerState? {
        daemonBridge.controllers.first
    }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Header
                HStack {
                    Text("Motion Sensors")
                        .font(.title)
                        .fontWeight(.bold)
                    
                    Spacer()
                    
                    Toggle("Show Raw Values", isOn: $showRawValues)
                }
                
                Divider()
                
                if let controller = controller {
                    // 3D Visualization
                    VStack(alignment: .leading, spacing: 12) {
                        Text("3D Orientation")
                            .font(.headline)
                        
                        ZStack {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color(NSColor.controlBackgroundColor))
                                .frame(height: 300)
                            
                            // Simple 3D representation using rotation
                            JoyConModel(
                                pitch: controller.gyroX,
                                roll: controller.gyroY,
                                yaw: controller.gyroZ
                            )
                            .frame(height: 280)
                        }
                    }
                    
                    Divider()
                    
                    // Gyroscope
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Gyroscope (°/s)")
                            .font(.headline)
                        
                        HStack(spacing: 40) {
                            MotionBar(
                                label: "Pitch (X)",
                                value: controller.gyroX,
                                range: -360...360,
                                color: .red
                            )
                            
                            MotionBar(
                                label: "Roll (Y)",
                                value: controller.gyroY,
                                range: -360...360,
                                color: .green
                            )
                            
                            MotionBar(
                                label: "Yaw (Z)",
                                value: controller.gyroZ,
                                range: -360...360,
                                color: .blue
                            )
                        }
                    }
                    
                    Divider()
                    
                    // Accelerometer
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Accelerometer (G)")
                            .font(.headline)
                        
                        HStack(spacing: 40) {
                            MotionBar(
                                label: "X",
                                value: controller.accelX,
                                range: -2...2,
                                color: .red
                            )
                            
                            MotionBar(
                                label: "Y",
                                value: controller.accelY,
                                range: -2...2,
                                color: .green
                            )
                            
                            MotionBar(
                                label: "Z",
                                value: controller.accelZ,
                                range: -2...2,
                                color: .blue
                            )
                        }
                    }
                    
                    if showRawValues {
                        Divider()
                        
                        // Raw values
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Raw Values")
                                .font(.headline)
                            
                            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                                GridRow {
                                    Text("Gyro X:")
                                        .foregroundColor(.secondary)
                                    Text("\(controller.gyroX, specifier: "%.2f")°/s")
                                        
                                }
                                
                                GridRow {
                                    Text("Gyro Y:")
                                        .foregroundColor(.secondary)
                                    Text("\(controller.gyroY, specifier: "%.2f")°/s")
                                        
                                }
                                
                                GridRow {
                                    Text("Gyro Z:")
                                        .foregroundColor(.secondary)
                                    Text("\(controller.gyroZ, specifier: "%.2f")°/s")
                                        
                                }
                                
                                GridRow {
                                    Text("")
                                    Text("")
                                }
                                
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
                // Background
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.2))
                    .frame(width: 200, height: 20)
                
                // Center line
                Rectangle()
                    .fill(Color.secondary.opacity(0.5))
                    .frame(width: 1, height: 20)
                    .offset(x: 100)
                
                // Value indicator
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

struct JoyConModel: View {
    let pitch: Double
    let roll: Double
    let yaw: Double
    
    var body: some View {
        ZStack {
            // Simple 2D representation of 3D rotation
            RoundedRectangle(cornerRadius: 20)
                .fill(
                    LinearGradient(
                        colors: [.blue, .blue.opacity(0.6)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 100, height: 200)
                .rotation3DEffect(
                    .degrees(pitch / 5),
                    axis: (x: 1, y: 0, z: 0)
                )
                .rotation3DEffect(
                    .degrees(roll / 5),
                    axis: (x: 0, y: 1, z: 0)
                )
                .rotation3DEffect(
                    .degrees(yaw / 5),
                    axis: (x: 0, y: 0, z: 1)
                )
                .shadow(radius: 10)
            
            // Orientation indicators
            VStack {
                Text("↑")
                    .font(.title)
                    .foregroundColor(.white)
                Spacer()
            }
            .frame(width: 100, height: 200)
            .rotation3DEffect(
                .degrees(pitch / 5),
                axis: (x: 1, y: 0, z: 0)
            )
            .rotation3DEffect(
                .degrees(roll / 5),
                axis: (x: 0, y: 1, z: 0)
            )
            .rotation3DEffect(
                .degrees(yaw / 5),
                axis: (x: 0, y: 0, z: 1)
            )
        }
    }
}

#Preview {
    GyroView()
        .environmentObject(DaemonBridge.shared)
        .frame(width: 800, height: 600)
}
