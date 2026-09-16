# Raemote Connector (iOS)

The iPhone/iPad client for [Raemote](https://github.com/raemote/raemote_server):
it pairs with a Raemote server running on a computer you own, lists the web apps
that server discovers, and opens them over a direct, end-to-end encrypted iroh
connection — from any network, with no port forwarding and no account.

Pairing is a QR code or a `raemote://bind?...` link printed by the server. Once
paired, the phone remembers the server and can reach it from anywhere.

## What it does

- Binds a real **iroh** endpoint with a persistent identity kept in the Keychain.
- Pairs by scanning the server's QR code (or pasting the link).
- Fetches the server's app catalog over iroh and renders each app in a `WKWebView`
  through an in-app loopback proxy that relays over iroh.
- Keeps a stable per-app origin, so cookies, `localStorage` and site data survive
  relaunches.
- Shows whether the transport is direct or relayed, and invites another device to
  pair with the same server.

## Requirements

- macOS with **Xcode 27** or newer (the app targets iOS 27).
- Network access the first time you build: the `iroh-ffi` Swift package is
  fetched from GitHub.
- To run on a physical device: your own Apple Developer team id (a free Apple ID
  works — the app uses no special entitlements).

## Building

See **[BUILDING.md](BUILDING.md)** — it is short, and covers the two values you
supply (your bundle identifier and Apple team) and the fact that no keys, tokens
or other secrets are needed.

Quick version:

```sh
cp Config/Local.xcconfig.example Config/Local.xcconfig   # then edit it
open "Raemote Connector.xcodeproj"
```

Command line:

```sh
xcodebuild -project "Raemote Connector.xcodeproj" -scheme "Raemote Connector" \
  -destination 'generic/platform=iOS Simulator' build
xcodebuild -project "Raemote Connector.xcodeproj" -scheme "Raemote Connector" \
  -destination 'platform=iOS Simulator,name=iPhone 17' test
```

## Relationship to the server

This app is a client: it needs a Raemote server to be useful. The server is in
[raemote/raemote_server](https://github.com/raemote/raemote_server) and installs
with a one-liner. The two speak a small HTTP-over-iroh API (`raemote/bind/0` for
pairing, `raemote/0` for the API and app proxying).

## License

AGPL-3.0-or-later — see [LICENSE](LICENSE). The server is licensed the same way.
