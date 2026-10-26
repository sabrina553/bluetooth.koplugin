-- Run from the repo root: luajit tests/dbus_events_test.lua
-- Fixtures follow signals recorded on the reader (2026-10-26) with made-up
-- MACs and no device names.
package.path = "bluetooth.koplugin/?.lua;" .. package.path

local DbusEvents = require("bluetooth/controller/dbus_events")

local failures = 0
local function check(description, actual, expected)
    if actual ~= expected then
        failures = failures + 1
        print(("FAIL %s: got %s, expected %s"):format(description, tostring(actual), tostring(expected)))
    end
end

local function readFile(path)
    local f = assert(io.open(path, "r"))
    local text = f:read("*a")
    f:close()
    return text
end

local NOISE = readFile("tests/fixtures/dbus_signals.txt")
local CONNECTED = readFile("tests/fixtures/dbus_signals_relevant.txt")

-- Advertising, RSSI, GATT services and adapter interfaces are not drawn.
check("noise is ignored", DbusEvents.feed(DbusEvents.newState(), NOISE), false)
check("a Connected change counts", DbusEvents.feed(DbusEvents.newState(), CONNECTED), true)
check("noise then a change counts", DbusEvents.feed(DbusEvents.newState(), NOISE .. CONNECTED), true)

-- A chunk can end anywhere: mid-line or mid-signal. Every split point must
-- still find the change once it has all arrived.
local text = NOISE .. CONNECTED
for cut = 1, #text - 1 do
    local state = DbusEvents.newState()
    local a = DbusEvents.feed(state, text:sub(1, cut))
    local b = DbusEvents.feed(state, text:sub(cut + 1))
    if not (a or b) then
        check("split at " .. cut .. " still finds the change", false, true)
        break
    end
end

-- The property name alone, cut off before its line ends, does not count yet.
local state = DbusEvents.newState()
local head = CONNECTED:sub(1, CONNECTED:find('"Connected"', 1, true) + 4)
check("half a line is held back", DbusEvents.feed(state, head), false)
check("the rest of the line completes it", DbusEvents.feed(state, CONNECTED:sub(#head + 1)), true)

-- The same names inside a value do not count (only dict keys do).
local value = 'signal time=6 sender=:1.1 -> destination=(null destination) serial=6 path=/org/bluez/hci0/dev_00_11_22_33_44_03; interface=org.freedesktop.DBus.Properties; member=PropertiesChanged\n'
    .. '   string "org.bluez.Device1"\n   array [\n      dict entry(\n         string "Icon"\n'
    .. '         variant             string "Connected"\n      )\n   ]\n'
check("a value that reads Connected is not a key", DbusEvents.feed(DbusEvents.newState(), value), false)

-- A device appearing or going away counts; its services do not.
local added = 'signal time=7 sender=:1.1 -> destination=(null destination) serial=7 path=/; interface=org.freedesktop.DBus.ObjectManager; member=InterfacesAdded\n'
    .. '   object path "/org/bluez/hci0/dev_00_11_22_33_44_04"\n   array [\n   ]\n'
check("a new device counts", DbusEvents.feed(DbusEvents.newState(), added), true)
local removed = added:gsub("InterfacesAdded", "InterfacesRemoved")
check("a removed device counts", DbusEvents.feed(DbusEvents.newState(), removed), true)

-- Radio going off: the adapter's Powered changes.
local powered = 'signal time=8 sender=:1.1 -> destination=(null destination) serial=8 path=/org/bluez/hci0; interface=org.freedesktop.DBus.Properties; member=PropertiesChanged\n'
    .. '   string "org.bluez.Adapter1"\n   array [\n      dict entry(\n         string "Powered"\n         variant             boolean false\n      )\n   ]\n'
check("adapter power counts", DbusEvents.feed(DbusEvents.newState(), powered), true)

if failures > 0 then
    print(failures .. " failure(s)")
    os.exit(1)
end
print("all dbus_events tests passed")
