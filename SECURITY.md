# Security Policy — SecureSSH Terminal

## Threat model

Assets we protect:

1. **User credentials** — SSH passwords and private-key passphrases.
2. **Private key files** — read, never copied or moved.
3. **Session integrity** — what the user types and sees over SSH.
4. **Server trust state** — which host keys the user has accepted.

Adversaries considered:

| Adversary | Mitigation |
|---|---|
| Network man-in-the-middle | Mandatory host-key verification (below); SSH transport encryption via SwiftNIO SSH |
| Malware reading app files on disk | No secrets on disk outside the Keychain; metadata files are 0o600 in a 0o700 directory; sandbox container in release builds |
| Shoulder-surfer / local snooping of logs | No session logging; secrets redacted from error text; SecureField inputs |
| Another local user | Keychain ACLs (`WhenUnlockedThisDeviceOnly`), POSIX permissions, optional Touch ID gate |
| Theft of a backup / synced device | `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` — secrets never migrate to backups or other devices |

Out of scope: a compromised OS/root attacker, hardware attacks, and
compromise of the remote server itself.

## Secret storage

- Passwords and key passphrases are stored **only in the macOS Keychain**
  (`kSecClassGenericPassword`, service `com.securessh.terminal.credentials`),
  and only when the profile's **"Save credentials in Keychain"** toggle is on
  (`MacKeychainService` in `Sources/SecureSSHCore/Services/KeychainService.swift`).
- Items use `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. With
  **"Require Touch ID or password"** enabled, items additionally carry a
  `SecAccessControl` with `.userPresence`, so every read triggers Touch ID
  or the system password.
- When saving is **off**, credentials are requested per connection, passed
  by value to the connect call, and go out of scope when it returns. They
  are never written anywhere. (Swift cannot guarantee zeroization of
  string memory; this is best-effort by design and noted as a limitation.)
- **Deleting a profile deletes its Keychain items** (password and
  passphrase) and disconnects its session (`AppModel.confirmDelete`).
  Turning the save toggle off also purges previously stored secrets.
- Non-secret metadata (profile names, hosts, ports, usernames, notes,
  known-host public keys) lives in JSON under
  `~/Library/Application Support/SecureSSHTerminal/` with 0o600 file /
  0o700 directory permissions. A unit test asserts the persisted JSON
  schema contains no secret-bearing fields.
- Secrets never appear in UserDefaults, plists, logs, source code, tests,
  or fixtures. Test keys are generated at runtime with `ssh-keygen` into
  temporary directories; test "passwords" are random UUIDs.

## Redaction

- User-facing errors come from `SSHAppError` — templated messages that
  never interpolate credential material.
- Unexpected errors are formatted through `Redactor.describe(_:secrets:)`,
  which masks any supplied secret occurrences before display.
- The app writes no log files and installs no logging framework.

## Host-key verification

Implemented in `FileKnownHostsService` + `TerminalViewModel.runHostKeyFlow`
and enforced inside the NIOSSH `HostKeyVerificationDelegate`. **There is no
code path that skips verification** — the delegate fails the handshake
unless the app's trust flow explicitly approves, and the changed-key branch
never accepts implicit decisions.

- **First connection**: the SHA-256 fingerprint (OpenSSH format) is shown
  and the user must explicitly choose *Trust and Connect* (persisted) or
  *Connect Once* (not persisted). Cancel aborts the handshake.
- **Known host, matching key**: connects silently.
- **Changed key**: the connection is **blocked by default** with a warning
  that this may be a man-in-the-middle attack, showing both old and new
  fingerprints and the original trust date. The only way through is the
  destructive-styled *Replace Key and Connect* action; the store also
  refuses to silently overwrite a conflicting entry (`trust` throws —
  only `replace` may overwrite).
- Known hosts are stored at
  `Application Support/SecureSSHTerminal/known_hosts.json` with 0o600
  permissions. Trust is keyed by host **and** port.

## Sandbox, hardened runtime, entitlements

`Resources/SecureSSHTerminal.entitlements` enables the App Sandbox with the
minimum set: `network.client` (outbound SSH only) and
`files.user-selected.read-only` (private keys picked in the open panel).
There is no server entitlement, no blanket file access, and no
library-validation or JIT exceptions. Release builds are signed with the
hardened runtime (see RELEASE_CHECKLIST.md). Development builds run as a
bare SwiftPM executable and are therefore unsandboxed until bundled and
signed.

## Telemetry

**None.** The app makes no network connections other than the SSH sessions
the user initiates. No analytics, crash reporting, or update phone-home.

## Reporting

This is a demonstration project; report issues via the repository issue
tracker. Do not include credentials or server fingerprints in reports.
