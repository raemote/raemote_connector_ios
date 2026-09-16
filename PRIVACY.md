# Privacy Policy

## The short version

- No accounts, no sign-in, no advertising, no analytics, no tracking.
- We do not collect, transmit, or sell your personal data.
- The app has no service of ours to talk to: it only talks to the computers you
  paired it with.

## What is stored, and where

**On your phone** (in the app's own container):

- a private key that identifies this device, in the iOS **Keychain**, marked
  `AfterFirstUnlockThisDeviceOnly` — it is not synced to iCloud and is not
  restored onto another device from a backup;
- the servers you paired with (their node ids, and any name you gave them);
- per-app state: the local port used, the name learned from the page's title,
  and an optional launch URL (for apps whose entry URL carries a token);
- this device's display name (editable in About);
- web data — cookies, local storage — for apps you open, kept by iOS in the
  app's container so your logins survive.

**On your own server(s)**, when you pair and use an app:

- this device's identity, so the server can recognise it;
- the display name this device reports.

Nothing here is sent to us. There is no Raemote service in the middle.

## What goes over the network

- App traffic (the pages you open) travels from the phone to your server over an
  **end-to-end encrypted** [iroh](https://www.iroh.computer/) connection, and
  from the server to the app on that computer.
- To find each other, iroh may use public infrastructure — a relay and a DNS
  service run by the iroh project. A relay forwards encrypted packets, so it can
  see connection metadata (which endpoints talked, when, how much) but not the
  contents. A direct path is used whenever one can be found.
- Nothing is sent to the authors of Raemote. There is no telemetry.

## Third parties

- **iroh** (relays and discovery), as described above. You can point your server
  at a different relay if you prefer — see the server's configuration.
- **Apple / iOS**: the Keychain and the web view are part of the system, and
  Apple's own policies apply.
- No analytics SDKs, no advertising SDKs, no crash-reporting SDKs.

## Your choices

- **Remove a server** in the app to forget it, and **delete the app** to remove
  everything it stored on the phone — including the Keychain key and the web
  data of apps you opened (that data is kept so logins survive, and only goes
  away with the app).
- **On the server**, `raemote devices revoke <node-id>` (or removing
  `~/.raemote/authorized_nodes`) ends this phone's access. The phone keeps its
  own copy of what it stored until you delete the app.

## Children and sensitive data

The app is a general-purpose client for a server you run yourself. What you
expose through it, and the security of your devices, are up to you.

## Changes

Changes to this policy will be noted in the repository.

## Contact

Questions or concerns: **cool@lyuhj.top**. The server's policy
([`PRIVACY.md`](https://github.com/raemote/raemote_server/blob/main/PRIVACY.md))
covers the server side.
