-- Run from the repo root: luajit tests/bluez_test.lua
package.path = "bluetooth.koplugin/?.lua;" .. package.path
package.preload["gettext"] = function() return function(s) return s end end
package.preload["logger"] = function()
    local noop = function() end
    return { dbg = noop, info = noop, warn = noop, err = noop }
end
package.preload["ui/uimanager"] = function() return {} end

local Bluez = require("bluetooth/controller/bluez")

local failures = 0
local function check(description, actual, expected)
    if actual ~= expected then
        failures = failures + 1
        print(("FAIL %s: got %s, expected %s"):format(description, tostring(actual), tostring(expected)))
    end
end

local ALL = table.concat({
    "Device 00:11:22:33:44:55 Test Pager",
    "Device 66:77:88:99:AA:BB 66-77-88-99-AA-BB",
    "Device 12:34:56:78:9A:BC Some Speaker",
    "",
}, "\n")
local PAIRED = "Device 00:11:22:33:44:55 Test Pager\n"

-- Replaces Bluez.capture with canned answers and records the calls made.
local function fakeBluetoothctl(answers)
    local calls = {}
    Bluez.paired_command = nil
    Bluez.capture = function(cmd)
        table.insert(calls, cmd)
        return answers[cmd] or ""
    end
    return calls
end

local function count(calls, cmd)
    local n = 0
    for _, c in ipairs(calls) do if c == cmd then n = n + 1 end end
    return n
end

-- Newer BlueZ: `devices Paired` works
local calls = fakeBluetoothctl({
    ["bluetoothctl devices"] = ALL,
    ["bluetoothctl devices Paired"] = PAIRED,
})
local devices = Bluez:knownDevices()
check("lists every device", #devices, 3)
check("paired device is marked paired", devices[1].paired, true)
check("paired device still gets info", devices[1].skip_info, false)
check("unpaired device is not paired", devices[2].paired, false)
check("unpaired device skips info", devices[2].skip_info, true)
check("new BlueZ never tries the old command", count(calls, "bluetoothctl paired-devices"), 0)

-- BlueZ 5.52: `devices Paired` is rejected, `paired-devices` works
calls = fakeBluetoothctl({
    ["bluetoothctl devices"] = ALL,
    ["bluetoothctl devices Paired"] = "\27[1;39mToo many arguments\27[0m\n",
    ["bluetoothctl paired-devices"] = PAIRED,
})
devices = Bluez:knownDevices()
check("old BlueZ: paired device found", devices[1].paired, true)
check("old BlueZ: unpaired skips info", devices[3].skip_info, true)
check("old BlueZ: remembers the working command", Bluez.paired_command, "bluetoothctl paired-devices")
Bluez:knownDevices()
check("old BlueZ: does not retry the rejected command", count(calls, "bluetoothctl devices Paired"), 1)

-- Nothing paired is a valid answer, not an error
fakeBluetoothctl({ ["bluetoothctl devices"] = ALL, ["bluetoothctl devices Paired"] = "" })
devices = Bluez:knownDevices()
check("nothing paired: nobody is paired", devices[1].paired, false)
check("nothing paired: info is skipped", devices[1].skip_info, true)

-- No command understood: fall back to asking about every device
fakeBluetoothctl({
    ["bluetoothctl devices"] = ALL,
    ["bluetoothctl devices Paired"] = "Invalid command in menu main: devices\n",
    ["bluetoothctl paired-devices"] = "Invalid command in menu main: paired-devices\n",
})
devices = Bluez:knownDevices()
check("unknown BlueZ: nothing is skipped", devices[2].skip_info, nil)

if failures > 0 then
    print(failures .. " failure(s)")
    os.exit(1)
end
print("all bluez tests passed")
