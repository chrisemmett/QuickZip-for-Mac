# Distribution

**Decision: Developer ID with notarization, outside the Mac App Store.**
HLD §18.5 asked for this to be decided before the first release.

## Why not the Mac App Store

- **Updates.** The App Store delivers updates for free. Developer ID
  does not, and the usual answer (Sparkle) is a third-party runtime
  dependency, which the design principles rule out (§2). QuickZip ships
  without an in-app updater: new versions are announced on the
  [releases page](https://github.com/chrisemmett/QuickZip-for-macOS/releases) and
  the landing page, and a Homebrew cask can follow once there is a
  stable download URL. An updater built on `URLSession` can be added
  later without a dependency if people ask for it.
- **Review latency and rules.** A file utility that registers as a
  document viewer, opens read-only copies in other applications and may
  one day install a command-line tool (Phase 7) is easier to ship
  without App Review in the loop.
- **Pricing and relationship.** Direct distribution lets the app be free,
  paid or donation-supported without Apple's 15–30% share.

What is given up: App Store discovery, automatic updates, and the
purchase and refund machinery. If discovery matters later, the app is
already sandboxed and carries a privacy manifest, so a Mac App Store build
is a signing and packaging change, not a rewrite.

## What makes a build releasable

| Requirement | Where |
|---|---|
| App Sandbox, with user-selected read/write file access only | `QuickZip/QuickZip.entitlements` |
| Hardened Runtime | `ENABLE_HARDENED_RUNTIME` in the project |
| Signed with a *Developer ID Application* certificate and a secure timestamp | `Scripts/release.sh` |
| Notarized by Apple and stapled to the disk image | `Scripts/release.sh` |
| Privacy manifest (no tracking, no collected data, required-reason APIs declared) | `QuickZip/PrivacyInfo.xcprivacy` |
| No network access, no third-party code | Entitlements; `Package.swift` has no dependencies |

The sandbox has no network entitlement, so QuickZip cannot send anything
anywhere. That is worth saying on the landing page, and it is true by
construction.

## One-time setup

1. Join the Apple Developer Program and, in Xcode → Settings → Accounts,
   create a **Developer ID Application** certificate.
2. Store notarization credentials in the keychain (an app-specific
   password from appleid.apple.com):

   ```bash
   xcrun notarytool store-credentials quickzip \
       --apple-id you@example.com --team-id ABCDE12345
   ```

3. Set your own bundle identifier and team. Copy
   `Config/Local.xcconfig.example` to `Config/Local.xcconfig` (ignored by
   git) and set `BUNDLE_ID_PREFIX` to a reverse-DNS prefix you control and
   `DEVELOPMENT_TEAM` to your team ID. The app becomes
   `<prefix>.QuickZip` and the Quick Look extension
   `<prefix>.QuickZip.QuickLook`. Do not ship with the `com.example`
   placeholder. Choose the prefix once: the identifier names the app to
   Launch Services, the sandbox container and notarization, and changing it
   later orphans users' settings.

## Making a release

1. Set `MARKETING_VERSION` and increment `CURRENT_PROJECT_VERSION` in the
   project.
2. Run the checks: `swift test` in `ArchiveKit`, the benchmarks with
   `--check`, and a long fuzz run (all three also run in CI).
3. Build the disk image:

   ```bash
   TEAM_ID=ABCDE12345 NOTARY_PROFILE=quickzip Scripts/release.sh
   ```

   The script archives, exports with Developer ID, confirms the sandbox
   and hardened runtime are present, builds a disk image, notarizes it
   (waiting for Apple), staples the ticket and runs `spctl` as Gatekeeper
   would. The result is `Distribution/out/QuickZip-<version>.dmg`.
4. Tag the commit, create a GitHub release and attach the disk image and
   its SHA-256 (printed at the end of the script).
5. Download the release on a second Mac that has never seen the app and
   open it, to confirm Gatekeeper accepts it.

## Not yet done

The script is written but has not been run: it needs a Developer ID
certificate and notarization credentials that are not in this repository.
Expect to fix small things the first time (the most likely is the
`CODE_SIGN_IDENTITY` string if the certificate has a different name).
