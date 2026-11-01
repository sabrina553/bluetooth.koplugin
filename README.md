# Bluetooth.koplugin

A Bluetooth plugin for [KOReader](https://koreader.rocks/): scan for devices, pair, connect and manage them from the KOReader menu, have them reconnect after the reader wakes, and bind remote buttons to KOReader actions.

> **Status: in development.** It currently supports PocketBook (and Linux, for testing), with experimental Kobo MTK and Kindle support. Expect rough edges and please report them on the [issue tracker](https://github.com/sabrina553/bluetooth.koplugin/issues); feature requests are welcome too.

## Supported devices

| Device | State |
| --- | --- |
| PocketBook (Linux-based) | Supported. Power is switched with `netagent`, everything else through BlueZ over D-Bus or `bluetoothctl`. |
| Linux desktop / KOReader emulator | Supported through BlueZ (D-Bus or `bluetoothctl`). |
| Kobo MTK (Libra Colour, Clara BW/Colour, Tolino Shine 5) | Experimental, development builds only, untested on a device. Talks to Kobo's own Bluetooth service over D-Bus. |
| Kindle (with Bluetooth) | Experimental, development builds only, untested on a device. Headphones pair as usual; remotes need a one-time setup, see [Kindle](#kindle). |
| Older Kobo, Android | Not yet. The plugin disables itself on these. |

Tested on a PocketBook Verse Pro, Verse Pro Colour and Era Colour, and on Fedora under the KOReader emulator. It should work on other Linux-based PocketBooks that ship BlueZ.

On BlueZ devices it has two backends: **Fast** talks to BlueZ directly over D-Bus, and **Compatible** drives `bluetoothctl`. The default, **Automatic**, uses Fast and falls back to Compatible if D-Bus isn't usable. Both work with older BlueZ (5.52 on current PocketBooks) and newer releases.

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
- **Buttons**: bind remote buttons to KOReader actions, see [Buttons](#buttons).
- **Your devices** (below the scan entry): tap to connect or disconnect, hold for the device actions (info, pair, trust, block, star). With Bluetooth off, your saved devices are still listed; tapping one turns Bluetooth on.

### Settings

| Setting | What it does |
| --- | --- |
| Disable on Suspend | Switch Bluetooth off when the reader suspends. |
| Starred on Wake | Reconnect starred devices on wake. |
| Last on Wake | Reconnect the last connected device on wake. |
| Backend | Automatic (default), Fast (D-Bus) or Compatible (`bluetoothctl`). Only shown where there is a choice. |
| Live updates (experimental) | Follow the radio and devices while the menu is open. Off by default. |

Star a device from its hold menu to mark it as a favourite for *Starred on Wake*.

Bluetooth is never switched on automatically: if you turned it off, it stays off after a restart or wake. If it was on when the reader suspended, it is restored on wake.

Disconnecting a device yourself holds it: it is untrusted so it can't reconnect by itself, and it is skipped on wake until you connect it again.

## Buttons

**Buttons → Bind a button…** asks you to press a button on the remote, then which screen it applies to (Reader, File browser or Both) and which action to run: page turns and other common actions, or any KOReader action. **Reader buttons** and **File browser buttons** list your bindings; tap one to change or remove it.

Bindings are saved per remote, by its Bluetooth name.

## Kindle

Kindle's own software only pairs audio devices such as headphones. Page-turn remotes, keyboards and game controllers need a one-time setup first, which needs root access. The plugin never changes system files itself.

Once it's done, you can pair remotes from the plugin (including **Pair by address…** on the scan screen, since Kindle's scan may not list them), turn pages with them, and bind their buttons to any KOReader action.

The setup is described in [kindlebtcontroller.koplugin's README](https://github.com/finlater/kindlebtcontroller.koplugin#before-you-install-prepare-bluetooth-pairing) and the [MobileRead guide](https://www.mobileread.com/forums/showthread.php?t=369712). In short: a udev rule and a small helper script so the Kindle treats the remote as an input device, pairing with `ace_bt_cli`, and marker files that stop disconnects filling the disk with logs.

- It is verified on the Kindle Paperwhite 5 and 6.
- **Don't** try it on older models such as the Oasis 1 or Paperwhite 3: they can end up on a white screen that needs recovery.
- Only classic Bluetooth remotes work; Bluetooth Low Energy (BLE) ones don't.

## Updating

**Settings → About** shows the installed version and checks GitHub for a newer one. Pick a channel under **Update Channel**:

| Channel | Gets |
| --- | --- |
| Stable | Stable releases (`X.Y.Z`). |
| Beta | Beta releases and release candidates (`X.Y.Z-beta.N`, `-rc.N`). |
| Development | Development pre-releases (`X.Y.Z-dev.N`). |

Each channel follows only its own releases and offers the newest one, even if its version number is lower than what you have; switch channel to move between them.

Note: the updater does not verify the TLS certificate of GitHub, so only use it on networks you trust, or update by hand.

## Troubleshooting

KOReader writes its log to `crash.log` in its folder. The plugin logs its scans, state changes and timings there with device addresses shortened to the last two bytes, so it is safe to attach to an issue.

## Contributing

Branches are `main` (stable) ← `beta` ← `dev` ← feature branches. Open pull requests against `dev`. Tests are plain LuaJIT scripts:

```sh
for t in tests/*_test.lua; do luajit "$t"; done
```

## Credits

Forked from, and jump-started by, the PocketBook work of [last-available-username](https://github.com/last-available-username). Plugins like this are built for their users and on the back of their contributions. Code adapted from other plugins is listed in [CREDITS.md](./bluetooth.koplugin/CREDITS.md).

## Licence

GPL-3.0. See [LICENSE](./LICENSE).
