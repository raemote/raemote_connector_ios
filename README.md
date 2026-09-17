# Raemote Connector (iOS)

The iPhone/iPad client for [Raemote](https://github.com/raemote/raemote_server).
It pairs with a Raemote server on your computer, lists the web apps that server
finds, and opens them over an end-to-end encrypted
[iroh](https://www.iroh.computer/) connection — from any network, with no port
forwarding and no account.

Join TestFlight [here](https://testflight.apple.com/join/3AQeWyUR).

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
- Opens each app in a `WKWebView` through an in-app loopback proxy with a stable
  per-app origin, so logins and site data survive relaunches.
- Shows whether the connection is direct or relayed, and can invite another
  device to the same server.

It needs a server to be useful:
[raemote/raemote_server](https://github.com/raemote/raemote_server) installs with
one command.

## Docs and license

[BUILDING.md](BUILDING.md) · [SECURITY.md](SECURITY.md) · [PRIVACY.md](PRIVACY.md)
· AGPL-3.0-or-later — see [LICENSE](LICENSE).
