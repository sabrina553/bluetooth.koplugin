# Credits

- `bluetooth/keys/keymap.lua`: the "BTKey" slot and Dispatcher approach is adapted from
  [titandrive/bluetoothconfigurator.koplugin](https://github.com/titandrive/bluetoothconfigurator.koplugin) (MIT).
- `bluetooth/keys/actions.lua`: the reader and file manager common action lists and the
  file manager category exclusions are adapted from the same project (MIT).
- `bluetooth/ui/keys_menu.lua`: the full action picker (Dispatcher's own menu shown in a
  plain Menu, with TouchMenu-style selection) is adapted from `showActionPicker` in the
  same project (MIT).
- `bluetooth/controller/backend_select.lua`: Kobo family detection (the MTK D-Bus service
  file and the Libra 2, Clara 2E and Sage model names) is adapted from
  [xZenLabs/zen-os](https://github.com/xZenLabs/zen-os) (GPL-3.0).
- `bluetooth/controller/kobo_mtk.lua` and `kobo_reboot.lua`: the Kobo MTK power, Wi-Fi,
  scan and pairing sequences and the reboot instead of quitting to Nickel are adapted
  from the same project (GPL-3.0).
- `bluetooth/keys/kobo_input.lua`: finding a Bluetooth remote's input device by the
  `uhid` sysfs link and opening it with `Device.input:open` is adapted from
  [onatbas/bluetooth.koplugin](https://github.com/onatbas/bluetooth.koplugin),
  MIT licence, Copyright (c) 2024 Bluetooth Page Turner Contributors.
- `bluetooth/controller/kindle.lua`: the lipc list reads and their field names, A2DP
  scanning and the Bond/Connect/Disconnect calls are adapted from ZenOS (GPL-3.0); power
  (`BTflightMode`), state (`BTstate`) and the remote setup the README points to come from
  [finlater/kindlebtcontroller.koplugin](https://github.com/finlater/kindlebtcontroller.koplugin),
  MIT licence, Copyright (c) 2025 qiuyukang.

## References

Read for ideas while planning other devices; no code taken from them unless listed above.

| Repo | Platform | Licence |
|---|---|---|
| [igarizio/pocketbook8bitdo.koplugin](https://github.com/igarizio/pocketbook8bitdo.koplugin) | PocketBook | MIT |
| [last-available-username/pocketbook-bluetooth.koplugin](https://github.com/last-available-username/pocketbook-bluetooth.koplugin) | PocketBook | GPL-3.0 |
| [majjam/bluetooth.koplugin](https://github.com/majjam/bluetooth.koplugin) | Kobo MTK | none (ideas only) |
| [linsyking/bluetooth.koplugin](https://github.com/linsyking/bluetooth.koplugin) | Kindle | none (ideas only) |
