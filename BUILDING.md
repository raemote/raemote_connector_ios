# Building Raemote Connector

Short version: `cp Config/Local.xcconfig.example Config/Local.xcconfig`, fill in
two values, open the project in Xcode, build. There are **no secrets to obtain** —
see "What you need" below.

## Prerequisites

- macOS with **Xcode 27** or newer, including an iOS 27 simulator.
- Network access for the first build: the `iroh-ffi` Swift package is resolved
  from GitHub and provides the prebuilt iroh binary. (Nothing is vendored.)
- To run on a device, an Apple ID you can sign with — a free one is fine.

## Steps

```sh
git clone https://github.com/raemote/raemote_ios.git
cd raemote_ios/Raemote\ Connector
cp Config/Local.xcconfig.example Config/Local.xcconfig     # then edit it
open "Raemote Connector.xcodeproj"
```

Select the **Raemote Connector** scheme and run. Without
`Config/Local.xcconfig` the project still builds for the Simulator using the
placeholder bundle id `com.example.raemote`.

Command line, if you prefer:

```sh
xcodebuild -project "Raemote Connector.xcodeproj" -scheme "Raemote Connector" \
  -destination 'generic/platform=iOS Simulator' build

xcodebuild -project "Raemote Connector.xcodeproj" -scheme "Raemote Connector" \
  -destination 'platform=iOS Simulator,name=iPhone 17' test
```

## What you need

Two values, both in `Config/Local.xcconfig` (gitignored, so yours stay private):

| Setting | What it is |
| --- | --- |
| `RAEMOTE_BUNDLE_ID` | Your app's bundle identifier — any reverse-DNS string unique to you, e.g. `com.yourname.raemote`. |
| `RAEMOTE_DEVELOPMENT_TEAM` | Your Apple Developer team id, needed only to run on a physical device. Leave empty for the Simulator. |

That's all. Specifically:

- **No API keys, tokens, certificates or provisioning profiles** are needed to
  build, and none are stored in this repository.
- The pairing token comes from *your own* Raemote server at runtime — it is
  printed by `raemote pair` and is not part of the build.
- The device's iroh identity (a private key) is **generated on first run** and
  stored in the iOS Keychain, scoped to the bundle identifier. It never leaves
  the device (not synced, not backed up).
- The app uses no special entitlements or capabilities, so a free Apple ID can
  sign it for your own device.

### Why the bundle identifier matters

The Keychain entry that holds this device's identity is scoped to
`RAEMOTE_BUNDLE_ID`. Pick one and keep using it: changing it later makes the app
look like a brand-new device to servers you already paired with, so you would
pair again.

## Notes for contributors

- `Package.resolved` is deliberately gitignored so the `iroh-ffi` dependency
  floats to the newest upstream release within its major version. Commit it if
  you ever want a reproducible build more than upstream fixes.
- Do not hard-code identifiers in Swift: the bundle id comes from
  `Config/Shared.xcconfig` (plus your local override), and the Keychain service
  is derived from `Bundle.main.bundleIdentifier` at runtime.

## Troubleshooting

- **`xcodebuild` cannot resolve `IrohLib`** — the package is fetched from GitHub;
  check network access and try `File > Packages > Reset Package Caches`.
- **A device build asks for a team** — set `RAEMOTE_DEVELOPMENT_TEAM` (and pick
  the same team in the target's Signing settings).
- **The app connects but shows no apps** — you need a paired Raemote server with
  discovered apps. Run `raemote discover --verbose` on the server to see what it
  found and why anything was skipped.
