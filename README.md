# Nirvana Control

A macOS menu bar app and Notification Center widget for **boAt Nirvana Ion ANC**
earbuds. boAt only ships Android and iOS apps; this brings the main controls to
the Mac.

Unofficial and not affiliated with boAt.

> [!TIP]
> **Different boAt earbuds?** [boat-tws-commands](https://github.com/bezalelsamuel/boat-tws-commands)
> has command references for 57 Airdopes and Nirvana models to adapt this app.

<p align="center">
  <img src="https://cdn.shopify.com/s/files/1/0057/8938/4802/files/NION-ANC-FI_Black01.png?v=1702893834" alt="boAt Nirvana Ion ANC earbuds and case" width="300"><br>
  <sub><a href="https://www.boat-lifestyle.com/products/nirvana-ion-anc-earbuds">boAt Nirvana Ion ANC</a> (image: boAt)</sub>
</p>

## Features

- **Noise control:** ANC, Ambient or Off, from the menu bar, the widget, a
  global hotkey, Siri/Shortcuts, or `nirvanacontrol://` links
- **8-band EQ** with presets and saved custom presets
- **Battery** for left, right and case, with low-battery notifications
- **In-ear detection** toggle
- **Auto-connect**, plus Open at Login
- **Disconnect when the lid closes** (and reconnect when it opens)
- **Keep the Mac's microphone** so the earbuds' mic doesn't take over input

## Requirements

- macOS 14 or later
- Xcode, signed into an Apple ID (a free Personal Team works)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

## Build and install

```sh
Scripts/build_app.sh
```

This generates the Xcode project from `project.yml`, builds a Release copy,
installs it to `/Applications/Nirvana Control.app` and refreshes the widget.

`project.yml` is the source of truth. The `.xcodeproj` is generated, so edit
`project.yml` and rerun `xcodegen generate` instead of changing the project in
Xcode. To sign with your own team, change `DEVELOPMENT_TEAM` and the App Group
ID in `project.yml` and the entitlements in `Support/`.

## Shortcuts links

Use these with the Shortcuts **Open URLs** action:

| Link | Mode |
| --- | --- |
| `nirvanacontrol://anc` | Noise cancelling |
| `nirvanacontrol://ambient` | Ambient |
| `nirvanacontrol://off` | Off |

## Project layout

```
Sources/
  BoatMenuBar/      the menu bar app
    Wuqi/           RFCOMM connection and earbud protocol
  BoatWidget/       Notification Center widget
  Shared/           state shared between app and widget (App Group)
Support/            Info.plists, entitlements, assets
Scripts/            build_app.sh
project.yml         XcodeGen project definition
```

## Notes

- Quit the app normally rather than killing it. A killed app can leave the
  earbuds holding a stale session and refusing new connections.
- The earbuds accept one controlling device at a time. If a phone is holding
  the connection, the Mac may not be able to connect.
