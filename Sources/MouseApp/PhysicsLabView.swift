import SwiftUI

private let accentBlue = Color(red: 0.075, green: 0.498, blue: 0.925)

// MARK: - Physics Lab View

struct PhysicsLabView: View {
    let appState: AppState
    var onBack: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            thinDivider
            simulationViewport
            thinDivider
            controlsSection
            thinDivider
            footer
        }
        .frame(width: 260)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            Image(systemName: "atom")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(accentBlue)

            Text("Physics Lab")
                .font(.system(size: 13, weight: .bold))

            Spacer()

            modePicker
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var modePicker: some View {
        Menu {
            ForEach(TransitionMode.allCases, id: \.self) { mode in
                Button(action: { appState.transitionPhysics.mode = mode }) {
                    HStack {
                        Text(mode.rawValue.capitalized)
                        if appState.transitionPhysics.mode == mode {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(appState.transitionPhysics.mode.rawValue.capitalized)
                    .font(.system(size: 9, weight: .semibold))
                    .textCase(.uppercase)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
            }
            .foregroundStyle(accentBlue)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(accentBlue.opacity(0.1))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Simulation Viewport

    private var simulationViewport: some View {
        SimulationCanvas(
            mode: appState.transitionPhysics.mode,
            velocity: appState.cursorVelocity
        )
        .frame(height: 120)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    // MARK: - Controls

    private var controlsSection: some View {
        VStack(spacing: 8) {
            PhysicsSlider(
                label: "Spring Stiffness",
                value: Binding(
                    get: { appState.transitionPhysics.springStiffness },
                    set: { appState.transitionPhysics.springStiffness = $0 }
                ),
                displayFormatter: { String(format: "%.0f%%", $0 * 100) }
            )
            PhysicsSlider(
                label: "Blur Intensity",
                value: Binding(
                    get: { appState.transitionPhysics.blurIntensity },
                    set: { appState.transitionPhysics.blurIntensity = $0 }
                ),
                displayFormatter: { String(format: "%.0f%%", $0 * 100) }
            )
            PhysicsSlider(
                label: "Portal Friction",
                value: Binding(
                    get: { appState.transitionPhysics.portalFriction },
                    set: { appState.transitionPhysics.portalFriction = $0 }
                ),
                displayFormatter: { String(format: "%.0f%%", $0 * 100) }
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Footer

    private var footer: some View {
        Text("Settings sync across both devices")
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
    }

    private var thinDivider: some View {
        Rectangle()
            .fill(.primary.opacity(0.06))
            .frame(height: 1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
    }
}

// MARK: - Custom Slider

private struct PhysicsSlider: View {
    let label: String
    @Binding var value: CGFloat
    let displayFormatter: (CGFloat) -> String

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(displayFormatter(value))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(accentBlue)
                    .monospacedDigit()
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // Track background
                    Capsule()
                        .fill(.primary.opacity(0.06))
                        .frame(height: 4)

                    // Filled portion
                    Capsule()
                        .fill(accentBlue)
                        .frame(width: max(4, geo.size.width * value), height: 4)

                    // Thumb
                    Circle()
                        .fill(.white)
                        .frame(width: 12, height: 12)
                        .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                        .offset(x: max(0, geo.size.width * value - 6))
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            let newValue = drag.location.x / geo.size.width
                            value = min(max(newValue, 0), 1)
                        }
                )
            }
            .frame(height: 12)
        }
    }
}

// MARK: - Simulation Canvas

private struct SimulationCanvas: View {
    let mode: TransitionMode
    let velocity: CGFloat

    @State private var cursorProgress: CGFloat = 0
    @State private var ghostPositions: [CGFloat] = [0, 0, 0]
    @State private var portalPulse = false

    private let portalBlue = Color(red: 0.075, green: 0.498, blue: 0.925)

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Dark background
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black.opacity(0.85))

                // Two halves labels
                HStack {
                    Text("YOUR MAC")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.white.opacity(0.3))
                        .tracking(0.5)
                    Spacer()
                    Text("REMOTE MAC")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.white.opacity(0.3))
                        .tracking(0.5)
                }
                .padding(.horizontal, 12)
                .padding(.top, -40)

                // Center portal line
                Rectangle()
                    .fill(portalBlue.opacity(portalPulse ? 0.5 : 0.3))
                    .frame(width: 2, height: geo.size.height * 0.7)
                    .shadow(color: portalBlue.opacity(0.4), radius: 6)

                // Ghost cursor trail
                ForEach(0..<3, id: \.self) { i in
                    cursorShape
                        .opacity(0.15 * Double(3 - i))
                        .offset(x: ghostX(index: i, width: geo.size.width))
                }

                // Active cursor
                cursorShape
                    .shadow(color: portalBlue.opacity(0.6), radius: 4)
                    .offset(x: cursorX(width: geo.size.width))

                // Mode badge
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Text(mode.rawValue.uppercased())
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(portalBlue)
                            .tracking(0.5)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(portalBlue.opacity(0.15))
                            )
                    }
                    .padding(6)
                }

                // Stats overlay
                VStack {
                    Spacer()
                    HStack(spacing: 12) {
                        statsItem(label: "Velocity", value: String(format: "%.0f px/s", velocity))
                        statsItem(label: "Latency", value: "~12ms")
                        Spacer()
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .onAppear {
                startAnimation()
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                    portalPulse = true
                }
            }
        }
    }

    private var cursorShape: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(portalBlue)
            .frame(width: 8, height: 8)
    }

    private func cursorX(width: CGFloat) -> CGFloat {
        let range = width * 0.7
        return -range / 2 + cursorProgress * range
    }

    private func ghostX(index: Int, width: CGFloat) -> CGFloat {
        let range = width * 0.7
        return -range / 2 + ghostPositions[index] * range
    }

    private func statsItem(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 7, weight: .medium))
                .foregroundStyle(.white.opacity(0.3))
            Text(value)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white.opacity(0.7))
                .monospacedDigit()
        }
    }

    private func startAnimation() {
        // Animate cursor left→right on a 3s loop
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { timer in
            withAnimation(.linear(duration: 0.05)) {
                // Update ghost positions (trail of previous positions)
                ghostPositions[2] = ghostPositions[1]
                ghostPositions[1] = ghostPositions[0]
                ghostPositions[0] = cursorProgress

                cursorProgress += 0.012
                if cursorProgress > 1.0 {
                    cursorProgress = 0
                    ghostPositions = [0, 0, 0]
                }
            }
        }
    }
}
