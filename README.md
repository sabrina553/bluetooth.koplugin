# Bluetooth.koplugin

*The* Bluetooth plugin for ko-reader.

WARNING: This is in development and as of right now is not functional. Is only compatabile with Unix based devices, and it frankly utterly useless.

# Aims

One-stop shop for bluetooth with koreader.

Current state is working with Unix devices running bluez, (Linux/PocketBook).

Tested and Verified against:

- u634.6.10.3425 (PocketBook Verse Pro)
- Fedora 7.0.13 (Desktop) running under the kodev simulator.

As of now I expect this *should* work for all PocketBook devices that are based on linux. Aswell as any other linux devices.

Future goals include combining the community contributions thus far for other devices. Kobo, Kindle, and others. into this repository,
creating a one-stop shop for bluetooth management across all supported devices.

Thank you to [last-available-username](https://github.com/last-available-username) for this plugin was forked and jumped started in regards to pocketbook from their work.

## Installation

Download the zip, extract.

Place contents in the koreader/plugins directory:

```
plugins/
├── pocketbook-bluetooth.koplugin/
|   |__ bluetooth/
│   ├── _meta.lua
│   └── main.lua
├── some-other.koplugin/
└── yet-another.koplugin/
```
Restart KOReader.

## Usage

Appears in the top menu under Tools (Crossed Wrench and Screwdriver Icon) as "Pocketbook Bluetooth"

Provides three actions "Enable Bluetooth", "Disable Bluetooth" and "Toggle Bluetooth".

## License

Licensed under GPL3. For details see [LICENSE](./LICENSE).
