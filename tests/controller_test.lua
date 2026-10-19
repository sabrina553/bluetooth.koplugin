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

-- A failed or empty live read over a populated store is never saved: the
-- cached devices are served and starred stays.
do
    local c, calls = build(true, { ["AA:AA"] = { mac = "AA:AA", name = "Keyboard", paired = true, starred = true } })
    for _, read in ipairs({ function() return {} end, function() return nil end }) do
        fake.knownDevices = read
        calls.saved = nil
        local list = c:knownDevices()
        check(#list == 1 and list[1].starred == true, "failed read: cached device served with starred kept")
        check(not calls.saved, "failed read: store not rewritten")
    end
end

-- Starring a copy from before the last re-read still stars the device that
-- gets saved.
do
    local Devices = require("bluetooth/controller/devices")
    local c = build(true)
    local saved
    c.device_store.saveAll = function(_, list) saved = list[1].starred end
    local stale = Devices:new({ mac = "AA:AA", name = "Remote", paired = true, controller = c })
    c.known_devices = { Devices:new({ mac = "AA:AA", name = "Remote", paired = true, controller = c }) }
    local ok
    stale:toggleStar(function(confirmed) ok = confirmed end)
    check(ok == true and saved == true, "star: saved on the live device, not just the stale copy")
    check(c.known_devices[1].starred == true, "star: live device shows the star")
end

-- Background read: the cache is served at once, the result is applied when
-- it lands, reads in flight are shared and a result from before a radio
-- change is dropped. Every callback fires exactly once.
do
    local c, calls = build(true, { ["AA:AA"] = { mac = "AA:AA", name = "Keyboard", paired = true, starred = true } })
    local finish
    fake.readSnapshot = function(_, done) calls.started = (calls.started or 0) + 1; finish = done end
    local function dev(mac) return { mac = mac, name = mac, paired = true, skip_info = true } end

    c.known_devices = { dev("OLD:OLD") }
    local a, b = {}, {}
    local list = c:knownDevices(function(ok) table.insert(a, ok) end)
    c:knownDevices(function(ok) table.insert(b, ok) end)
    check(list[1].mac == "OLD:OLD", "async: cached list served while reading")
    check(calls.started == 1, "async: a second read joins the one in flight")
    finish({ dev("AA:AA"), dev("BB:BB") })
    check(#c.known_devices == 2, "async: result applied when it lands")
    check(#a == 1 and a[1] == true and #b == 1 and b[1] == true, "async: both callbacks fire once with true")
    check(c.known_devices[1].starred == true, "async: stored state applied to the new list")

    -- Radio changed during the read: result dropped, callback false
    local before = c.known_devices
    local dropped = {}
    c:knownDevices(function(ok) table.insert(dropped, ok) end)
    c._poll_generation = (c._poll_generation or 0) + 1
    finish({ dev("ZZ:ZZ") })
    check(c.known_devices == before, "async: stale result not applied")
    check(#dropped == 1 and dropped[1] == false, "async: stale callback fires once with false")

    -- A failed read keeps the saved devices and the store
    calls.saved = nil
    c:knownDevices()
    finish(nil)
    check(#c.known_devices == 1 and c.known_devices[1].starred == true, "async: failed read serves the saved devices")
    check(not calls.saved, "async: failed read does not rewrite the store")

    -- A new read can start once the last has landed
    c:knownDevices()
    check(calls.started == 4, "async: reading flag cleared after a result")

    -- Suspend reads block: the radio goes down right after
    fake.knownDevices = function() calls.blocking = (calls.blocking or 0) + 1; return { dev("AA:AA") } end
    finish({ dev("AA:AA") })
    local snap_done
    c:snapshotBeforeSuspend(function() snap_done = true end)
    check(snap_done and calls.blocking == 1, "async: suspend snapshot uses the blocking read")
    fake.readSnapshot = nil
end

-- Cached status: display code gets the last value at once; the background
-- check only changes it when nothing newer has happened.
do
    local c = build(true)
    c:status()
    local finish
    fake.readStatus = function(_, done) finish = done end
    local changes = {}
    local function on_change(v) table.insert(changes, v) end

    check(c:statusCached(on_change) == true, "cached status: last value returned at once")
    c:statusCached(on_change)
    finish(true)
    check(#changes == 0 and c.is_enabled == true, "cached status: same value is no change")

    c:statusCached(on_change)
    finish(false)
    check(c.is_enabled == false and changes[1] == false, "cached status: change applied and reported")

    c:statusCached(on_change)
    finish(nil)
    check(c.is_enabled == false and #changes == 1, "cached status: no answer keeps the old value")

    c:statusCached(on_change)
    c:status() -- a blocking check ran meanwhile and is newer
    local after = c.is_enabled
    finish(not after)
    check(c.is_enabled == after, "cached status: stale result dropped after a blocking check")

    c:statusCached(on_change)
    c._poll_generation = (c._poll_generation or 0) + 1
    finish(not c.is_enabled)
    check(c.is_enabled == after, "cached status: result dropped after enable/disable")

    -- A check started by a caller with no callback still tells later callers
    c:statusCached()
    local late = {}
    c:statusCached(function(v) table.insert(late, v) end)
    finish(not c.is_enabled)
    check(#late == 1, "cached status: a later caller's callback is kept when a check is already running")

    fake.readStatus = nil
    local c2 = build(false)
    check(c2:statusCached() == false, "cached status: backend without a background check falls back")
end

if failures > 0 then os.exit(1) end
print("controller_test: ok")
