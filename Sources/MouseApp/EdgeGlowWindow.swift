import AppKit
import SwiftUI

final class EdgeGlowPanel {
    private var panel: NSPanel?
    private var isRightEdge: Bool?

    /// Create or update the glow panel. Proximity 0→1 controls alpha (progressive fade-in).
    func update(proximity: CGFloat, rightEdge: Bool) {
        if proximity > 0.01 {
            if panel == nil || isRightEdge != rightEdge {
                createPanel(rightEdge: rightEdge)
            }
            panel?.alphaValue = proximity
        } else {
            panel?.alphaValue = 0
        }
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
        isRightEdge = nil
    }

    private func createPanel(rightEdge: Bool) {
        hide()
        isRightEdge = rightEdge

        let screen: NSScreen?
        if rightEdge {
            screen = NSScreen.screens.max(by: { $0.frame.maxX < $1.frame.maxX })
        } else {
            screen = NSScreen.screens.min(by: { $0.frame.minX < $1.frame.minX })
        }
        guard let screen else { return }

        let glowWidth: CGFloat = 66 // 50% wider than original 44
        let frame: NSRect
        if rightEdge {
            frame = NSRect(x: screen.frame.maxX - glowWidth, y: screen.frame.minY,
                           width: glowWidth, height: screen.frame.height)
        } else {
            frame = NSRect(x: screen.frame.minX, y: screen.frame.minY,
                           width: glowWidth, height: screen.frame.height)
        }

        let p = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.level = .statusBar
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        p.alphaValue = 0

        let hostingView = NSHostingView(rootView: EdgeGlowView(rightEdge: rightEdge))
        p.contentView = hostingView
        p.orderFrontRegardless()
        panel = p
    }
}

// MARK: - Gradient View

private struct EdgeGlowView: View {
    let rightEdge: Bool
    @State private var breathing = false

    private let portalBlue = Color(red: 0.075, green: 0.498, blue: 0.925)

    var body: some View {
        Rectangle()
            .fill(gradient)
            .opacity(breathing ? 1.0 : 0.7)
            .brightness(breathing ? 0.15 : 0)
            .shadow(color: portalBlue.opacity(0.3), radius: 20,
                    x: rightEdge ? -5 : 5, y: 0)
            .ignoresSafeArea()
            .onAppear {
                withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                    breathing = true
                }
            }
    }

    private var gradient: LinearGradient {
        let stops: [Gradient.Stop] = [
            .init(color: .clear, location: 0),
            .init(color: portalBlue.opacity(0.15), location: 0.25),
            .init(color: portalBlue.opacity(0.4), location: 0.55),
            .init(color: portalBlue.opacity(0.7), location: 0.8),
            .init(color: portalBlue, location: 1.0),
        ]
        if rightEdge {
            return LinearGradient(stops: stops, startPoint: .leading, endPoint: .trailing)
        } else {
            return LinearGradient(stops: stops, startPoint: .trailing, endPoint: .leading)
        }
    }
}
