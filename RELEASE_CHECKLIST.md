# Release Checklist — SecureSSH Terminal

Work through every item before shipping a build.

## 1. Build & bundle

- [ ] `make test` — all suites pass on a clean checkout.
- [ ] `make release` — optimized build succeeds with no warnings of concern.
- [ ] `make app` — produces `build/SecureSSH Terminal.app` with the correct
      `Info.plist` (bundle id `com.securessh.terminal`, version bumped).
- [ ] Launch the bundled app on a clean user account: profile CRUD,
      first-connection trust prompt, connect/disconnect, paste warning.

## 2. Code signing & Hardened Runtime

- [ ] Sign with a Developer ID Application certificate, enabling the
      hardened runtime and the sandbox entitlements:

      codesign --force --options runtime \
        --entitlements Resources/SecureSSHTerminal.entitlements \
        --sign "Developer ID Application: <TEAM>" \
        "build/SecureSSH Terminal.app"

- [ ] Verify: `codesign --verify --deep --strict --verbose=2 "build/SecureSSH Terminal.app"`
- [ ] Confirm entitlements on the signed binary:
      `codesign -d --entitlements - "build/SecureSSH Terminal.app"`
      must list **only**: `app-sandbox`, `network.client`,
      `files.user-selected.read-only`.
- [ ] No extra entitlements crept in (no `network.server`, no
      `disable-library-validation`, no JIT).

## 3. Notarization

- [ ] `ditto -c -k --keepParent "build/SecureSSH Terminal.app" SecureSSH.zip`
- [ ] `xcrun notarytool submit SecureSSH.zip --keychain-profile <profile> --wait`
- [ ] `xcrun stapler staple "build/SecureSSH Terminal.app"`
- [ ] Gatekeeper check on another Mac: `spctl -a -vv "SecureSSH Terminal.app"`

## 4. Secret & log audit

- [ ] `grep -riE "password|passphrase|secret" Sources/ Tests/` — confirm no
      literal credential values; only identifiers, prompts, and Keychain
      plumbing.
- [ ] No `print`/`NSLog`/`os_log` of session data or credentials:
      `grep -rn "print(" Sources/` reviewed.
- [ ] Run the app, exercise a failed login, then check Console.app — no
      credential material in any message.
- [ ] Inspect `~/Library/Application Support/SecureSSHTerminal/*.json` —
      metadata only; permissions are 0600.
- [ ] Verify UserDefaults contains no secrets:
      `defaults read com.securessh.terminal` → only font size / paste-warning keys.
- [ ] Delete a profile that had saved credentials, then confirm in Keychain
      Access (service `com.securessh.terminal.credentials`) that its items
      are gone.

## 5. Security behavior spot-checks

- [ ] First connection to a fresh host shows the fingerprint and requires
      explicit trust; Cancel aborts without connecting.
- [ ] Tamper test: edit `known_hosts.json` to a wrong key, reconnect —
      connection is blocked with the changed-key warning; only
      "Replace Key and Connect" proceeds.
- [ ] Touch ID toggle: with "Require Touch ID" on, reading the saved
      password prompts for user presence.
- [ ] No telemetry: `nettop`/Little Snitch during idle use shows no
      connections besides the SSH session.

## 6. Repository hygiene

- [ ] `git status` clean; no `.build/`, bundles, or stray files committed.
- [ ] README test output section matches the actual latest run.
- [ ] Version bumped in `Resources/Info.plist`; tag created.
