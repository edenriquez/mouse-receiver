import AppKit
import SwiftUI

final class EdgeGlowPanel {
    private var panel: NSPanel?

    func show() {
        if panel != nil { return }

        guard let screen = NSScreen.screens.max(by: { $0.frame.maxX < $1.frame.maxX }) else { return }

        let glowWidth: CGFloat = 44
        let frame = NSRect(
            x: screen.frame.maxX - glowWidth,
            y: screen.frame.minY,
            width: glowWidth,
            height: screen.frame.height
        )

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

        let hostingView = NSHostingView(rootView: EdgeGlowView())
        p.contentView = hostingView
        p.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            p.animator().alphaValue = 1.0
        }

        panel = p
    }

    func hide() {
        guard let p = panel else { return }
        panel = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            p.animator().alphaValue = 0
        }, completionHandler: {
            p.orderOut(nil)
        })
    }
}

// MARK: - Gradient View

private struct EdgeGlowView: View {
    @State private var breathing = false

    private let portalBlue = Color(red: 0.075, green: 0.498, blue: 0.925)

    var body: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: portalBlue.opacity(0.15), location: 0.25),
                        .init(color: portalBlue.opacity(0.4), location: 0.55),
                        .init(color: portalBlue.opacity(0.7), location: 0.8),
                        .init(color: portalBlue, location: 1.0),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .opacity(breathing ? 1.0 : 0.7)
            .brightness(breathing ? 0.15 : 0)
            .shadow(color: portalBlue.opacity(0.3), radius: 20, x: -5, y: 0)
            .ignoresSafeArea()
            .onAppear {
                withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                    breathing = true
                }
            }
    }
}
