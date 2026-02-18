import SwiftUI

struct StatusView: View {
    let appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(appState.connectionStatus.rawValue)
                    .font(.caption)
            }

            if let name = appState.pairedDeviceName {
                Text(name)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(8)
        .frame(width: 180)
    }

    private var statusColor: Color {
        switch appState.connectionStatus {
        case .disconnected: return .red
        case .connecting: return .orange
        case .connected: return .green
        case .forwarding: return .blue
        }
    }
}
