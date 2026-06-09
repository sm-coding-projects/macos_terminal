# SecureSSH Terminal

A native macOS SSH client built with Swift and SwiftUI. No Electron, no web
views, no telemetry — a sidebar of saved servers, an interactive ANSI
terminal, and Keychain-only secret storage.

![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-blue)
![Swift](https://img.shields.io/badge/swift-6.x-orange)

## Features

- **Connection profiles**: add, edit, duplicate, and delete saved servers with
  display name, host/IP, port (default 22), username, auth method
  (password or private key), notes, and per-profile credential options.
- **Connect flow**: double-click a server in the sidebar (or select it and
  press Return, or ⌘↩) to open a session. Last-used timestamps update on
  successful connection. Sessions disconnect cleanly from the toolbar,
  menu (⇧⌘D), or status bar.
- **Interactive terminal** (via [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)):
  monospaced font, full ANSI/xterm-256color support, scrollback, selection
  and copy/paste, live resize (propagated as SSH window-change), Ctrl+C /
  Ctrl+D, clear screen (⌘K), and a warning before pasting multi-line
  clipboard content.
- **Security first**: secrets only in the macOS Keychain (opt-in, optional
  Touch ID / system-password gate), strict host-key verification with
  first-use fingerprint confirmation and changed-key blocking, secret
  redaction in errors. See [SECURITY.md](SECURITY.md).
- **macOS HIG niceties**: dark theme, sidebar + detail split view, toolbar,
  full menu bar with keyboard shortcuts, search field for servers,
  accessibility labels throughout, empty states, and a Settings window (⌘,).
- **Architecture ready for tabs**: every profile gets its own independent
  `TerminalViewModel` session; the UI currently shows one at a time via the
  sidebar, and multiple simultaneous sessions already work (connect A,
  select B, connect B, switch back — A keeps running).

## Requirements

- macOS 14 (Sonoma) or later (Apple Silicon or Intel)
- Swift 6 toolchain — either Xcode 16+, or just the Command Line Tools
- Network access on first build (SwiftPM fetches dependencies)

## Build, run, test

```sh
make build      # debug build (swift build)
make run        # build and launch the app
make test       # run the unit test suite (56 tests)
make release    # optimized build
make app        # wrap the release binary into build/SecureSSH Terminal.app
make dmg        # universal (arm64+x86_64) tester DMG, ad-hoc signed
```

`make dmg` produces `build/SecureSSH-Terminal-<version>.dmg` with a
drag-to-Applications layout and first-launch instructions. It is ad-hoc
signed by default (testers right-click → Open once, since it isn't
notarized); set `SIGN_IDENTITY="Developer ID Application: …"` to sign with
a real certificate instead.

`make test` passes explicit framework search paths so the Swift Testing
framework resolves when only the Command Line Tools are installed; with
full Xcode, plain `swift test` works as well.

### Test results (last verified run)

```
✔ Test run with 56 tests in 7 suites passed after 0.287 seconds.
```

Suites: profile validation, profile store persistence, redaction, Keychain
service + profile secrets, known-hosts trust transitions, OpenSSH key
parsing, terminal view model (connection lifecycle, host-key flow,
credential resolution, I/O) — all service-level, using protocol mocks for
SSH, Keychain, and prompts.

## Using the app

1. Click **＋** (or ⌘N) and fill in the server details.
2. Choose whether to **save credentials in the Keychain**. If off, you are
   asked for the password on every connection and it is kept only in memory.
   Optionally require Touch ID / system password to use saved credentials.
3. Double-click the server (or press Return) to connect.
4. On first connection, verify the server's key fingerprint against a
   trusted source before clicking **Trust and Connect**.

## Known limitations

- **xcodebuild / UI tests**: this machine has only the Command Line Tools
  (`xcode-select -p` → `/Library/Developer/CommandLineTools`), so
  `xcodebuild test` and XCUITest UI automation are unavailable. The project
  is a SwiftPM package; all logic is covered by `swift test` unit tests with
  mocks instead. Opening the package in Xcode enables adding a UI-test
  bundle without restructuring.
- **Passphrase-protected private keys** are detected and rejected with a
  clear error. Decrypting OpenSSH-format keys requires `bcrypt_pbkdf`,
  which we chose not to hand-implement (see DECISIONS.md). Use an
  unencrypted Ed25519 key (`ssh-keygen -p -N ""`) kept in a protected
  location, or password auth. The passphrase field/storage already exists
  for when support lands.
- **Key types**: Ed25519 and ECDSA P-256/384/521 are supported (the set
  supported by SwiftNIO SSH). RSA keys are rejected with guidance to use
  Ed25519.
- **Keyboard-interactive and SSH-agent auth** are not implemented.
- The bare `make run` binary runs without an app bundle, so it is unsandboxed
  in development; `make app` + codesigning with the provided entitlements
  produces the sandboxed, hardened-runtime build (see RELEASE_CHECKLIST.md).

## Project layout

```
Sources/SecureSSHCore/        # UI-independent library (fully unit-tested)
  Models/                     #   ConnectionProfile + validation
  Services/                   #   ProfileStore, KeychainService, KnownHosts, Redaction
  SSH/                        #   SSHSessionService protocol, NIOSSH backend, key parser
  ViewModels/                 #   TerminalViewModel (session orchestration)
Sources/SecureSSHTerminal/    # SwiftUI app (sidebar, terminal, sheets, settings)
Tests/SecureSSHCoreTests/     # Swift Testing suites with protocol mocks
Resources/                    # Info.plist, sandbox/hardened-runtime entitlements
Scripts/make-app.sh           # .app bundler
```

Further reading: [SECURITY.md](SECURITY.md) · [DECISIONS.md](DECISIONS.md) ·
[RELEASE_CHECKLIST.md](RELEASE_CHECKLIST.md)
