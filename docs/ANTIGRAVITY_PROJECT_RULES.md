# 📜 Antigravity Project Rules

## Project Name

**InputShare (macOS)**

## Project Type

macOS **system-level input sharing software**

---

## Core Objective

Build a **production-grade mouse and keyboard sharing system for macOS**, comparable in quality to **Barrier / Synergy / Universal Control**, using **native APIs**, optimized for **low latency, correctness, and long-term maintainability**.

This is **not a prototype**.

---

## Allowed Languages & Frameworks

* **Swift (required)**
* CoreGraphics
* AppKit
* Network.framework
* Foundation

❌ Disallowed:

* Python
* Electron
* SwiftUI-only abstractions
* Polling-based input capture
* USB-over-IP
* Screen scraping
* Remote desktop techniques

---

## Input Capture Rules

* MUST use **CGEventTap**
* MUST capture:

  * Mouse movement
  * Mouse buttons
  * Scroll wheel
  * Key down / key up
  * Modifier flags
* MUST NOT block the event tap
* MUST support suppressing local input when forwarding
* MUST survive sleep / wake

---

## Input Injection Rules

* MUST use **CGEventPost**
* Cursor movement via **CGWarpMouseCursorPosition**
* MUST preserve:

  * Modifier flags
  * Correct virtual keycodes
  * Key up/down ordering
* MUST avoid synthetic event feedback loops

---

## Screen & Coordinate Rules

* Mouse coordinates MUST be **normalized** before transport
* Receiver MUST **denormalize** using local screen geometry
* MUST support:

  * Retina & non-Retina displays
  * Differing resolutions
* Multi-monitor support must be architecturally possible

---

## Networking Rules

* MUST use **Network.framework**
* MUST use encrypted transport (TLS)
* MUST support reconnects
* MUST be resilient to packet loss
* MUST be structured so mouse & keyboard can be separated into channels later

❌ Raw BSD sockets unless explicitly justified

---

## Security Rules

* No unauthenticated input injection
* Devices MUST be paired / trusted
* Transport MUST be encrypted
* Events MUST only be accepted from paired peers
* No listening on open interfaces without intent

---

## Permissions & macOS Integration

* MUST request:

  * Accessibility permission
  * Input Monitoring (recommended)
* MUST correctly handle TCC prompts
* MUST not rely on private or undocumented APIs

---

## Architecture Rules

* Input capture, transport, and injection MUST be separate modules
* No monolithic “god objects”
* Logic MUST be testable in isolation
* System must work as:

  * background agent
  * optional menu bar controller
* launchd compatibility is required

---

## Quality Bar

* Comparable latency to Barrier
* No noticeable cursor jitter
* No stuck modifier keys
* Stable under continuous use
* No CPU spikes
* Clean shutdown & recovery

---

## LLM Behavior Instructions

When assisting on this project:

* Prefer **native macOS APIs**
* Assume developer is fluent in Swift
* Optimize for **correctness over shortcuts**
* Explicitly state macOS limitations when relevant
* Do not suggest cross-platform abstractions unless requested
