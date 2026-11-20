# Bluetooth.koplugin

A Bluetooth plugin for [KOReader](https://koreader.rocks/): scan for devices, pair, connect and manage them from the KOReader menu, have them reconnect after the reader wakes, and bind remote buttons to KOReader actions.

> **Status: in development.** It currently supports PocketBook (and Linux, for testing), with experimental Kobo MTK and Kindle support. Expect rough edges and please report them on the [issue tracker](https://github.com/sabrina553/bluetooth.koplugin/issues); feature requests are welcome too.

## Supported devices

| Device | State |
| --- | --- |
| PocketBook (Linux-based) | Supported. Power is switched with `netagent`, everything else through BlueZ over D-Bus or `bluetoothctl`. |
| Linux desktop / KOReader emulator | Supported through BlueZ (D-Bus or `bluetoothctl`). |
| Kobo MTK (Libra Colour, Clara BW/Colour, Tolino Shine 5) | Experimental, in beta and development builds; untested on a device, reports welcome. Talks to Kobo's own Bluetooth service over D-Bus. |
| Kindle (with Bluetooth) | Experimental, in beta and development builds; tested on the Paperwhite 5 and 6. Headphones pair as usual; remotes need a one-time setup, see [Kindle](#kindle). |
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
| Turn off if none reconnect | After a wake or start-up, turn Bluetooth off when no starred or last-connected device reconnects within 15 seconds. It tries again on the next wake. Off by default; needs Starred or Last on Wake. |
| Notifications | Silent mode hides confirmation pop-ups, or switch them off one kind at a time. Errors always show. |
| Backend | Automatic (default), Fast (D-Bus) or Compatible (`bluetoothctl`). Only shown where there is a choice. |
| Live updates (experimental) | Follow the radio and devices while the menu is open. Off by default. |
| Set up remotes… | Kindle only: the one-time setup that lets remotes pair, see [Kindle](#kindle). |

Star a device from its hold menu to mark it as a favourite for *Starred on Wake*.

Bluetooth is never switched on automatically: if you turned it off, it stays off after a restart or wake. If it was on when the reader suspended, it is restored on wake.

**Toggle Bluetooth**, **Turn on Bluetooth** and **Turn off Bluetooth** are also KOReader actions, in the **Device** section: bind them to a gesture or a profile, or add them to another plugin's quick-action menu (such as SimpleUI).

Disconnecting a device yourself holds it: it is untrusted so it can't reconnect by itself, and it is skipped on wake until you connect it again.

## Buttons

**Buttons → Bind a button…** asks you to press a button on the remote, then which screen it applies to (Reader, File browser or Both) and which action to run: page turns and other common actions, or any KOReader action. **Reader buttons** and **File browser buttons** list your bindings; tap one to change or remove it.

Bindings are saved per remote, by its Bluetooth name.

## Kindle

Kindle's own software only pairs audio devices such as headphones. Page-turn remotes, keyboards and game controllers need a one-time setup first, which needs root access.

**Settings → Set up remotes…** does it for you, after explaining the risks and what to back up:

- It adds a udev rule and a small helper script so the Kindle treats the remote as an input device, and marker files that stop disconnects filling the storage with logs. These steps come from [kindlebtcontroller.koplugin's guide](https://github.com/finlater/kindlebtcontroller.koplugin#before-you-install-prepare-bluetooth-pairing) and the [MobileRead guide](https://www.mobileread.com/forums/showthread.php?t=369712).
- Every file it changes is copied first to `koreader/settings/bluetooth_kindle_setup/`. The system partition is unlocked only while the files are written and always locked again. If a step fails, the original files are put back.
- **Settings → Undo remote setup…** restores the originals. A firmware update may remove the setup; run it again afterwards.
- It skips the guide's optional `dmcc.sh` edit. The marker files cover most of what that edit did.
- **Please report** how it went, success or failure, with your model and firmware, in an [issue](https://github.com/sabrina553/bluetooth.koplugin/issues). The setup screen shows both. Each report tells other owners of that model whether it's safe.

Once it's done, you can pair remotes from the plugin (including **Pair by address…** on the scan screen, since Kindle's scan may not list them), turn pages with them, and bind their buttons to any KOReader action.

- The setup steps and pairing remotes are verified on the Kindle Paperwhite 5 and 6, done by hand. The in-plugin setup itself hasn't run on a Kindle yet, so your report matters.
- Older models such as the Oasis 1 and Paperwhite 3 have ended up on a white screen that needs recovery. The plugin warns you a second time on these; only continue if you know how to recover your Kindle.
- Other models are untested: you can try, and your report helps everyone.
- Classic and Bluetooth Low Energy (BLE) remotes both work. BLE is verified with an Xbox Series controller on firmware 5.17.1. Only devices with a public address are confirmed; ones with a random address may not pair.

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
