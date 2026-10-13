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
local holds = 0 -- standby holds currently taken
package.preload["ui/uimanager"] = function()
    return {
        show = function() end,
        scheduleIn = function(_, _, fn) table.insert(queue, fn) end,
        preventStandby = function() holds = holds + 1 end,
        allowStandby = function() holds = holds - 1 end,
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

-- Runs queued UIManager work, including work queued while running.
local function drain()
    local guard = 0
    while #queue > 0 and guard < 100 do
        guard = guard + 1
        table.remove(queue, 1)()
    end
end

-- Superseded before its command is sent: the callback still fires, once, false.
do
    local c, calls = build(false)
    local got = {}
    c:enable(function(ok) table.insert(got, "enable:" .. tostring(ok)) end)
    c:disable(function(ok) table.insert(got, "disable:" .. tostring(ok)) end)
    drain()
    check(table.concat(got, ",") == "enable:false,disable:true", "superseded before send: got " .. table.concat(got, ","))
    check(not calls.enable and calls.disable == 1, "superseded before send: only disable sent")
end

-- Superseded while polling: the stale poll calls back false, once.
do
    local c = build(false)
    local got = {}
    c:enable(function(ok) table.insert(got, "enable:" .. tostring(ok)) end)
    table.remove(queue, 1)() -- debounce fires, enable sent, poll retry queued
    c:disable(function(ok) table.insert(got, "disable:" .. tostring(ok)) end)
    drain()
    check(table.concat(got, ",") == "enable:false,disable:true", "superseded while polling: got " .. table.concat(got, ","))
end

-- Resume during a pending disable: reads serve the cache, and the "on"
-- waits until the radio reports off before it is sent.
do
    local on, order = true, {}
    local c, calls = build(true, { ["AA:AA"] = { mac = "AA:AA", name = "Keyboard", paired = true } })
    fake.status = function() return on end
    fake.disable = function() table.insert(order, "off") end
    fake.enable = function() table.insert(order, "on"); on = true end
    calls.read = nil
    local enabled
    c:disable()
    check(c:isDisabling(), "disabling: flag set at once")
    local list = c:knownDevices()
    check(#list == 1 and not calls.read, "disabling: cache served, no live read")
    table.remove(queue, 1)() -- disable debounce: off sent, radio still reads on
    check(c:isDisabling(), "disabling: still pending while radio reads on")
    c:enable(function(ok) enabled = ok end)
    check(not c:isDisabling(), "disabling: enable supersedes it")
    for _ = 1, 4 do if #queue > 0 then table.remove(queue, 1)() end end -- stale poll ends, enable waits
    check(table.concat(order, ",") == "off", "wait: on not sent while radio still on, got " .. table.concat(order, ","))
    on = false        -- netagent finishes
    drain()
    check(table.concat(order, ",") == "off,on", "wait: on sent after off, got " .. table.concat(order, ","))
    check(enabled == true, "wait: enable confirmed")
end

-- Standby is held while waiting on the radio and always released, whichever
-- way the call ends (confirmed, timed out, superseded).
do
    for len = #queue, 1, -1 do queue[len] = nil end
    holds = 0
    local on = false
    local c = build(false)
    fake.status = function() return on end
    fake.enable = function() on = true end
    c:enable()
    check(holds == 1, "standby: held while enabling, got " .. holds)
    drain()
    check(holds == 0, "standby: released after confirm, got " .. holds)

    on = false
    fake.enable = function() end -- radio never comes up
    c:enable()
    drain()
    check(holds == 0, "standby: released after timeout, got " .. holds)

    c:enable()
    c:disable()
    check(holds == 2, "standby: one hold per pending call, got " .. holds)
    drain()
    check(holds == 0, "standby: released when superseded, got " .. holds)
end

-- A second tap while a transition is in flight reverses it, not repeats it,
-- even though the radio still reads the old state.
do
    for len = #queue, 1, -1 do queue[len] = nil end
    local on, order = true, {}
    local c = build(true)
    fake.status = function() return on end
    fake.disable = function() table.insert(order, "off") end
    fake.enable = function() table.insert(order, "on"); on = true end
    c:toggle()                 -- radio reads on: heads off
    check(not c:wantsEnabled(), "toggle: wants off after first tap")
    c:toggle()                 -- still reads on, but should now enable
    check(c:wantsEnabled(), "toggle: wants on after second tap")
    c:toggle()                 -- and back to off
    check(not c:wantsEnabled(), "toggle: wants off after third tap")
    on = false
    drain()
    check(table.concat(order, ",") == "off", "toggle: only the last intent sent, got " .. table.concat(order, ","))
end

-- Suspend while an enable is still in flight counts as "was on", so resume
-- restores it.
do
    for len = #queue, 1, -1 do queue[len] = nil end
    local c = build(false)
    fake.status = function() return false end
    c:enable()
    c:snapshotBeforeSuspend()
    check(c.was_enabled_before_suspend == true, "snapshot: mid-enable counts as on")
    c:disable()
    c:snapshotBeforeSuspend()
    check(c.was_enabled_before_suspend == false, "snapshot: mid-disable counts as off")
    drain()
end

if failures > 0 then os.exit(1) end
print("controller_test: ok")
