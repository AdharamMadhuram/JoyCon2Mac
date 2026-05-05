import SwiftUI

struct MouseView: View {
    @EnvironmentObject var daemonBridge: DaemonBridge
    @State private var selectedMode: MouseMode = .normal
    @State private var slowSensitivity: Double = 0.3
    @State private var normalSensitivity: Double = 0.6
    @State private var fastSensitivity: Double = 1.2
    @State private var scrollSpeed: Double = 1.0
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header
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
                            Text("Toggle Mode")
                        }
                    }
                    .buttonStyle(.bordered)
                }
                
                Divider()
                
                // Mode selector
                VStack(alignment: .leading, spacing: 12) {
                    Text("Mouse Mode")
                        .font(.headline)
                    
                    Picker("Mode", selection: $selectedMode) {
                        Text("Off").tag(MouseMode.off)
                        Text("Slow").tag(MouseMode.slow)
                        Text("Normal").tag(MouseMode.normal)
                        Text("Fast").tag(MouseMode.fast)
                    }
                    .pickerStyle(.segmented)
                    
                    Text("Press the Capture button on your Joy-Con to toggle modes")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Divider()
                
                // Sensitivity sliders
                VStack(alignment: .leading, spacing: 20) {
                    Text("Sensitivity Settings")
                        .font(.headline)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Slow Mode")
                                .frame(width: 100, alignment: .leading)
                            
                            Slider(value: $slowSensitivity, in: 0.1...1.0, step: 0.1)
                            
                            Text("\(slowSensitivity, specifier: "%.1f")x")
                                .frame(width: 50, alignment: .trailing)
                                
                        }
                        
                        HStack {
                            Text("Normal Mode")
                                .frame(width: 100, alignment: .leading)
                            
                            Slider(value: $normalSensitivity, in: 0.1...2.0, step: 0.1)
                            
                            Text("\(normalSensitivity, specifier: "%.1f")x")
                                .frame(width: 50, alignment: .trailing)
                                
                        }
                        
                        HStack {
                            Text("Fast Mode")
                                .frame(width: 100, alignment: .leading)
                            
                            Slider(value: $fastSensitivity, in: 0.5...3.0, step: 0.1)
                            
                            Text("\(fastSensitivity, specifier: "%.1f")x")
                                .frame(width: 50, alignment: .trailing)
                                
                        }
                        
                        HStack {
                            Text("Scroll Speed")
                                .frame(width: 100, alignment: .leading)
                            
                            Slider(value: $scrollSpeed, in: 0.5...3.0, step: 0.1)
                            
                            Text("\(scrollSpeed, specifier: "%.1f")x")
                                .frame(width: 50, alignment: .trailing)
                                
                        }
                    }
                }
                
                Divider()
                
                // Button mapping
                VStack(alignment: .leading, spacing: 12) {
                    Text("Button Mapping")
                        .font(.headline)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("L Button")
                                .frame(width: 120, alignment: .leading)
                            
                            Image(systemName: "arrow.right")
                                .foregroundColor(.secondary)
                            
                            Text("Left Click")
                                .foregroundColor(.blue)
                        }
                        
                        HStack {
                            Text("ZL Button")
                                .frame(width: 120, alignment: .leading)
                            
                            Image(systemName: "arrow.right")
                                .foregroundColor(.secondary)
                            
                            Text("Right Click")
                                .foregroundColor(.blue)
                        }
                        
                        HStack {
                            Text("Stick Click")
                                .frame(width: 120, alignment: .leading)
                            
                            Image(systemName: "arrow.right")
                                .foregroundColor(.secondary)
                            
                            Text("Middle Click")
                                .foregroundColor(.blue)
                        }
                        
                        HStack {
                            Text("Joystick Y-Axis")
                                .frame(width: 120, alignment: .leading)
                            
                            Image(systemName: "arrow.right")
                                .foregroundColor(.secondary)
                            
                            Text("Scroll Wheel")
                                .foregroundColor(.blue)
                        }
                    }
                }
                
                Divider()
                
                // Test area
                VStack(alignment: .leading, spacing: 12) {
                    Text("Mouse Test Area")
                        .font(.headline)
                    
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(NSColor.controlBackgroundColor))
                            .frame(height: 200)
                        
                        if let controller = daemonBridge.controllers.first {
                            VStack(spacing: 8) {
                                Text("Optical Sensor")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                
                                HStack(spacing: 20) {
                                    VStack {
                                        Text("ΔX")
                                            .font(.caption)
                                        Text("\(controller.mouseX)")
                                            .font(.title2)
                                            
                                    }
                                    
                                    VStack {
                                        Text("ΔY")
                                            .font(.caption)
                                        Text("\(controller.mouseY)")
                                            .font(.title2)
                                            
                                    }
                                    
                                    VStack {
                                        Text("Distance")
                                            .font(.caption)
                                        Text("\(controller.mouseDistance)")
                                            .font(.title2)
                                            
                                    }
                                }
                                
                                Text("Move Joy-Con over a surface to test")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } else {
                            Text("No controller connected")
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                Spacer()
            }
            .padding()
        }
    }
}

#Preview {
    MouseView()
        .environmentObject(DaemonBridge.shared)
        .frame(width: 800, height: 600)
}
