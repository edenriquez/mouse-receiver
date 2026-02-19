import AppKit
import SwiftUI

final class EdgeGlowPanel {
    private var panel: NSPanel?
    private var isRightEdge: Bool?
    private var currentEdgeX: CGFloat = 0
    private var currentWidth: CGFloat = 66

    /// Create or update the glow panel. Proximity 0→1 controls alpha (progressive fade-in).
    /// edgeX is the X coordinate of the screen boundary (used to find the correct NSScreen).
    /// velocity is 0...1 normalized edge-ward velocity for dynamic width.
    func update(proximity: CGFloat, rightEdge: Bool, edgeX: CGFloat, velocity: CGFloat) {
        if proximity > 0.01 {
            let targetWidth: CGFloat = 66 + velocity * 54  // 66pt at rest → 120pt at max velocity
            let needsRecreate = panel == nil
                || isRightEdge != rightEdge
                || abs(currentEdgeX - edgeX) > 2
                || abs(currentWidth - targetWidth) > 8
            if needsRecreate {
                createPanel(rightEdge: rightEdge, edgeX: edgeX, width: targetWidth, velocity: velocity)
            }
            panel?.alphaValue = proximity
        } else {
            panel?.alphaValue = 0
        }
    }

    /// Flash the portal on transition — light streak bridge effect.
    func showPortalSnap(rightEdge: Bool, edgeX: CGFloat) {
        createPanel(rightEdge: rightEdge, edgeX: edgeX, width: 140, velocity: 1.0)
        panel?.alphaValue = 1.0

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.4
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel?.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.panel?.alphaValue = 0
        })
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
        isRightEdge = nil
        currentEdgeX = 0
        currentWidth = 66
    }

    private func createPanel(rightEdge: Bool, edgeX: CGFloat, width: CGFloat, velocity: CGFloat) {
        hide()
        isRightEdge = rightEdge
        currentEdgeX = edgeX
        currentWidth = width

        // Find the NSScreen whose edge matches edgeX (X coordinates are same in CG and AppKit)
        let screen: NSScreen?
        if rightEdge {
            screen = NSScreen.screens.first { abs($0.frame.maxX - edgeX) < 2 }
                ?? NSScreen.screens.max(by: { $0.frame.maxX < $1.frame.maxX })
        } else {
            screen = NSScreen.screens.first { abs($0.frame.minX - edgeX) < 2 }
                ?? NSScreen.screens.min(by: { $0.frame.minX < $1.frame.minX })
        }
        guard let screen else { return }

        let frame: NSRect
        if rightEdge {
            frame = NSRect(x: screen.frame.maxX - width, y: screen.frame.minY,
                           width: width, height: screen.frame.height)
        } else {
            frame = NSRect(x: screen.frame.minX, y: screen.frame.minY,
                           width: width, height: screen.frame.height)
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

        let hostingView = NSHostingView(rootView: EdgeGlowView(rightEdge: rightEdge, velocity: velocity))
        p.contentView = hostingView
        p.orderFrontRegardless()
        panel = p
    }
}

// MARK: - Gradient View

private struct EdgeGlowView: View {
    let rightEdge: Bool
    let velocity: CGFloat   // 0...1 normalized
    @State private var breathing = false

    private let portalBlue = Color(red: 0.075, green: 0.498, blue: 0.925)

    var body: some View {
        ZStack {
            // Main gradient glow
            Rectangle()
                .fill(gradient)
                .opacity(breathing ? max(1.0, 0.7 + velocity * 0.3) : 0.7 + velocity * 0.3)
                .brightness(breathing ? 0.15 : 0)
                .shadow(color: portalBlue.opacity(0.3), radius: 20,
                        x: rightEdge ? -5 : 5, y: 0)

            // Motion trail — visible when velocity > 0.2
            if velocity > 0.2 {
                motionTrail
            }
        }
        .ignoresSafeArea()
        .onAppear {
            let duration = max(0.6, 1.5 - velocity * 0.9)
            withAnimation(.easeInOut(duration: duration).repeatForever(autoreverses: true)) {
                breathing = true
            }
        }
    }

    /// Thin bright streak extending from the edge — creates the visual "pull" toward the portal.
    private var motionTrail: some View {
        GeometryReader { geo in
            let trailWidth = velocity * 40
            HStack(spacing: 0) {
                if !rightEdge {
                    Spacer()
                }
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [portalBlue.opacity(0), portalBlue.opacity(0.8), portalBlue],
                            startPoint: rightEdge ? .leading : .trailing,
                            endPoint: rightEdge ? .trailing : .leading
                        )
                    )
                    .frame(width: trailWidth, height: 2)
                if rightEdge {
                    Spacer()
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
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
