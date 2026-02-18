import SwiftUI
import InputShareDiscovery

struct PairingView: View {
    let appState: AppState

    var body: some View {
        VStack(spacing: 16) {
            // Status indicator
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 12, height: 12)
                Text(appState.connectionStatus.rawValue)
                    .font(.headline)
            }
            .padding(.top, 8)

            if let name = appState.pairedDeviceName {
                Text("Paired with: \(name)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Divider()

            if appState.connectionStatus == .disconnected {
                if appState.discoveredDevices.isEmpty {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("Searching for devices...")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxHeight: .infinity)
                } else {
                    List(appState.discoveredDevices) { device in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(device.name)
                                    .font(.body)
                            }
                            Spacer()
                            Button("Pair") {
                                appState.connectTo(device: device)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .padding(.vertical, 4)
                    }
                }
            } else {
                VStack(spacing: 12) {
                    if appState.connectionStatus == .forwarding {
                        Text("Mouse is being shared")
                            .font(.title3)
                            .foregroundStyle(.green)
                        Text("Move to top-left corner to return control")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Move mouse to top-right corner to share")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("Disconnect") {
                        appState.disconnect()
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
                .frame(maxHeight: .infinity)
            }
        }
        .padding()
        .frame(width: 300, height: 350)
        .onAppear {
            appState.startDiscovery()
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            appState.refreshDevices()
        }
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
