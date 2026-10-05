# Nirvana Control

A macOS menu bar app and Notification Center widget for **boAt Nirvana Ion ANC**
earbuds. boAt only ships Android and iOS apps; this brings the main controls to
the Mac.

Unofficial and not affiliated with boAt. The control protocol was worked out by
studying how the official Android app talks to the earbuds.

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

- The earbuds use the wuqi chipset protocol over RFCOMM. The command bytes and
  where each came from are documented in comments in
  `Sources/BoatMenuBar/Wuqi/`.
- Quit the app normally rather than killing it. A killed app can leave the
  earbuds holding a stale session and refusing new connections.
- If the phone's boAt app is connected to the earbuds, it may hold the control
  channel and block the Mac.
