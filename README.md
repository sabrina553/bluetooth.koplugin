# pocketbook-bluetooth.koplugin

Toy KOReader plugin for PocketBook Inkpad 4 to toggle Bluetooth

Works on my Inkpad 4 with firmware 6.10, plausibly would work on any 6.8/6.10 firmware device, but may require some adjustment.

This is my first koplugin, written to scratch an itch and learn how KOReader plugins work.  It was heavily based on the stock 'Hello World' and SSH plugins.  As a first effort, the quality is somewhere between proof of concept and first draft, but it worked for me.


## What's the execuse for writing this
I frequently use a Bluetooth device (8bitdo zero 2) as a page turner. While the PocketBook reader is pretty good on runtime between charges, Bluetooth does cut noticeably into the battery life.  Therefore, I'd like to turn Bluetooth off when I'm not actively using it. 

The stock PocketBook panel where the Bluetooth control button is located is quick and easy to access...from the stock reader.  It can not be opened from within KOReader (Or at least I never figured out how).  To enable or disable WiFi or Bluetooth requires

 1) go back to main screen
 2) drop down top menu
 3) press Bluetooth button
 4) dismiss the top menu
 5) Press the KOReader Icon (You did put the KOReader icon on the front panel, right?)

In all this sequence takes maybe 5-10 seconds depending on how fast the device is feeling today. Which is about 7 seconds too many.

It would be nice to have a way to activate & deactivate Bluetooth without quitting back to the main screen.

I have recently started using the beautiful and functional [ZenUI plugin](https://github.com/AnthonyGress/zen_ui.koplugin), which has a lovely drop down top menu with choice of lots of useful buttons. These buttons include one that skips the annoying trip out of KOReader for WiFi, but unfortunately not for Bluetooth.  

ZenUI can, however create a custom button that may be assigned to a plugin action.  If only I had a plugin that could toggle Bluetooth...

## Installation

Download the zip, extract.

Place contents in the koreader/plugins directory:

```
plugins/
├── pocketbook-bluetooth.koplugin/
│   ├── _meta.lua
│   └── main.lua
├── some-other.koplugin/
└── yet-another.koplugin/
```
Restart KOReader, if necessary.

## Usage

Appears in the top menu under Tools (Crossed Wrench and Screwdriver Icon) as "Pocketbook Bluetooth"

Provides three actions "Enable Bluetooth", "Disable Bluetooth" and "Toggle Bluetooth"


## General Disclaimer
While this worked on my device I make no claims as to utility, safety or value.  I'm not a lawyer, but if this somehow manages to break your device, erase your books or make you sterile, its not my fault.  Use at your own risk.  

## License

Licensed under GPL3.  For details see [LICENSE](./LICENSE).
