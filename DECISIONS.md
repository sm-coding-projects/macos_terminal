# Architecture Decisions — SecureSSH Terminal

## 1. SSH library: SwiftNIO SSH (apple/swift-nio-ssh)

**Decision**: use SwiftNIO SSH directly for the transport, with a thin
`SSHSessionServicing` protocol so the backend is swappable.

**Environment inspection** (2026-06-10): macOS 26.5, Swift 6.3.2 via
Command Line Tools, GitHub reachable — SwiftPM dependencies are viable.

**Options considered**:

| Option | Verdict |
|---|---|
| **SwiftNIO SSH** | ✅ Chosen. Maintained by Apple, pure Swift, supports interactive client use: session channels with `PseudoTerminalRequest`, `ShellRequest`, `WindowChangeRequest`, and full client auth + host-key delegates (verified in source before adoption). Gives us total control over host-key policy — critical for the security requirements. |
| libssh2 via C wrapper | More key/cipher coverage (incl. encrypted keys, RSA), but requires bundling a C library + OpenSSL, unsafe-pointer surface, and manual update tracking. Held as fallback if NIOSSH proved unusable; it didn't. |
| Citadel (NIOSSH wrapper) | Higher-level, but its abstractions hide the host-key delegate behavior we must own; smaller maintenance team. Direct NIOSSH keeps the security-critical path auditable. |
| `/usr/bin/ssh` subprocess | ❌ Rejected as main implementation per requirements: no programmatic host-key UX (would need expect-style scraping), credentials via askpass hacks, no sandbox-friendly story. The `SSHSessionServicing` protocol means such a backend *could* be added behind the same interface if ever needed, but none is shipped. |

**Consequences**: key support limited to what NIOSSH accepts (Ed25519,
ECDSA P-256/384/521; no RSA), and no built-in OpenSSH key-file parser —
we wrote one (`OpenSSHKeyParser`) for unencrypted keys.

### 1a. Passphrase-encrypted private keys: deliberately unsupported

Decrypting OpenSSH-format encrypted keys requires `bcrypt_pbkdf`
(blowfish-based KDF) + AES-CTR. swift-crypto provides neither primitive,
and **hand-rolling crypto in a security-focused app is a worse risk than
the missing feature**. The parser detects encrypted keys and returns a
specific, actionable error; the UI carries the passphrase field and
Keychain plumbing so support can land without data migration (likely via
a vetted `bcrypt_pbkdf` implementation or libssh2 fallback).

## 2. Terminal emulation: SwiftTerm

**Decision**: embed [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)'s
AppKit `TerminalView` rather than writing an emulator.

VT100/xterm emulation is a multi-year rabbit hole (CSI/OSC parsing, charsets,
mouse modes, 256/true color, reflow). SwiftTerm is mature (powers La
Terminal and Secure ShellFish), pure Swift, SPM-installable, and provides
scrollback, selection, copy/paste, and resize callbacks out of the box. We
subclass it only to add the multi-line paste warning (`PasteGuardTerminalView`)
and keep all SSH wiring in a delegate, so the dependency is replaceable.

## 3. Storage: JSON files in Application Support + Keychain

**Decision**: profiles and known hosts are small JSON arrays written
atomically with 0o600 permissions; secrets go exclusively to the Keychain.

SQLite/SwiftData would add migrations and concurrency machinery for data
that is at most a few KB. JSON files are human-auditable (useful for a
security review: you can *see* there are no secrets), trivially atomic via
`Data.write(.atomic)`, and testable with temp directories. The
`ProfileStoring`/`KnownHostsServicing` protocols isolate the format, so a
database can replace it without touching callers. Known hosts use JSON
rather than OpenSSH's `known_hosts` format because we store trust dates and
need strict host:port keying; the public-key encoding inside is standard
OpenSSH, so fingerprints match `ssh-keygen -lf`.

## 4. Sandboxing & distribution

**Decision**: App Sandbox + Hardened Runtime in the release entitlements;
development runs as a bare SwiftPM executable.

The app needs only `network.client` and user-selected read-only file access
(private keys), so the sandbox costs nothing functionally. SwiftPM cannot
produce signed .app bundles itself, hence `Scripts/make-app.sh` +
RELEASE_CHECKLIST.md document the bundle/sign/notarize path. We accepted
the trade-off that `make run` development builds are unsandboxed — this is
standard for SwiftPM GUI development and is documented in README/SECURITY.

## 5. Architecture: protocol-first core library + thin SwiftUI shell

**Decision**: all logic lives in `SecureSSHCore` (no AppKit/SwiftUI
imports outside the VM's Combine usage), consumed by a small app target.

- `ProfileStoring`, `KeychainServicing`, `KnownHostsServicing`,
  `SSHSessionServicing`, `UserPrompting` are protocols injected into
  `TerminalViewModel` / `AppModel` — every security-relevant flow is unit
  tested against mocks (56 tests), including the full host-key state
  machine, without a network or a real Keychain.
- Async/await throughout; NIO futures are bridged once at the service
  boundary. Connection work never blocks the main thread; UI prompts are
  bridged to async flows via `CheckedContinuation`.
- One `TerminalViewModel` per profile, held in a dictionary on `AppModel`:
  multiple concurrent sessions already work, and a future tab bar is a
  pure view-layer change (render N session views instead of the selected
  one).

## 6. Testing: Swift Testing instead of XCTest

The Command Line Tools on this machine ship the Swift Testing framework
(`Testing.framework`) but not a usable XCTest for SPM macOS test bundles.
Swift Testing is the forward-looking choice anyway (`@Test`, `#expect`,
parameterized tests). The Makefile injects the CLT framework paths; with
full Xcode none of that is needed. UI tests (XCUITest) require an Xcode
project and are documented as a limitation rather than faked.
