-- Run from the repo root: luajit tests/controller_test.lua
package.path = "bluetooth.koplugin/?.lua;" .. package.path
package.preload["gettext"] = function() return function(s) return s end end
package.preload["logger"] = function()
    local noop = function() end
    return { dbg = noop, info = noop, warn = noop, err = noop }
end
package.preload["device"] = function()
    local d = {}
    function d:isAndroid() return false end
    function d:isPocketBook() return true end
    function d:isEmulator() return false end
    function d:isDesktop() return false end
    return d
end
package.preload["ui/widget/infomessage"] = function() return { new = function() return {} end } end

-- Scheduled work runs only when the test says so, so a stray enable/disable
-- shows up as a queued task instead of vanishing.
local queue = {}
package.preload["ui/uimanager"] = function()
    return {
        show = function() end,
        scheduleIn = function(_, _, fn) table.insert(queue, fn) end,
    }
end

-- One fake backend stands in for the real PocketBook one, which would shell
-- out to netagent and bluetoothctl.
local fake = {}
package.preload["bluetooth/controller/pocketbook"] = function()
    return { new = function() return fake end }
end

local controller = require("bluetooth/controller/controller")

local failures = 0
local function check(cond, message)
    if not cond then
        failures = failures + 1
        print("FAIL " .. message)
    end
end

-- Builds a controller on the PocketBook backend with a fake radio. The
-- backend table the controller picked is replaced wholesale.
local function build(radio_on, store_data)
    local calls = {}
    fake.status = function() return radio_on end
    fake.enable = function() calls.enable = (calls.enable or 0) + 1 end
    fake.disable = function() calls.disable = (calls.disable or 0) + 1 end
    fake.knownDevices = function() calls.read = (calls.read or 0) + 1; return {} end
    local c = controller:new({
        device_store = { data = store_data or {}, get = function(self, mac) return self.data[mac] end,
            saveAll = function() calls.saved = (calls.saved or 0) + 1 end },
    })
    return c, calls
end

-- Radio off: serve the cache, never touch power, call back once.
do
    local c, calls = build(false, {
        ["AA:AA"] = { mac = "AA:AA", name = "Keyboard", paired = true, connected = true, starred = true },
    })
    c:status()
    local fired = 0
    local list = c:knownDevices(function(ok) fired = fired + 1; check(ok == true, "off: callback true") end)
    check(#list == 1 and list[1].name == "Keyboard", "off: cached device returned")
    check(list[1].connected == false, "off: cached device is not connected")
    check(list[1].starred == true, "off: starred restored")
    check(fired == 1, "off: callback fired exactly once, got " .. fired)
    check(not calls.enable and not calls.disable and not calls.read, "off: no power change or live read")
    check(#queue == 0, "off: nothing scheduled")
end

-- Radio off with an empty cache: empty list, no error.
do
    local c = build(false)
    c:status()
    check(#c:knownDevices() == 0, "cold cache: empty list")
end

-- Radio on: live read, then cache written.
do
    local c, calls = build(true)
    calls.read, calls.saved = nil, nil -- construction already read once
    c:status()
    c:knownDevices()
    check(calls.read == 1, "on: live read")
    check(calls.saved == 1, "on: cache persisted")
    check(not calls.enable and not calls.disable, "on: no power change")
end

if failures > 0 then os.exit(1) end
print("controller_test: ok")
