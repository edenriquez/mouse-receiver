import SwiftUI
import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var popover: NSPopover?
    let appState = AppState()
    private var statusTimer: Timer?
    private let edgeGlowPanel = EdgeGlowPanel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "cursorarrow.motionlines", accessibilityDescription: "MousePortal")
            button.image?.size = NSSize(width: 16, height: 16)
            button.imagePosition = .imageLeading
            button.action = #selector(togglePopover)
            button.target = self
        }

        // Popover
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        let hosting = NSHostingController(rootView: PairingView(appState: appState))
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
        self.popover = popover

        // Edge glow overlay — progressive fade-in as cursor approaches screen edge
        appState.onEdgeGlowUpdate = { [weak self] proximity, rightEdge in
            self?.edgeGlowPanel.update(proximity: proximity, rightEdge: rightEdge)
        }

        // Periodically update menu bar appearance
        statusTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.updateStatusItem()
            if self?.appState.connectionStatus == .disconnected {
                self?.edgeGlowPanel.hide()
            }
        }
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        switch appState.connectionStatus {
        case .disconnected:
            button.title = ""
            button.contentTintColor = nil
        case .connecting:
            button.title = " Connecting"
            button.contentTintColor = .systemOrange
        case .connected:
            button.title = " Connected"
            button.contentTintColor = .systemGreen
        case .forwarding:
            button.title = " Forwarding"
            button.contentTintColor = .systemBlue
        }
    }

    @objc func togglePopover() {
        guard let popover = popover, let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
