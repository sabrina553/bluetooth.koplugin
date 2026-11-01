-- Run from the repo root: luajit tests/dbus_parse_test.lua
-- tests/fixtures/dbus_managed_objects.txt is a real GetManagedObjects reply
-- from the PocketBook (BlueZ 5.52, 2026-10-13) with MACs and names replaced by
-- made-up ones. Other fixtures are synthetic, laid out like dbus-send's output.
package.path = "bluetooth.koplugin/?.lua;" .. package.path
local DbusParse = require("bluetooth/controller/dbus_parse")

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

-- GetManagedObjects from the reader
local objects = DbusParse.managedObjects(readFile("tests/fixtures/dbus_managed_objects.txt"))
check("managed objects parse", type(objects), "table")
local adapter = objects.adapters["/org/bluez/hci0"]
check("adapter found", type(adapter), "table")
check("adapter powered", adapter.Powered, true)
check("adapter discovering", adapter.Discovering, false)
check("adapter class is a number", adapter.Class, 524288)
check("adapter UUIDs are a list", #adapter.UUIDs, 6)
check("two devices", #objects.devices, 2)

local phone, remote = objects.devices[1], objects.devices[2]
check("devices sorted by path", phone.path, "/org/bluez/hci0/dev_00_11_22_33_44_02")
check("mac from Address", phone.mac, "00:11:22:33:44:02")
check("name from Alias", phone.name, "Test Phone")
check("unpaired", phone.paired, false)
check("remote name", remote.name, "Kobo Remote")
check("remote paired", remote.paired, true)
check("remote trusted", remote.trusted, true)
check("remote not blocked", remote.blocked, false)
check("remote not connected", remote.connected, false)
check("Bonded missing on 5.52 reads false", remote.bonded, false)

-- Synthetic replies
local HEADER = "method return time=0 sender=:1.1 -> destination=:1.2 serial=1 reply_serial=2\n"

local UNNAMED = HEADER .. [[
   array [
      dict entry(
         object path "/org/bluez/hci0/dev_00_11_22_33_44_55"
         array [
            dict entry(
               string "org.bluez.Device1"
               array [
                  dict entry(
                     string "Address"
                     variant                         string "00:11:22:33:44:55"
                  )
                  dict entry(
                     string "Alias"
                     variant                         string "00-11-22-33-44-55"
                  )
                  dict entry(
                     string "Connected"
                     variant                         boolean true
                  )
                  dict entry(
                     string "ManufacturerData"
                     variant                         array [
                           dict entry(
                              uint16 76
                              variant                                 array of bytes [
                                    02 15 aa bb
                                 ]
                           )
                        ]
                  )
               ]
            )
         ]
      )
   ]
]]
local unnamed = DbusParse.managedObjects(UNNAMED)
check("unnamed device parses", unnamed and #unnamed.devices, 1)
check("a dashed-MAC alias means unnamed", unnamed and unnamed.devices[1].name, nil)
check("connected", unnamed and unnamed.devices[1].connected, true)
check("no adapter in reply", unnamed and next(unnamed.adapters), nil)

local values = DbusParse.reply(UNNAMED)
local data = values[1]["/org/bluez/hci0/dev_00_11_22_33_44_55"]["org.bluez.Device1"].ManufacturerData
check("byte array rows kept as text", data[76][1], "02 15 aa bb")

check("property reply", DbusParse.property(HEADER .. "   variant       boolean true\n"), true)
check("property false", DbusParse.property(HEADER .. "   variant       boolean false\n"), false)
check("property string", DbusParse.property(HEADER .. '   variant       string "a \\"quoted\\" name"\n'), 'a \\"quoted\\" name')

local value, err, msg = DbusParse.property("Error org.freedesktop.DBus.Error.ServiceUnknown: The name org.bluez was not provided by any .service files\n")
check("error reply has no value", value, nil)
check("error name", err, "org.freedesktop.DBus.Error.ServiceUnknown")
check("error message", msg, "The name org.bluez was not provided by any .service files")

value, err = DbusParse.reply("Error org.bluez.Error.Failed: No discovery started")
check("bluez error name", err, "org.bluez.Error.Failed")

value, err = DbusParse.reply("")
check("empty output is a parse failure", err, "parse")
value, err = DbusParse.reply("sh: dbus-send: not found\n")
check("missing binary is a parse failure", err, "parse")
value, err = DbusParse.reply(HEADER .. "   array [\n      string \"cut off\"\n")
check("truncated reply is a parse failure", err, "parse")
value, err = DbusParse.reply(HEADER .. "   ]\n")
check("stray close is a parse failure", err, "parse")
check("empty method return parses", #DbusParse.reply(HEADER), 0)
value, err = DbusParse.property(HEADER)
check("property needs a value", err, "parse")

if failures > 0 then
    print(failures .. " failure(s)")
    os.exit(1)
end
print("all dbus_parse tests passed")
