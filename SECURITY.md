# Security Policy

Security matters here: this app holds a private key that identifies your phone
to the servers you paired with, and it can reach web apps on your computer. We
take reports seriously and appreciate responsible disclosure.

## Supported versions

The latest release, plus `main`. Older builds are not patched.

## Reporting a vulnerability

**Please do not open a public issue for a security problem.**

Report privately to:

> **cool@lyuhj.top**

If that address is unavailable, open a minimal public issue that says only
"security contact requested" (no details) and we will reach out.

Please include, where possible:

- what you were doing and what you expected;
- the impact (what an attacker gains);
- steps to reproduce, or a proof of concept;
- the app version (About screen) and iOS version;
- any suggested fix.

## What to expect

- We will acknowledge your report as soon as we can.
- We will confirm the problem and its impact, and keep you posted while we work
  on a fix.
- With your permission, we will credit you in the release notes.

## Scope

In scope (this app):

- pairing and device identity: token handling, the Keychain entry, and what
  happens when a server is removed or a device revoked;
- the in-app loopback proxy and the tunnel to the server: request rewriting,
  isolation between servers and between apps, and the loopback secret gate
  (`ProxyAuth` — another app on the same phone must not reach the proxy or
  ride the paired connection);
- anything that lets one paired server — or one app served through it — read
  another's data, or reach something it should not;
- deep links (`raemote://`), the QR scanner, and the share paths;
- the web view: rendering a remote page with the app's privileges, or escaping
  the loopback proxy origin.

Out of scope:

- the security of the apps you choose to expose, and of your own server host;
- iOS, WebKit, or iroh/QUIC vulnerabilities — report those upstream (we are
  still interested if the app makes one reachable);
- an attacker who already controls your unlocked phone, or a jailbroken device.

The trust model, and the server-side considerations, live in the server
repository: [`docs/threat-model.md`](https://github.com/raemote/raemote_server/blob/main/docs/threat-model.md),
with its own
[`SECURITY.md`](https://github.com/raemote/raemote_server/blob/main/SECURITY.md).
