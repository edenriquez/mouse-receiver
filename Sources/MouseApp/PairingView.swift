import SwiftUI
import InputShareDiscovery

private let accentBlue = Color(red: 0.075, green: 0.498, blue: 0.925)

// MARK: - Main View

struct PairingView: View {
    let appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            headerSection
            thinDivider

            switch appState.connectionStatus {
            case .disconnected:
                deviceListSection
            case .connecting:
                connectingSection
            case .connected:
                if appState.isNearEdge {
                    portalWarningSection
                } else {
                    connectedSection
                }
            case .forwarding:
                forwardingSection
            }

            thinDivider
            actionSection
        }
        .frame(width: 260)
        .onAppear { appState.startDiscovery() }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            appState.refreshDevices()
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 8)
                .fill(accentBlue)
                .frame(width: 36, height: 36)
                .overlay {
                    Image(systemName: "cursorarrow.motionlines")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                }

            VStack(alignment: .leading, spacing: 3) {
                Text("MousePortal")
                    .font(.system(size: 13, weight: .bold))

                HStack(spacing: 5) {
                    Circle()
                        .fill(statusDotColor)
                        .frame(width: 6, height: 6)
                    Text(statusLabel)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .tracking(0.3)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Disconnected: Device List

    private var deviceListSection: some View {
        VStack(spacing: 4) {
            if appState.discoveredDevices.isEmpty {
                VStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Searching for devices...")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 80)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(appState.discoveredDevices) { device in
                            DeviceRow(device: device) {
                                appState.connectTo(device: device)
                            }
                        }
                    }
                }
                .frame(maxHeight: 140)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    // MARK: - Connecting

    private var connectingSection: some View {
        VStack(spacing: 8) {
            ProgressView()
                .scaleEffect(0.7)
            Text("Connecting to \(appState.pairedDeviceName ?? "device")...")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 80)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    // MARK: - Portal Warning (near edge)

    private var portalWarningSection: some View {
        VStack(spacing: 10) {
            // Warning icon
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(.white.opacity(0.6))
                    .frame(width: 52, height: 52)
                    .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(accentBlue)
            }

            Text("Portal Warning")
                .font(.system(size: 13, weight: .bold))

            Text("Edge Proximity active. Your cursor is\ncurrently within the trigger zone.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(1)

            // Edge Glow Animation card
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "waveform.path")
                    .font(.system(size: 13))
                    .foregroundStyle(accentBlue)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Edge Glow Animation")
                        .font(.system(size: 11, weight: .semibold))
                    Text("A visual 'breathing' indicator prevents accidental screen forwarding to remote Macs.")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineSpacing(1)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(accentBlue.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(accentBlue.opacity(0.1), lineWidth: 0.5)
                    )
            )

            // Zone Config
            VStack(spacing: 4) {
                HStack {
                    Text("ZONE CONFIG")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .tracking(0.5)
                    Spacer()
                    Text("5% Width")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(accentBlue)
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(.primary.opacity(0.06))
                        Capsule()
                            .fill(accentBlue)
                            .frame(width: geo.size.width * 0.05)
                    }
                }
                .frame(height: 4)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    // MARK: - Connected

    private var connectedSection: some View {
        VStack(spacing: 6) {
            deviceCard
            Text("Move cursor to right edge to share")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
                .padding(.top, 2)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    // MARK: - Forwarding

    private var forwardingSection: some View {
        VStack(spacing: 6) {
            deviceCard

            HStack(spacing: 6) {
                Circle()
                    .fill(accentBlue)
                    .frame(width: 6, height: 6)
                Text("Mouse control is on the remote Mac")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.top, 2)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    // MARK: - Device Card (connected state)

    private var deviceCard: some View {
        HStack(spacing: 8) {
            Image(systemName: "laptopcomputer")
                .font(.system(size: 16))
                .foregroundStyle(accentBlue)

            VStack(alignment: .leading, spacing: 1) {
                Text(appState.pairedDeviceName ?? "Unknown")
                    .font(.system(size: 12, weight: .semibold))
                Text(appState.connectionStatus == .forwarding ? "Sharing Active" : "Connected")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(accentBlue)
            }

            Spacer()

            Image(systemName: "link")
                .font(.system(size: 14))
                .foregroundStyle(accentBlue)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(accentBlue.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(accentBlue.opacity(0.15), lineWidth: 1)
                )
        )
    }

    // MARK: - Actions

    private var actionSection: some View {
        VStack(spacing: 2) {
            if appState.connectionStatus == .forwarding {
                MenuItemRow(icon: "stop.circle.fill", title: "Stop Forwarding", style: .prominent) {
                    appState.disconnect()
                }
            } else if appState.connectionStatus == .connected || appState.connectionStatus == .connecting {
                MenuItemRow(icon: "xmark.circle", title: "Disconnect") {
                    appState.disconnect()
                }
            }

            MenuItemRow(icon: "power", title: "Quit MousePortal", shortcut: "\u{2318}Q", style: .destructive) {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
    }

    // MARK: - Helpers

    private var thinDivider: some View {
        Rectangle()
            .fill(.primary.opacity(0.06))
            .frame(height: 1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
    }

    private var statusDotColor: Color {
        switch appState.connectionStatus {
        case .disconnected: .red
        case .connecting: .orange
        case .connected: .green
        case .forwarding: accentBlue
        }
    }

    private var statusLabel: String {
        switch appState.connectionStatus {
        case .disconnected: "Disconnected"
        case .connecting: "Connecting"
        case .connected: "Active Connection"
        case .forwarding: "Forwarding Active"
        }
    }
}

// MARK: - Device Row (discovery list)

private struct DeviceRow: View {
    let device: DiscoveredDevice
    let onConnect: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: onConnect) {
            HStack(spacing: 8) {
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 14))
                    .foregroundStyle(accentBlue)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 1) {
                    Text(device.name)
                        .font(.system(size: 12, weight: .semibold))
                    Text("Available")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text("Connect")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(hovered ? .white : accentBlue)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hovered ? accentBlue : accentBlue.opacity(0.05))
            )
            .foregroundStyle(hovered ? .white : .primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

// MARK: - Menu Item Row (action buttons)

private struct MenuItemRow: View {
    let icon: String
    let title: String
    var shortcut: String?
    var style: Style = .normal
    let action: () -> Void
    @State private var hovered = false

    enum Style { case normal, prominent, destructive }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .frame(width: 18)

                Text(title)
                    .font(.system(size: 12, weight: style == .prominent ? .semibold : .medium))

                Spacer()

                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 10))
                        .foregroundStyle(isHighlighted ? .white.opacity(0.7) : .secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(backgroundColor)
            )
            .foregroundStyle(foregroundColor)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }

    private var isHighlighted: Bool {
        style == .prominent || hovered
    }

    private var backgroundColor: Color {
        switch style {
        case .prominent:
            return hovered ? accentBlue.opacity(0.85) : accentBlue
        case .destructive:
            return hovered ? .red : .clear
        case .normal:
            return hovered ? accentBlue : .clear
        }
    }

    private var foregroundColor: Color {
        if style == .prominent || hovered {
            return .white
        }
        return .primary
    }
}
