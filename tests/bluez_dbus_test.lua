-- Run from the repo root: luajit tests/bluez_dbus_test.lua
-- Replies are the anonymised reader fixture or synthetic, with made-up MACs.
package.path = "bluetooth.koplugin/?.lua;" .. package.path
package.preload["gettext"] = function() return function(s) return s end end
local warnings = {}
package.preload["logger"] = function()
    local noop = function() end
    return { dbg = noop, info = noop, err = noop, warn = function(...) table.insert(warnings, table.concat({ ... }, " ")) end }
end
package.preload["ui/uimanager"] = function() return {} end

local Bluez = require("bluetooth/controller/bluez")
local BluezDbus = require("bluetooth/controller/bluez_dbus")
local Dbus = require("bluetooth/controller/dbus")

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

local HEADER = "method return time=0 sender=:1.1 -> destination=:1.2 serial=1 reply_serial=2\n"
local OBJECTS = readFile("tests/fixtures/dbus_managed_objects.txt")
local SERVICE_UNKNOWN = "Error org.freedesktop.DBus.Error.ServiceUnknown: The name org.bluez was not provided by any .service files\n"
local ACCESS_DENIED = "Error org.freedesktop.DBus.Error.AccessDenied: Rejected send message\n"
local LISTING = "Device 00:11:22:33:44:55 Test Pager\n"

-- Fakes bluez.capture: answers are matched by a substring of the command.
-- An answer of false simulates a timeout (exit 124).
local calls
local function fake(answers)
    calls = {}
    BluezDbus.reset()
    Bluez.paired_command = nil
    Bluez.capture = function(cmd)
        table.insert(calls, cmd)
        Bluez.last_rc = 0
        for key, answer in pairs(answers) do
            if cmd:find(key, 1, true) then
                if answer == false then Bluez.last_rc = 124; return "" end
                return answer
            end
        end
        return ""
    end
end
local function ranBluetoothctl()
    for _, c in ipairs(calls) do if c:find("^bluetoothctl") then return true end end
    return false
end

-- Commands
check("command", Dbus.command("org.bluez", "/", "org.freedesktop.DBus.ObjectManager.GetManagedObjects"),
    "dbus-send --system --print-reply --reply-timeout=4000 --dest=org.bluez / org.freedesktop.DBus.ObjectManager.GetManagedObjects")
check("command with arguments", Dbus.command("org.bluez", "/org/bluez/hci0", "org.freedesktop.DBus.Properties.Get",
    "string:org.bluez.Adapter1", "string:Powered"):match("string:Powered$"), "string:Powered")
check("unsafe argument refused", Dbus.command("org.bluez", "/; reboot", "x.y"), nil)
check("unsafe typed argument refused", Dbus.command("org.bluez", "/", "x.y", "string:$(id)"), nil)
check("device path", Dbus.devicePath("/org/bluez/hci0", "aa:bb:cc:dd:ee:ff"), "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF")
check("device path needs a MAC", Dbus.devicePath("/org/bluez/hci0", "not a mac"), nil)

-- Blocking read
fake({ GetManagedObjects = OBJECTS })
local devices = BluezDbus:knownDevices()
check("reads both devices", devices and #devices, 2)
check("device carries full state", devices[2].paired and devices[2].trusted, true)
check("all devices skip per-device reads", devices[1].skip_info and devices[2].skip_info, true)
check("devices act through the Fast backend", devices[1].backend, BluezDbus)
check("no bluetoothctl", ranBluetoothctl(), false)

-- Radio off: no bluetoothd, a failed read, still Fast
fake({ GetManagedObjects = SERVICE_UNKNOWN })
check("radio off is a failed read", BluezDbus:knownDevices(), nil)
check("radio off keeps Fast", BluezDbus.isBroken(), false)

-- Timed out
fake({ GetManagedObjects = false })
check("timeout is a failed read", BluezDbus:knownDevices(), nil)
check("timeout keeps Fast", BluezDbus.isBroken(), false)

-- bluetoothd refuses one call: D-Bus works, so stay
fake({ GetManagedObjects = "Error org.bluez.Error.NotReady: Resource Not Ready\n" })
check("bluez error is a failed read", BluezDbus:knownDevices(), nil)
check("bluez error keeps Fast", BluezDbus.isBroken(), false)

-- Access denied: fall back and answer through bluetoothctl in the same call
fake({ GetManagedObjects = ACCESS_DENIED, ["bluetoothctl devices"] = LISTING, ["bluetoothctl paired-devices"] = LISTING })
devices = BluezDbus:knownDevices()
check("access denied switches to Compatible", BluezDbus.isBroken(), true)
check("same read answered by bluetoothctl", devices and #devices, 1)
check("fallback is logged", #warnings > 0 and warnings[#warnings]:find("Compatible", 1, true) ~= nil, true)
calls = {}
BluezDbus:knownDevices()
check("later reads skip D-Bus", calls[1], "bluetoothctl devices")
BluezDbus.reset()
check("reset retries Fast", BluezDbus.isBroken(), false)

-- Garbage (dbus-send gone, or a format we can't read) also falls back
fake({ GetManagedObjects = "sh: dbus-send: not found\n", ["bluetoothctl devices"] = LISTING })
BluezDbus:knownDevices()
check("unparseable reply switches to Compatible", BluezDbus.isBroken(), true)

-- Power state (plain BlueZ only; PocketBook asks netagent)
fake({ ["string:Powered"] = HEADER .. "   variant       boolean true\n" })
check("powered", BluezDbus:status(), true)
fake({ ["string:Powered"] = SERVICE_UNKNOWN })
check("no bluetoothd reads as off", BluezDbus:status(), false)

-- One device's state, for the connect poll
fake({ GetAll = HEADER .. [[
   array [
      dict entry(
         string "Address"
         variant             string "00:11:22:33:44:55"
      )
      dict entry(
         string "Connected"
         variant             boolean true
      )
      dict entry(
         string "Paired"
         variant             boolean true
      )
   ]
]] })
local info = BluezDbus:readInfo("00:11:22:33:44:55")
check("readInfo connected", info and info.connected, true)
check("readInfo asks the right path", calls[1]:find("/org/bluez/hci0/dev_00_11_22_33_44_55 ", 1, true) ~= nil, true)
-- A removed device answers UnknownObject: read as unpaired, so the unpair
-- poll confirms, as bluetoothctl's "not available" does (2026-10-26).
fake({ GetAll = "Error org.freedesktop.DBus.Error.UnknownObject: no such device\n" })
local gone = BluezDbus:readInfo("00:11:22:33:44:55")
check("removed device reads as unpaired", gone and gone.paired, false)
check("removed device keeps Fast", BluezDbus.isBroken(), false)
fake({ GetAll = SERVICE_UNKNOWN })
check("radio off is still a failed read", BluezDbus:readInfo("00:11:22:33:44:55"), nil)
fake({ GetAll = ACCESS_DENIED, ["bluetoothctl info"] = "Device 00:11:22:33:44:55 (public)\n\tPaired: yes\n\tConnected: yes\n" })
info = BluezDbus:readInfo("00:11:22:33:44:55")
check("readInfo falls back to bluetoothctl info", info and info.connected, true)

-- Background read
local pending
Bluez.runAsync = function(script, done) pending = { script = script, done = done } end
local got
local function snapshot(text)
    got = "unset"
    BluezDbus:readSnapshot(function(d) got = d end)
    pending.done(text)
end
BluezDbus.reset()
Bluez.timeout_style = "k"
snapshot(OBJECTS .. "@@rc 0\n")
check("snapshot script is guarded by timeout", pending.script:find("^timeout %-k 1 5 dbus%-send") ~= nil, true)
-- BusyBox 1.22 has no -k; the script must follow the detected style.
local saved_style = Bluez.timeout_style
Bluez.timeout_style = "t"
check("snapshot script uses BusyBox 1.22 timeout", BluezDbus:snapshotScript():find("^timeout %-t 5 %-s KILL dbus%-send") ~= nil, true)
Bluez.timeout_style = "none"
check("snapshot script without timeout", BluezDbus:snapshotScript():find("^dbus%-send") ~= nil, true)
Bluez.timeout_style = saved_style
check("snapshot reads devices", type(got) == "table" and #got, 2)
snapshot(nil)
check("snapshot that never finished fails", got, nil)
snapshot("@@rc 124\n")
check("killed snapshot fails", got, nil)
snapshot(SERVICE_UNKNOWN .. "@@rc 1\n")
check("snapshot with radio off fails", got, nil)
check("snapshot with radio off keeps Fast", BluezDbus.isBroken(), false)

-- Pairing needs an agent and scanning a long-lived client, so both stay on
-- bluetoothctl; device actions are Fast mode's own (stage 3).
check("connect is Fast mode's", BluezDbus.connect ~= Bluez.connect, true)
check("pair is bluetoothctl's", BluezDbus.pair, Bluez.pair)
check("search is bluetoothctl's", BluezDbus.search, Bluez.search)

-- Device actions (stage 3): one background dbus-send each, errors logged by
-- name, a D-Bus that can't work here falls back to bluetoothctl.
do
    local MAC = "00:11:22:33:44:55"
    local PATH = "/org/bluez/hci0/dev_00_11_22_33_44_55"
    local scripts, answer = {}, nil
    Bluez.timeout_style = "k"
    Bluez.runAsync = function(script, done) table.insert(scripts, script); done(answer) end
    local fell_back = {}
    for _, name in ipairs({ "connect", "disconnect", "trust", "untrust", "block", "unblock", "unpair" }) do
        Bluez[name .. "_saved"] = Bluez[name]
        Bluez[name] = function(_, mac) table.insert(fell_back, name .. " " .. mac) end
    end
    local function run(name, reply)
        scripts, fell_back, warnings = {}, {}, {}
        BluezDbus.reset()
        answer = reply
        BluezDbus[name](BluezDbus, MAC)
        return scripts[1] or ""
    end
    local OK = HEADER .. "@@rc 0\n"

    local s = run("connect", OK)
    check("connect: Device1.Connect on the device path", s:find(PATH .. " org.bluez.Device1.Connect", 1, true) ~= nil, true)
    check("connect: longer reply timeout", s:find("--reply-timeout=10000", 1, true) ~= nil, true)
    check("connect: outer timeout above the reply timeout", s:find("^timeout %-k 1 12 ") ~= nil, true)
    check("connect: success needs no fallback", #fell_back, 0)
    s = run("disconnect", OK)
    check("disconnect: Device1.Disconnect", s:find(PATH .. " org.bluez.Device1.Disconnect", 1, true) ~= nil, true)
    s = run("trust", OK)
    check("trust: sets Trusted true", s:find("string:org.bluez.Device1 string:Trusted variant:boolean:true", 1, true) ~= nil, true)
    s = run("untrust", OK)
    check("untrust: sets Trusted false", s:find("string:Trusted variant:boolean:false", 1, true) ~= nil, true)
    s = run("block", OK)
    check("block: sets Blocked true", s:find("string:Blocked variant:boolean:true", 1, true) ~= nil, true)
    s = run("unblock", OK)
    check("unblock: sets Blocked false", s:find("string:Blocked variant:boolean:false", 1, true) ~= nil, true)
    s = run("unpair", OK)
    check("unpair: Adapter1.RemoveDevice with the path", s:find("/org/bluez/hci0 org.bluez.Adapter1.RemoveDevice objpath:" .. PATH, 1, true) ~= nil, true)

    run("connect", "Error org.bluez.Error.AlreadyConnected: Already Connected\n@@rc 1\n")
    check("already connected: not a failure", #warnings + #fell_back, 0)
    run("unpair", "Error org.bluez.Error.DoesNotExist: Does Not Exist\n@@rc 1\n")
    check("remove twice: not a failure", #warnings + #fell_back, 0)

    run("connect", "Error org.bluez.Error.Failed: br-connection-page-timeout\n@@rc 1\n")
    check("bluez error: logged by name", warnings[1] ~= nil and warnings[1]:find("org.bluez.Error.Failed", 1, true) ~= nil, true)
    check("bluez error: stays in Fast", BluezDbus.isBroken() == false and #fell_back == 0, true)

    run("trust", ACCESS_DENIED .. "@@rc 1\n")
    check("access denied: falls back to bluetoothctl", fell_back[1], "trust " .. MAC)
    check("access denied: session switches to Compatible", BluezDbus.isBroken(), true)

    run("disconnect", "@@rc 124\n")
    check("timeout: warned, no fallback", #warnings == 1 and #fell_back == 0, true)

    -- Already in Compatible: straight to bluetoothctl, no dbus-send.
    scripts, fell_back = {}, {}
    BluezDbus.broken = "test"
    BluezDbus:connect(MAC)
    check("broken session: bluetoothctl only", #scripts == 0 and fell_back[1] == "connect " .. MAC, true)
    -- A MAC that can't make a path never reaches the shell.
    BluezDbus.reset()
    scripts, fell_back = {}, {}
    BluezDbus:connect("not-a-mac; reboot")
    check("bad mac: no dbus-send", #scripts, 0)

    for _, name in ipairs({ "connect", "disconnect", "trust", "untrust", "block", "unblock", "unpair" }) do
        Bluez[name] = Bluez[name .. "_saved"]
        Bluez[name .. "_saved"] = nil
    end
    BluezDbus.reset()
end

if failures > 0 then
    print(failures .. " failure(s)")
    os.exit(1)
end
print("all bluez_dbus tests passed")
