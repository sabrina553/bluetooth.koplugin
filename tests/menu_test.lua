-- Run from the repo root: luajit tests/menu_test.lua
-- KOReader's widgets are stubbed; shown messages are recorded so the tests
-- can read their text and timeout.
package.path = "bluetooth.koplugin/?.lua;" .. package.path
package.preload["gettext"] = function() return function(s) return s end end
package.preload["logger"] = function()
    local noop = function() end
    return { dbg = noop, info = noop, warn = noop, err = noop }
end
package.preload["ffi/util"] = function()
    return { template = function(s, ...) local a = { ... }; return (s:gsub("%%(%d)", function(i) return tostring(a[tonumber(i)]) end)) end }
end
local shown = {}
package.preload["ui/widget/infomessage"] = function()
    return { new = function(_, o) return o end }
end
package.preload["ui/uimanager"] = function()
    return {
        show = function(_, w) table.insert(shown, w) end,
        close = function() end,
        nextTick = function(_, fn) fn() end,
        scheduleIn = function() end,
        unschedule = function() end,
        broadcastEvent = function() end,
    }
end
for _, name in ipairs({ "ui/widget/menu", "ui/widget/buttondialogtitle", "ui/event", "ui/widget/buttondialog" }) do
    package.preload[name] = function() return { new = function(_, o) return o or {} end } end
end
-- The live-updates monitor is faked: the test only needs to see starts and stops.
local monitors = {}
package.preload["bluetooth/controller/dbus_monitor"] = function()
    return { start = function()
        local m = { stopped = false }
        function m:stop() self.stopped = true end
        table.insert(monitors, m)
        return m
    end }
end

local BluetoothMenu = require("bluetooth/ui/menu")

local failures = 0
local function check(description, actual, expected)
    if actual ~= expected then
        failures = failures + 1
        print(("FAIL %s: got %s, expected %s"):format(description, tostring(actual), tostring(expected)))
    end
end
local function last() return shown[#shown] or {} end

local live = false
local mode = "fast"
local menu = BluetoothMenu:new({
    settings = { getLiveUpdates = function() return live end },
    controller = { activeMode = function() return mode end, is_enabled = true, known_devices = {} },
})
menu.refresh = function() end

-- A device whose toggle method answers with the given result.
local function device(fields, confirmed, reason, after)
    fields.name = fields.name or "Remote"
    fields.mac = fields.mac or "00:11:22:33:44:55"
    fields.calls = 0
    fields.toggleConnection = function(self, cb)
        self.calls = self.calls + 1
        if after then after(self) end
        cb(confirmed, reason)
    end
    fields.togglePair = fields.toggleConnection
    return fields
end

-- Blocked: no connect attempt, a message that says how to unblock.
do
    shown = {}
    local dev = device({ paired = true, blocked = true }, true)
    local rows = {}
    menu:pairedDevices(rows, { dev })
    rows[1].callback(nil)
    check("blocked: no connect attempted", dev.calls, 0)
    check("blocked: says how to unblock", (last().text or ""):find("is blocked. Unblock it first", 1, true) ~= nil, true)
    check("blocked: row says so", rows[1].text, "Remote (blocked)")
    dev.connected = true
    check("blocked: a link without input is not ticked", rows[1].checked_func(), false)
end

-- Starred, connected, not blocked: star prefix and a tick.
do
    local rows = {}
    menu:pairedDevices(rows, { device({ paired = true, starred = true, connected = true }, true),
        device({ paired = false, name = "Scan result" }, true) })
    check("rows: only paired devices", #rows, 1)
    check("rows: star prefix", rows[1].text, "★ Remote")
    check("rows: connected is ticked", rows[1].checked_func(), true)
end

-- Manual disconnect of a held device: the longer toast that explains it.
do
    shown = {}
    local dev = device({ paired = true, connected = true }, true, nil, function(self)
        self.connected = false; self.held = true
    end)
    local rows = {}
    menu:pairedDevices(rows, { dev })
    rows[1].callback(nil)
    check("held: explains it stays off", (last().text or ""):find("stays off until you connect it", 1, true) ~= nil, true)
    check("held: shown long enough to read", last().timeout, 2)
end

-- A plain connect: the short confirmation.
do
    shown = {}
    local dev = device({ paired = true, connected = false }, true, nil, function(self) self.connected = true end)
    local rows = {}
    menu:pairedDevices(rows, { dev })
    rows[1].callback(nil)
    check("connect: confirmation", last().text, "Connected to Remote")
    check("connect: short toast", last().timeout < 1, true)
end

-- A failed connect: the failure text, not a confirmation.
do
    shown = {}
    local dev = device({ paired = true }, false)
    local rows = {}
    menu:pairedDevices(rows, { dev })
    rows[1].callback(nil)
    check("failed: says it could not confirm", (last().text or ""):find("Could not confirm connection change", 1, true) ~= nil, true)
end

-- Busy pairing: its own message instead of "could not confirm".
do
    shown = {}
    -- performToggle with a pair-shaped action; the menu's pair entry has
    -- field "paired" and method "togglePair".
    local dev = device({ paired = false }, false, "busy")
    menu:performToggle(dev, { field = "paired", method = "togglePair", active_text = "", inactive_text = "",
        active_done_text = "", inactive_done_text = "", fail_text = "Could not confirm pairing change for " }, nil)
    check("busy: says another pairing is running", (last().text or ""):find("Another pairing is still running", 1, true) ~= nil, true)
end

-- The scan screen, where unpaired devices are paired, says why too.
do
    for _, case in ipairs({ { "busy", "Another pairing is still running" }, { "invalid", "address is not valid" } }) do
        shown = {}
        local dev = { mac = "00:11:22:33:44:55", name = "Phone", paired = false,
            pair = function(_, cb) cb(false, case[1]) end }
        menu:pairFoundDevice(dev)
        check("scan " .. case[1] .. ": says why", (last().text or ""):find(case[2], 1, true) ~= nil, true)
    end
end

-- The signature changes when a device is blocked, so the row redraws.
do
    local dev = { mac = "A", name = "Remote", paired = true }
    menu.controller.known_devices = { dev }
    local before = menu:deviceSignature()
    dev.blocked = true
    check("signature: changes on block", menu:deviceSignature() ~= before, true)
end

-- Live updates: only with the setting on, Fast mode, the radio on, and this
-- poll still current; stopped as soon as one of those goes.
do
    monitors = {}
    local token = {}
    menu._poll_token = token
    live = false
    menu:updateLiveMonitor(token)
    check("live: off by default, no monitor", #monitors, 0)
    live = true
    menu:updateLiveMonitor(token)
    check("live: on in Fast mode starts one", #monitors, 1)
    menu:updateLiveMonitor(token)
    check("live: not started twice", #monitors, 1)
    mode = "compatible"
    menu:updateLiveMonitor(token)
    check("live: Compatible stops it", monitors[1].stopped, true)
    mode = "fast"
    menu:updateLiveMonitor(token)
    menu._poll_token = {}
    menu:updateLiveMonitor(token)
    check("live: a closed menu (stale token) stops it", monitors[2].stopped, true)
    menu._poll_token = token
    menu:updateLiveMonitor(token)
    menu.controller.is_enabled = false
    menu:updateLiveMonitor(token)
    check("live: radio off stops it", monitors[3].stopped, true)
    menu.controller.is_enabled = true
    menu:updateLiveMonitor(token)
    menu:stopLiveMonitor()
    check("live: stopLiveMonitor (suspend, close) stops it", monitors[4].stopped, true)
end

-- Closing the menu before the first poll is not a layout change: the first
-- look finds it, so the poll logs "closed" at debug level, not WARN.
do
    local UIManager = require("ui/uimanager")
    local logger = require("logger")
    local saved_schedule, saved_warn = UIManager.scheduleIn, logger.warn
    local tasks, warned = {}, 0
    UIManager.scheduleIn = function(_, s, fn) table.insert(tasks, { s = s, fn = fn }) end
    UIManager._window_stack = {}
    logger.warn = function() warned = warned + 1 end
    local open = true
    menu.findTouchMenu = function() return open end
    menu.checkNow = function() end
    menu:startPolling()
    table.sort(tasks, function(a, b) return a.s < b.s end)
    tasks[1].fn() -- first look, menu open
    open = false  -- closed before the first poll
    tasks[2].fn() -- first poll
    check("quick close: no WARN", warned, 0)
    -- Never found at all: that one still warns.
    tasks, warned, open = {}, 0, false
    menu:startPolling()
    table.sort(tasks, function(a, b) return a.s < b.s end)
    tasks[1].fn(); tasks[2].fn()
    check("never found: WARN kept", warned, 1)
    UIManager.scheduleIn, logger.warn = saved_schedule, saved_warn
    menu.findTouchMenu, menu.checkNow = nil, nil
end

-- Taps on the Bluetooth switch while the radio is still switching are
-- ignored quietly: no second toggle, no message.
do
    shown = {}
    local toggles = 0
    local switching = true
    menu.controller.isUserSwitching = function() return switching end
    menu.controller.status = function() end
    menu.controller.wantsEnabled = function() return true end
    menu.controller.toggle = function() toggles = toggles + 1 end
    local item = menu:buildMenuTable()[1]
    item.callback(nil)
    item.callback(nil)
    check("still switching: taps ignored", toggles, 0)
    check("still switching: no message", #shown, 0)
    switching = false
    item.callback(nil)
    check("done switching: a tap toggles", toggles, 1)
end

if failures > 0 then
    print(failures .. " failure(s)")
    os.exit(1)
end
print("all menu tests passed")
