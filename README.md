# InputShare

Production-grade mouse and keyboard sharing for macOS.

## Overview

**InputShare** is a native macOS application for sharing mouse and keyboard input across multiple Macs on a local network. Built with Swift using CoreGraphics, Network.framework, and other native APIs for low latency and reliability.

Similar to: Barrier, Synergy, Universal Control

## Features

### ✅ Implemented (Phase 0)
- CGEventTap-based input capture (mouse, keyboard, scroll)
- CGEventPost input injection
- Cursor warping and position synchronization
- Coordinate normalization for resolution independence
- TLS-encrypted transport with mutual authentication
- Certificate pinning for security
- Synthetic event detection (prevents feedback loops)

### 🚧 In Progress (Phase 1)
- Screen-edge detection with hysteresis
- Seamless cursor handoff between machines
- Input suppression on sender during forwarding
- Modifier key state synchronization
- Activation/deactivation handshake protocol

### 📋 Planned
- Bonjour service discovery
- Device pairing UI
- Multi-monitor support
- Menu bar app
- launchd integration
- Sleep/wake recovery

See [ROADMAP.md](docs/ROADMAP.md) for the complete feature roadmap.

## Requirements

- macOS 12.0 or later
- Swift 5.10+
- Accessibility permissions (prompted on first run)

## Quick Start

### 1. Setup
Run the setup script to generate TLS certificates and build the project:

```bash
./setup.sh
```

This will:
- Generate a local Certificate Authority
- Create certificates for two test devices
- Build the project
- Create convenience run scripts

### 2. Run Receiver
On the machine that will receive input:

```bash
./run-receiver.sh
```

Or manually:
```bash
swift run inputshare receive \
  --port 4242 \
  --identity-p12 .certs/device-a.p12 \
  --identity-pass inputshare-dev \
  --pin-sha256 <device-b-pin>
```

### 3. Run Sender
On the machine that will send input:

```bash
./run-sender.sh
```

Or manually:
```bash
swift run inputshare send \
  --host <receiver-ip> \
  --port 4242 \
  --identity-p12 .certs/device-b.p12 \
  --identity-pass inputshare-dev \
  --pin-sha256 <device-a-pin>
```

**Note:** You'll be prompted for Accessibility permissions on first run. Grant them in System Settings > Privacy & Security > Accessibility.

## Architecture

```
InputShare/
├── Sources/
│   ├── InputShareShared/      # Protocol models, codecs
│   ├── InputShareTransport/   # Network.framework TLS + framing
│   ├── InputShareCapture/     # CGEventTap capture + geometry
│   ├── InputShareInjection/   # CGEventPost injection
│   └── InputShareCLI/         # Command-line interface
├── docs/                      # Documentation and ADRs
└── Package.swift              # Swift Package Manager manifest
```

### Key Design Decisions
- **Protocol:** Length-prefixed JSON messages over TLS
- **Coordinates:** Normalized [0,1] range for resolution independence
- **Security:** Mutual TLS with certificate pinning
- **Input Capture:** CGEventTap (passive, non-blocking)
- **Input Injection:** CGEventPost with synthetic event markers

See [Architecture Decision Records](docs/adrs/) for detailed technical decisions.

## Development

### Build
```bash
swift build
```

### Run Tests
```bash
swift test
```

### Generate Certificates
See [docs/DEV_TLS.md](docs/DEV_TLS.md) for detailed TLS setup instructions.

## Project Rules

This project follows strict architectural guidelines documented in [ANTIGRAVITY_PROJECT_RULES.md](docs/ANTIGRAVITY_PROJECT_RULES.md):

- **Language:** Swift only (no Python, Electron, etc.)
- **APIs:** Native macOS frameworks only
- **Input:** CGEventTap (required)
- **Network:** Network.framework with TLS
- **Security:** Mutual authentication, encrypted transport
- **Architecture:** Modular, testable, launchd-compatible

## Security

- All communication is encrypted via TLS 1.3
- Mutual authentication required (both peers must present certificates)
- Certificate pinning prevents MITM attacks
- Synthetic event markers prevent feedback loops
- No unauthenticated input injection

**Note:** Current setup uses development certificates. Production deployments should use proper certificate management and Keychain integration.

## Contributing

See [FIRST_SPRINT_PLAN.md](docs/FIRST_SPRINT_PLAN.md) for current development priorities.

Key areas for contribution:
- Edge detection and handoff logic
- Modifier key synchronization
- Connection resilience and recovery
- Multi-monitor support
- Unit tests

## License

[Add license information]

## References

- [Product Roadmap](docs/ROADMAP.md)
- [Sprint Plan](docs/FIRST_SPRINT_PLAN.md)
- [Architecture Decision Records](docs/adrs/)
- [Project Rules](docs/ANTIGRAVITY_PROJECT_RULES.md)
