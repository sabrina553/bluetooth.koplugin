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
local cannot = {} -- features the stub backend lacks
local hint -- the stub backend's advice after a failed pairing
local mode = "fast"
local menu = BluetoothMenu:new({
    settings = { getLiveUpdates = function() return live end },
    controller = { activeMode = function() return mode end, is_enabled = true, known_devices = {},
        can = function(_, feature) return not cannot[feature] end,
        pairFailedHint = function() return hint end },
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
    local saved_schedule, saved_tick, saved_warn = UIManager.scheduleIn, UIManager.nextTick, logger.warn
    local tasks, warned = {}, 0
    UIManager.scheduleIn = function(_, s, fn) table.insert(tasks, { s = s, fn = fn }) end
    -- Queued as delay 0, so it sorts before any scheduled task.
    UIManager.nextTick = function(_, fn) table.insert(tasks, { s = 0, fn = fn, tick = true }) end
    local function sorted() table.sort(tasks, function(a, b) return a.s < b.s end) end
    UIManager._window_stack = {}
    logger.warn = function() warned = warned + 1 end
    local open = true
    menu.findTouchMenu = function() return open end
    menu.checkNow = function() end
    menu:startPolling()
    sorted()
    tasks[1].fn() -- first look, menu open
    open = false  -- closed before the first poll
    tasks[2].fn() -- first poll
    check("quick close: no WARN", warned, 0)
    -- Never found at all: that one still warns.
    tasks, warned, open = {}, 0, false
    menu:startPolling()
    while #tasks > 0 do sorted(); table.remove(tasks, 1).fn() end
    check("never found: WARN kept", warned, 1)
    -- The first look runs on the next tick; missed there, the delayed retry
    -- still finds a slow-opening menu (decision 2026-10-27).
    tasks, warned, open = {}, 0, false
    menu:startPolling()
    sorted()
    check("first look: on the next tick", tasks[1].tick, true)
    if tasks[1].tick then
        tasks[1].fn() -- not there yet
        sorted()
        check("first look: retried later", #tasks, 3)
        open = true; tasks[2].fn() -- the retry finds it
        open = false; tasks[3].fn() -- closed before the first poll
        check("first look: retry counts as seen", warned, 0)
    end
    UIManager.scheduleIn, UIManager.nextTick, logger.warn = saved_schedule, saved_tick, saved_warn
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

-- One tap reads the radio status once: each read is a blocking shell-out
-- on PocketBook (decision 2026-10-27). Uses the real toggle().
do
    shown = {}
    package.preload["device"] = function() return { model = "test" } end
    local Controller = require("bluetooth/controller/controller")
    local reads, sent = 0, nil
    menu.controller.isUserSwitching = function() return false end
    menu.controller.status = function(self) reads = reads + 1; self.is_enabled = false end
    menu.controller.wantsEnabled = Controller.wantsEnabled
    menu.controller.isEnabling = Controller.isEnabling
    menu.controller.isDisabling = Controller.isDisabling
    menu.controller.toggle = Controller.toggle
    menu.controller.enable = function() sent = "on" end
    menu.controller.disable = function() sent = "off" end
    menu:buildMenuTable()[1].callback(nil)
    check("one tap: status reads", reads, 1)
    check("one tap: enables", sent, "on")
    check("one tap: message", last().text, "Enabling Bluetooth")
end

-- Buttons sits after Settings once main.lua passes a KeysMenu.
do
    check("buttons: absent without a KeysMenu", menu:buildMenuTable()[3].text, "Scan")
    menu.keys_menu = { menuTable = function() return { "x" } end }
    local item = menu:buildMenuTable()[3]
    check("buttons: after Settings", item.text, "Buttons")
    check("buttons: opens the KeysMenu", item.sub_item_table_func()[1], "x")
    menu.keys_menu = nil
end

do -- Capabilities (decision 2026-10-28): items a backend can't do are omitted.
    local function texts(row)
        local out = {}
        for _, b in ipairs(row) do table.insert(out, b.text_func and "Backend" or b.text) end
        return table.concat(out, ",")
    end
    local dev = { name = "Pad", mac = "XX:XX", paired = true }
    menu:showDeviceActions(dev)
    check("caps: full row", texts(last().buttons[1]), "info,Unpair,Trust,Block")
    check("caps: separator on the row's last", last().buttons[1][4].separator, true)
    cannot = { trust = true, block = true }
    menu:showDeviceActions(dev)
    check("caps: no trust or block", texts(last().buttons[1]), "info,Unpair")
    check("caps: separator moves to the last kept", last().buttons[1][2].separator, true)
    cannot = { block = true }
    menu:showDeviceActions(dev)
    check("caps: trust only", texts(last().buttons[1]), "info,Unpair,Trust")

    -- The info box leaves out what the backend can't manage (Kindle showed "nil").
    last().buttons[1][1].callback()
    check("caps: info shows Trusted", last().text:find("Trusted:", 1, true) ~= nil, true)
    check("caps: info leaves out Blocked", last().text:find("Blocked:", 1, true), nil)

    local function has(items, label)
        for _, item in ipairs(items) do
            if (item.text_func and "Backend" or item.text) == label then return true end
        end
        return false
    end
    cannot = {}
    local settings = menu:getSettingsMenu()
    check("caps: Backend shown", has(settings, "Backend"), true)
    check("caps: Live updates shown", has(settings, "Live updates (experimental)"), true)
    cannot = { transport = true }
    settings = menu:getSettingsMenu()
    check("caps: Backend hidden", has(settings, "Backend"), false)
    check("caps: Live updates hidden", has(settings, "Live updates (experimental)"), false)
    check("caps: About still last", settings[#settings].text, "About")
    cannot = {}
end

do -- Kindle (decision 2026-10-28): setup hint after a failed pairing, pair by address.
    local dev = { mac = "00:11:22:33:44:55", name = "Pager", paired = false,
        pair = function(_, cb) cb(false) end }
    hint = nil
    shown = {}
    menu:pairFoundDevice(dev)
    check("no hint: short failure message", last().timeout, 2)
    hint = "Remotes need a one-time setup"
    shown = {}
    menu:pairFoundDevice(dev)
    check("hint: shown", last().text, hint)
    check("hint: stays until tapped", last().timeout, nil)
    hint = nil

    cannot = { address_pair = true }
    local items = menu:searchItems()
    check("address pair: absent without the capability", items[1] and items[1].address_pair, nil)
    cannot = {}
    items = menu:searchItems()
    check("address pair: first item with the capability", items[1] and items[1].address_pair, true)

    local paired_with
    local saved = menu.pairFoundDevice
    menu.pairFoundDevice = function(_, d) paired_with = d end
    shown = {}
    menu:pairAddress("not an address")
    check("address pair: bad address refused", paired_with, nil)
    check("address pair: says why", last().text, "Not a Bluetooth address")
    menu:pairAddress(" 00:11:22:33:44:aa ")
    check("address pair: valid address paired", paired_with and paired_with.mac, "00:11:22:33:44:AA")
    check("address pair: no per-device info reads", paired_with and paired_with.skip_info, true)
    menu.pairFoundDevice = saved
end

if failures > 0 then
    print(failures .. " failure(s)")
    os.exit(1)
end
print("all menu tests passed")
