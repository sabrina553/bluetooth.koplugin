# Bluetooth.koplugin

A Bluetooth plugin for [KOReader](https://koreader.rocks/): scan for devices, pair, connect and manage them from the KOReader menu, and have them reconnect after the reader wakes.

> **Status: in development.** It currently supports PocketBook (and Linux, for testing). Expect rough edges and please report them on the [issue tracker](https://github.com/sabrina553/bluetooth.koplugin/issues); feature requests are welcome too.

## Supported devices

| Device | State |
| --- | --- |
| PocketBook (Linux-based) | Supported. Power is switched with `netagent`, everything else through BlueZ. |
| Linux desktop / KOReader emulator | Supported through BlueZ (`bluetoothctl`). |
| Kobo, Kindle, Android | Not yet. The plugin disables itself on these. |

Tested on a PocketBook Verse Pro, Verse Pro Colour and Era Colour, and on Fedora under the KOReader emulator. It should work on other Linux-based PocketBooks that ship BlueZ.

It talks to `bluetoothctl`, so it works with both older BlueZ (5.52 on current PocketBooks) and newer releases; it detects which command spellings are available.

## Installation

1. Download `bluetooth.koplugin.zip` from the [latest release](https://github.com/sabrina553/bluetooth.koplugin/releases/latest) and extract it.
2. Copy the inner `bluetooth.koplugin` folder into KOReader's `plugins` directory (on a PocketBook, `applications/koreader/plugins` on the internal storage).
3. Restart KOReader.

Once installed, later versions can be installed from inside KOReader (see [Updating](#updating)).

## Usage

Open the top menu, go to **Tools** (the crossed wrench and screwdriver) and choose **Bluetooth**.

- **Bluetooth** (tick box): turns the controller on or off.
- **Settings**: see below.
- **Scan**: searches for nearby devices for a short while and lists them. The list updates as devices appear and keeps your page. Tap a device to pair it.
- **Your devices** (below the scan entry): tap to connect or disconnect, hold for the device actions (info, pair, trust, block, star).

### Settings

| Setting | What it does |
| --- | --- |
| Disable on Suspend | Switch Bluetooth off when the reader suspends. |
| Starred on Wake | Reconnect starred devices on wake. |
| Last on Wake | Reconnect the last connected device on wake. |

Star a device from its hold menu to mark it as a favourite for *Starred on Wake*.

Bluetooth is never switched on automatically: if you turned it off, it stays off after a restart or wake. If it was on when the reader suspended, it is restored on wake.

A device you have trusted may reconnect by itself after you disconnect it, because BlueZ accepts connections from trusted devices. Untrust it if you do not want that.

## Updating

**Settings → About** shows the installed version and checks GitHub for a newer one. Pick a channel under **Update Channel**:

| Channel | Gets |
| --- | --- |
| Stable | Tagged releases (`X.Y.Z`). |
| Beta | Release candidates (`X.Y.Z-beta.N`, `-rc.N`) and stable. |
| Development | Everything, including `X.Y.Z-dev.N` pre-releases. |

Note: the updater does not verify the TLS certificate of GitHub, so only use it on networks you trust, or update by hand.

## Troubleshooting

KOReader writes its log to `crash.log` in its folder. The plugin logs its scans, state changes and timings there with device addresses shortened to the last two bytes, so it is safe to attach to an issue.

## Contributing

Branches are `main` (stable) ← `beta` ← `dev` ← feature branches. Open pull requests against `dev`. Tests are plain LuaJIT scripts:

```sh
for t in tests/*_test.lua; do luajit "$t"; done
```

## Credits

Forked from, and jump-started by, the PocketBook work of [last-available-username](https://github.com/last-available-username). Plugins like this are built for their users and on the back of their contributions.

## Licence

GPL-3.0. See [LICENSE](./LICENSE).
