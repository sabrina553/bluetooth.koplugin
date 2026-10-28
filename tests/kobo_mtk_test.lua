-- Run from the repo root: luajit tests/kobo_mtk_test.lua
-- Replies are synthetic, shaped like dbus-send output, with made-up MACs.
package.path = "bluetooth.koplugin/?.lua;tests/?.lua;" .. package.path
local helpers = require("helpers")
package.preload["gettext"] = function() return function(s) return s end end
local logs = {}
package.preload["logger"] = function()
    local function log(...) table.insert(logs, table.concat({ ... }, " ")) end
    return { dbg = log, info = log, warn = log, err = log }
end
local scheduled = {}
package.preload["ui/uimanager"] = function()
    return { scheduleIn = function(_, _, fn) table.insert(scheduled, fn) end }
end
local input_opened = {}
package.preload["device"] = function()
    return { input = { open = function(_, path) table.insert(input_opened, path) end } }
end
-- Never loaded for real: tests set KoboMTK.network.
package.preload["ui/network/manager"] = function() return {} end

local Bluez = require("bluetooth/controller/bluez")
local BluezDbus = require("bluetooth/controller/bluez_dbus")
local Contract = require("bluetooth/controller/backend_contract")
local KoboMTK = require("bluetooth/controller/kobo_mtk")

local failures = 0
local function check(cond, message)
    helpers.rejectDescription(cond)
    if not cond then
        failures = failures + 1
        print("FAIL " .. message)
    end
end

local HEADER = "method return time=0 sender=:1.1 -> destination=:1.2 serial=1 reply_serial=2\n"
local TRUE = HEADER .. "   boolean true\n"
local FALSE = HEADER .. "   boolean false\n"
local POWERED = HEADER .. "   variant       boolean true\n"
local ACCESS_DENIED = "Error org.freedesktop.DBus.Error.AccessDenied: Rejected send message\n"
local MAC = "00:11:22:33:44:55"

-- Commands are recorded in order; answers are matched by a substring.
local calls, scripts, async_reply
local function fake(answers)
    calls, scripts, logs, scheduled = {}, {}, {}, {}
    KoboMTK.used = false
    KoboMTK.enabling = false
    BluezDbus.reset()
    Bluez.timeoutPrefix = function(secs) return "timeout " .. secs .. " " end
    Bluez.capture = function(cmd)
        table.insert(calls, cmd)
        Bluez.last_rc = 0
        for key, answer in pairs(answers or {}) do
            if cmd:find(key, 1, true) then return answer end
        end
        return ""
    end
    Bluez.runAsync = function(script, done)
        table.insert(scripts, script)
        done(async_reply)
    end
end
local function ran(word, list)
    for _, c in ipairs(list or calls) do
        if c:find(word, 1, true) then return true end
    end
    return false
end
local function runScheduled()
    local fns = scheduled
    scheduled = {}
    for _, fn in ipairs(fns) do fn() end
end

local network
local function stubNetwork(wifi_on)
    network = { order = {} }
    function network:isWifiOn() return wifi_on end
    function network:restoreWifiAsync() table.insert(self.order, "wifi on") end
    function network:disableWifi() table.insert(self.order, "wifi off") end
    KoboMTK.network = network
end

local kobo = KoboMTK:new()

local ok, problems = Contract.check(kobo)
check(ok, "KoboMTK meets the contract: " .. table.concat(problems, "; "))
check(kobo.capabilities.transport == false, "no Fast/Compatible choice on Kobo")
check(kobo.service == "com.kobo.mtk.bluedroid", "talks to Kobo's service")

-- Status: service not running means off, and nothing was used.
fake({ NameHasOwner = FALSE })
check(kobo:status() == false, "status: service not owned reads off")
check(KoboMTK.used == false, "status: not owned leaves used false")
fake({ NameHasOwner = TRUE, ["Properties.Get"] = POWERED })
check(kobo:status() == true, "status: owned and powered reads on")
check(KoboMTK.used == true, "status: owned marks used")

-- A D-Bus error never falls back to bluetoothctl or sets the shared flag.
fake({ NameHasOwner = TRUE, ["Properties.Get"] = ACCESS_DENIED, GetManagedObjects = ACCESS_DENIED })
kobo:status()
kobo:knownDevices()
check(not ran("bluetoothctl"), "errors: no bluetoothctl")
check(BluezDbus.broken == nil, "errors: shared broken flag untouched")
BluezDbus.broken = "set by another backend"
fake({ NameHasOwner = TRUE, ["Properties.Get"] = POWERED })
BluezDbus.broken = "set by another backend"
check(kobo:status() == true and not ran("bluetoothctl"), "errors: ignores BluezDbus's broken flag")
BluezDbus.reset()

-- Enable with Wi-Fi off: Wi-Fi on, wait, power sequence, Wi-Fi off.
stubNetwork(false)
async_reply = "@@rc 0\n"
fake()
kobo:enable()
check(#network.order == 1 and network.order[1] == "wifi on", "wifi off: turned on first")
check(#scripts == 0, "wifi off: power waits for the scheduled step")
runScheduled()
check(#scripts == 1, "wifi off: one power script after the wait")
local script = scripts[1] or ""
local on_at = script:find("BluedroidManager1.On", 1, true)
local set_at = script:find("variant:boolean:true", 1, true)
check(on_at and set_at and on_at < set_at, "power: manager On before Powered")
check(script:find("BluedroidManager1.Off", 1, true) ~= nil, "power: rollback Off in the script")
check(network.order[2] == "wifi off", "wifi off: switched off again after powering")

-- A second tap during the Wi-Fi wait doesn't start a second power-up.
stubNetwork(false)
fake()
kobo:enable()
kobo:enable()
check(#network.order == 1, "double enable: Wi-Fi switched on once")
check(#scheduled == 1, "double enable: one power-up waiting")
runScheduled()
check(#scripts == 1, "double enable: one power script")
kobo:enable()
check(#scheduled == 1, "double enable: enabling again works once the first finished")

-- Wi-Fi already on: no juggling, and it stays on.
stubNetwork(true)
fake()
kobo:enable()
check(#scripts == 1, "wifi on: power straight away")
check(#network.order == 0, "wifi on: Wi-Fi left alone")

-- A failed Powered set reports failure in the log (the script rolls back).
stubNetwork(true)
async_reply = "@@failed powered\n@@rc 1\n"
fake()
kobo:enable()
check(ran("power on failed", logs), "power failure is logged")

-- Disable: Powered false, then manager Off.
async_reply = "@@rc 0\n"
fake()
kobo:disable()
local off = scripts[1] or ""
local p_at = off:find("variant:boolean:false", 1, true)
local o_at = off:find("BluedroidManager1.Off", 1, true)
check(p_at and o_at and p_at < o_at, "disable: Powered false before manager Off")

-- Search: start discovery now, stop after the duration.
fake()
kobo:search(7)
check(ran("StartDiscovery") and not ran("StopDiscovery"), "search: discovery started")
runScheduled()
check(ran("StopDiscovery"), "search: discovery stopped when the timer fires")

-- Pair: Device1.Pair in the background; result reaches on_done.
local result = "unset"
async_reply = HEADER .. "@@rc 0\n"
fake()
local started = kobo:pair(MAC, function(r) result = r end)
check(started == true, "pair: started")
check(ran("org.bluez.Device1.Pair", scripts), "pair: Device1.Pair")
check(result == true, "pair: success reaches on_done")
async_reply = "Error org.bluez.Error.AuthenticationFailed: Authentication Failed\n@@rc 1\n"
fake()
kobo:pair(MAC, function(r) result = r end)
check(result == false, "pair: failure reaches on_done")
local refused, reason = kobo:pair("not a mac")
check(refused == false and reason == "invalid", "pair: bad MAC refused")

-- Connect: after the link settles, a new uhid input device is opened.
async_reply = "@@rc 0\n"
fake({ ["/sys/class/input/event"] = "/sys/class/input/event4 ../../devices/virtual/misc/uhid/x/input/input4/event4\n" })
kobo:connect(MAC)
check(ran("org.bluez.Device1.Connect", scripts), "connect: Device1.Connect")
check(#input_opened == 0, "connect: input not opened before the link settles")
runScheduled()
check(input_opened[1] == "/dev/input/event4", "connect: remote's input device opened")

-- A bad MAC never falls through to bluetoothctl (review 2026-10-28).
local fell_back = {}
local saved = { connect = Bluez.connect, info = Bluez.info }
Bluez.connect = function() table.insert(fell_back, "connect") end
Bluez.info = function() table.insert(fell_back, "info") return "" end
fake()
kobo:connect("not a mac")
kobo:readInfo("not a mac")
check(#fell_back == 0, "bad MAC: no bluetoothctl fallback, got " .. table.concat(fell_back, ","))
Bluez.connect, Bluez.info = saved.connect, saved.info

-- A device read that shows a newly connected device checks for its input
-- device too, so a remote that reconnects by itself is opened.
local listed = {}
local saved_from = BluezDbus.devicesFrom
BluezDbus.devicesFrom = function() return listed end
fake({ ["/sys/class/input/event"] = "/sys/class/input/event6 ../../devices/virtual/misc/uhid/y/input/input6/event6\n" })
input_opened = {}
listed = { { mac = MAC, connected = false } }
kobo:devicesFrom({})
runScheduled()
check(#input_opened == 0, "devices: nothing connected, no input check")
listed = { { mac = MAC, connected = true } }
kobo:devicesFrom({})
runScheduled()
check(input_opened[1] == "/dev/input/event6", "devices: newly connected device gets its input opened")
input_opened = {}
kobo:devicesFrom({})
check(#scheduled == 0, "devices: same connected set, no new check")
BluezDbus.devicesFrom = saved_from

for _, line in ipairs(logs) do
    check(not line:find(MAC, 1, true), "MAC unmasked in log: " .. line)
end

if failures > 0 then
    os.exit(1)
end
print("kobo_mtk_test: ok")
