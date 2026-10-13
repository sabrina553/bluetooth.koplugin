-- Run from the repo root: luajit tests/bluetoothctl_parse_test.lua
-- Fixtures are synthetic: made-up MACs and device names, laid out like bluetoothctl's output.
package.path = "bluetooth.koplugin/?.lua;" .. package.path
local Parse = require("bluetooth/controller/bluetoothctl_parse")

local failures = 0
local function check(description, actual, expected)
    if actual ~= expected then
        failures = failures + 1
        print(("FAIL %s: got %s, expected %s"):format(description, tostring(actual), tostring(expected)))
    end
end

-- bluetoothctl devices
local mac, name = Parse.deviceLine("Device 00:11:22:33:44:55 Test Pager")
check("device line mac", mac, "00:11:22:33:44:55")
check("device line name", name, "Test Pager")

mac, name = Parse.deviceLine("Device 00:11:22:33:44:55   Padded Name  ")
check("device line trims the name", name, "Padded Name")

mac, name = Parse.deviceLine("Device 00:11:22:33:44:55 00-11-22-33-44-55")
check("a dashed-MAC name means unnamed", name, "Unknown")

mac, name = Parse.deviceLine("Device 00:11:22:33:44:55 00-11-22-aa-bb-cc")
check("a different dashed MAC is a real name", name, "00-11-22-aa-bb-cc")

check("not a device line", Parse.deviceLine("[CHG] Controller 00:11:22:33:44:55 Powered: yes"), nil)
check("empty line", Parse.deviceLine(""), nil)

-- bluetoothctl info
local CONNECTED = table.concat({
    "Device 00:11:22:33:44:55 (public)",
    "\tName: Test Pager",
    "\tAlias: Test Pager",
    "\tClass: 0x00002540",
    "\tIcon: input-keyboard",
    "\tPaired: yes",
    "\tBonded: yes",
    "\tTrusted: yes",
    "\tBlocked: no",
    "\tConnected: yes",
    "",
}, "\n")

local info = Parse.info(CONNECTED)
check("info mac", info.mac, "00:11:22:33:44:55")
check("info paired", info.paired, true)
check("info bonded", info.bonded, true)
check("info trusted", info.trusted, true)
check("info blocked", info.blocked, false)
check("info connected", info.connected, true)

local DISCOVERED = table.concat({
    "Device 66:77:88:99:AA:BB (random)",
    "\tAlias: 66-77-88-99-AA-BB",
    "\tPaired: no",
    "\tBonded: no",
    "\tTrusted: no",
    "\tBlocked: no",
    "\tConnected: no",
    "",
}, "\n")

info = Parse.info(DISCOVERED)
check("unpaired mac", info.mac, "66:77:88:99:AA:BB")
check("unpaired paired", info.paired, false)
check("unpaired connected", info.connected, false)

info = Parse.info("")
check("empty output has no mac", info.mac, nil)
check("empty output is not connected", info.connected, false)

info = Parse.info("Device 00:11:22:33:44:55 not available\n")
check("missing flags are false", info.paired, false)

-- Names: Alias is what the menu shows (bluetoothctl devices lists the alias),
-- so it wins; Name is the fallback.
check("name comes from Alias", Parse.info(CONNECTED).name, "Test Pager")

local RENAMED = table.concat({
    "Device 00:11:22:33:44:55 (public)",
    "\tName: Factory Name",
    "\tAlias: My Pager",
    "\tPaired: yes",
    "",
}, "\n")
check("Alias wins over Name", Parse.info(RENAMED).name, "My Pager")

local NAME_ONLY = table.concat({
    "Device 00:11:22:33:44:55 (public)",
    "\tName: Factory Name",
    "\tPaired: yes",
    "",
}, "\n")
check("Name is the fallback", Parse.info(NAME_ONLY).name, "Factory Name")

check("no name at all", Parse.info("Device 00:11:22:33:44:55 (public)\n\tPaired: no\n").name, nil)

check("a dashed-MAC alias means unnamed", Parse.info(DISCOVERED).name, nil)

if failures > 0 then
    print(failures .. " failure(s)")
    os.exit(1)
end
print("all bluetoothctl_parse tests passed")
