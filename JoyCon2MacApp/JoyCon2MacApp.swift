import SwiftUI
import AppKit

@main
struct JoyCon2MacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var daemonBridge = DaemonBridge.shared

    var body: some Scene {
        WindowGroup {
            MainWindow()
                .environmentObject(daemonBridge)
                .frame(minWidth: 960, minHeight: 640)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            SettingsView()
                .environmentObject(daemonBridge)
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var daemonBridge: DaemonBridge? = DaemonBridge.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "gamecontroller.fill", accessibilityDescription: "JoyCon2Mac")
            button.action = #selector(togglePopover)
            button.target = self
        }

        setupMenu()

        daemonBridge = DaemonBridge.shared
        activateBundledDriver()
    }

    private func activateBundledDriver() {
        DriverExtensionInstaller.shared.activate { status, shouldRestartDaemon in
            DispatchQueue.main.async {
                TelemetryStore.shared.updateDriverStatus(status)
                if shouldRestartDaemon {
                    DaemonBridge.shared.restartDaemon()
                }
            }
        }
    }

    @objc func togglePopover() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
    }

    func setupMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show Window", action: #selector(togglePopover), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Toggle Mouse Mode", action: #selector(toggleMouseMode), keyEquivalent: "m"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem?.menu = menu
    }

    @objc func toggleMouseMode() {
        daemonBridge?.toggleMouseMode()
    }
}
