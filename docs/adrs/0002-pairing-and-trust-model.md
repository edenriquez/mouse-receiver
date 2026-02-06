# ADR 0002: Pairing and Trust Model

## Status
Proposed

## Context
Input injection is security-sensitive. The system must not accept or inject events from unauthenticated or untrusted peers. Transport must be encrypted and peers must be explicitly trusted.

## Decision
- Use TLS over `Network.framework` for all connections.
- Use mutual authentication by pinning peer identity:
  - Each device generates and persists a long-term identity keypair.
  - Pairing persists the peer public key (or certificate public key hash) and binds it to the peer device ID.
- Before accepting any input messages, verify:
  - TLS is established
  - the peer identity matches a stored trusted record
- Pairing requires explicit approval by the user.

## Consequences
- Prevents unauthenticated input injection on the LAN.
- Allows reconnects without re-pairing.
- Requires key management and a persistence mechanism (Keychain recommended).

## Alternatives considered
- Server-only TLS: does not prevent a malicious client on the LAN from injecting input.
- Shared secret without TLS: harder to secure and still lacks transport encryption.

## Notes
- The approval UX can start minimal (single dialog) and evolve into a menu bar flow.
