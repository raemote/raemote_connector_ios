# Raemote Connector (iOS)

The iPhone/iPad client for [Raemote](https://github.com/raemote/raemote_cli).
It pairs with a Raemote server on your computer, lists the web apps that server
finds, and opens them over an end-to-end encrypted
[iroh](https://www.iroh.computer/) connection — from any network, with no port
forwarding and no account.

<a href="https://testflight.apple.com/join/3AQeWyUR"><img src="testflight_badge.svg" alt="Available on TestFlight" height="64"></a>

## Build

```sh
git clone https://github.com/raemote/raemote_connector_ios.git
cd raemote_connector_ios
cp Config/Local.xcconfig.example Config/Local.xcconfig   # your bundle id + Apple team
open "Raemote Connector.xcodeproj"
```

Xcode 27 or newer (the app targets iOS 27). The `iroh-ffi` package is fetched
from GitHub on the first build, and **no keys, tokens or certificates are
needed** — [BUILDING.md](BUILDING.md) covers the two values you supply, plus the
command-line build and test.

## What it does

- Keeps a persistent device identity in the Keychain; pairs once, by QR code or
  link.
- Opens each app in `SFSafariViewController` through an in-app loopback proxy
  with a stable per-app origin, so logins and site data survive relaunches.
  Open apps stay warm as background tabs — switching between them is instant
  and keeps the page's state, and leaving one (Done) keeps it running.
- Shows connection status, and can invite another
  device to the same server.

It needs a server to be useful:
[raemote/raemote_cli](https://github.com/raemote/raemote_cli) installs with
one command.

## Troubleshooting

- **"Not Secure Connection Warning" page when opening an app** — Safari (which
  renders apps in-app) can show a full-page HTTP warning for the loopback
  origin. The connection itself is end-to-end encrypted by iroh; the warning is
  a Safari setting, not a problem with Raemote. Turn it off in
  *Settings → Apps → Safari → Privacy & Security → Not Secure Connection
  Warning*.

## Docs and license

[BUILDING.md](BUILDING.md) · [SECURITY.md](SECURITY.md) · [PRIVACY.md](PRIVACY.md)
· AGPL-3.0-or-later — see [LICENSE](LICENSE).
