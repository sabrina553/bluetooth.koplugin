# Bluetooth.koplugin

*The* Bluetooth plugin for ko-reader.

WARNING: This is in development! Currently limited to pocketbook and is subject to contain issues and bugs. Please use this repository page to report issues and feature requests; however significant! and I hope to get round to fixing/implementing them.

Plugins like this are built for it's users and on the backs of their contributions. 

# Aims

One-stop shop for bluetooth with koreader.

Current state is working with Unix devices running bluez, (Linux/PocketBook).

Tested and Verified against:

- PocketBook: Verse Pro (u634.6.10.3425)
-           : Verse Pro Colour
-           : Era
- Linux: Fedora 7.0.13 (running under the kodev simulator)

As of now I expect this *should* work for all PocketBook devices that are based on linux. Aswell as any other linux devices.

Future goals include combining the community contributions thus far for other devices. Kobo, Kindle, and others. into this repository,
creating a one-stop shop for bluetooth management across all supported devices.

Thank you to [last-available-username](https://github.com/last-available-username) for this plugin was forked and jumped started in regards to pocketbook from their work.

## Installation

Download the zip, extract.

Place the internal bluetooth.koplugin directory into the koreader/plugins directory. (ignoring the Readme, license and such)

Restart KOReader.

## Usage

Appears in the top menu under Tools (Crossed Wrench and Screwdriver Icon) as "Pocketbook Bluetooth"

Main-Menu: 

- Enable Bluetooth (controller)
- Search Devices 
- Your Paired Deivces. Click to toggle Connection:Hold to show device specific actions and details. 

## License

Licensed under GPL3. For details see [LICENSE](./LICENSE).
