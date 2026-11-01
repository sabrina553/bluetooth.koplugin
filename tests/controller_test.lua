-- Run from the repo root: luajit tests/controller_test.lua
package.path = "bluetooth.koplugin/?.lua;tests/?.lua;" .. package.path
local rejectDescription = require("helpers").rejectDescription
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
    rejectDescription(cond)
    if not cond then
        failures = failures + 1
        print("FAIL " .. message)
    end
end

-- Builds a controller on the PocketBook backend with a fake radio. The
-- backend table the controller picked is replaced wholesale.
local function build(radio_on, store_data)
    -- The switch state is shared across instances, so each build starts idle.
    controller._resetSwitchState()
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

-- Last on Wake: the devices connected at suspend reconnect, even though the
-- first read after wake reports everything disconnected; the list is used once.
do
    local Devices = require("bluetooth/controller/devices")
    local c = build(true)
    c.settings = { getStarredOnWake = function() return false end, getLastOnWake = function() return true end,
        setRadioWasOn = function() end }
    c.device_store.getStarred = function() return {} end
    fake.knownDevices = function()
        return { Devices:new({ mac = "AA:AA", name = "Remote", paired = true, connected = true, controller = c }) }
    end
    c:status()
    c:snapshotBeforeSuspend()
    fake.knownDevices = function()
        return { Devices:new({ mac = "AA:AA", name = "Remote", paired = true, connected = false, controller = c }) }
    end
    c:knownDevices()
    local connects = 0
    for _, dev in ipairs(c.known_devices) do dev.connect = function() connects = connects + 1 end end
    c:reconnectOnWake()
    check(connects == 1, "last on wake: reconnected after a disconnected read, got " .. connects)
    c:reconnectOnWake()
    check(connects == 1, "last on wake: list used only once")
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
    c:enable() -- bumps the shared poll generation, as a real switch would
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
    c:enable() -- bumps the shared poll generation, as a real switch would
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

-- Restore at boot: the menu toggle and the suspend snapshot both save the
-- radio state to disk; a plain disable (disable-on-suspend) does not.
do
    for len = #queue, 1, -1 do queue[len] = nil end
    local c = build(false)
    local saved = {}
    c.settings = { setRadioWasOn = function(_, on) table.insert(saved, on) end }
    c:toggle()
    check(saved[#saved] == true, "radio state: toggle on saves true")
    c:snapshotBeforeSuspend()
    check(saved[#saved] == true, "radio state: suspend mid-enable saves true")
    c:toggle()
    check(saved[#saved] == false, "radio state: toggle off saves false")
    c:enable()
    local before = #saved
    c:disable()
    check(#saved == before, "radio state: plain disable saves nothing")
    drain()
end

-- Held devices (vault Docs/Controller design, "Stage 3 plan"): a manual
-- disconnect holds and untrusts, a manual connect releases and trusts, wake
-- skips held devices, and the flag survives stale copies and re-reads.
do
    local Devices = require("bluetooth/controller/devices")
    -- A fake radio for one device: actions change its state and are recorded
    -- in order; info() answers as bluetoothctl would.
    local function fakeBackend(state, order, refuse)
        local b = {}
        local function act(name, field, value)
            b[name] = function()
                table.insert(order, name)
                if not (refuse and refuse[name]) then state[field] = value end
            end
        end
        act("trust", "trusted", true); act("untrust", "trusted", false)
        act("connect", "connected", true); act("disconnect", "connected", false)
        b.info = function(_, mac)
            local yn = function(v) return v and "yes" or "no" end
            return "Device " .. mac .. " (public)\n\tName: Remote\n\tPaired: yes\n\tTrusted: " .. yn(state.trusted)
                .. "\n\tBlocked: no\n\tConnected: " .. yn(state.connected) .. "\n"
        end
        return b
    end
    local function stubController(held_log)
        return {
            setHeld = function(_, mac, held) table.insert(held_log, held) end,
            enableWhenDisabled = function(_, cb) cb(true) end,
        }
    end

    -- Disconnect: held first, then untrust, then disconnect.
    local order, held_log = {}, {}
    local state = { trusted = true, connected = true }
    local dev = Devices:new({ mac = "AA:AA", name = "Remote", paired = true, trusted = true, connected = true,
        backend = fakeBackend(state, order, nil), controller = stubController(held_log) })
    local ok
    dev:toggleConnection(function(c) ok = c end)
    drain()
    check(ok == true, "held: manual disconnect confirmed")
    check(held_log[1] == true and dev.held == true, "held: disconnect sets held on the object and the controller")
    check(table.concat(order, ",") == "untrust,disconnect", "held: untrust before disconnect, got " .. table.concat(order, ","))

    -- Connect: release, trust, connect.
    order = {}
    dev.backend = fakeBackend(state, order, nil)
    dev:toggleConnection(function(c) ok = c end)
    drain()
    check(ok == true and dev.connected, "held: manual connect confirmed")
    check(held_log[2] == false and dev.held == false, "held: connect clears held")
    check(table.concat(order, ",") == "trust,connect", "held: trust before connect, got " .. table.concat(order, ","))

    -- A failed untrust still disconnects; a failed trust still connects.
    order = {}
    state = { trusted = true, connected = true }
    dev = Devices:new({ mac = "AA:AA", name = "Remote", paired = true, trusted = true, connected = true,
        backend = fakeBackend(state, order, { untrust = true, trust = true }), controller = stubController({}) })
    dev:toggleConnection(function(c) ok = c end)
    drain()
    check(ok == true and not dev.connected and dev.held, "held: failed untrust still disconnects and holds")
    dev:toggleConnection(function(c) ok = c end)
    drain()
    check(ok == true and dev.connected and not dev.held, "held: failed trust still connects and releases")

    -- Untrust of an untrusted device is a success, as trust of a trusted one is.
    dev = Devices:new({ mac = "AA:AA", name = "Remote", trusted = false, backend = fakeBackend({}, {}, nil) })
    dev:untrust(function(c) ok = c end)
    check(ok == true, "untrust: already untrusted calls back true")
end

-- Held through the controller: setHeld reaches the live device after a
-- re-read, the store carries it, and wake skips held devices.
do
    local Devices = require("bluetooth/controller/devices")
    local c = build(true)
    local saved
    c.device_store.saveAll = function(self, list)
        self.data = {}
        for _, d in ipairs(list) do self.data[d.mac] = { mac = d.mac, name = d.name, paired = true, held = d.held, starred = d.starred } end
        saved = self.data
    end
    c.known_devices = { Devices:new({ mac = "AA:AA", name = "Remote", paired = true, controller = c }) }
    c:setHeld("AA:AA", true)
    check(c.known_devices[1].held == true and saved["AA:AA"].held == true, "setHeld: live device and store")

    c.known_devices = { Devices:new({ mac = "AA:AA", name = "Remote", paired = true, controller = c }) }
    c:applyStoredDeviceState()
    check(c.known_devices[1].held == true, "setHeld: survives a re-read")
    check(c:devicesFromStore()[1].held == true, "setHeld: devicesFromStore carries held")

    c.settings = { getStarredOnWake = function() return true end, getLastOnWake = function() return true end }
    c.device_store.getStarred = function() return { { mac = "AA:AA" } } end
    c.connected_at_suspend = { "AA:AA" }
    local connects = 0
    c.known_devices[1].connect = function() connects = connects + 1 end
    c:reconnectOnWake()
    check(connects == 0, "wake: held device skipped for starred and last on wake")

    c:setHeld("AA:AA", false)
    c.connected_at_suspend = { "AA:AA" }
    c:reconnectOnWake()
    check(connects == 1, "wake: released device reconnects, got " .. connects)
end

-- A suspend that replaces an enable says so, so main.lua logs it at debug
-- level instead of WARN (reader log 2026-10-26 10:07:51).
do
    for len = #queue, 1, -1 do queue[len] = nil end
    local c = build(false)
    fake.status = function() return false end
    local ok, reason
    c:enable(function(confirmed, why) ok, reason = confirmed, why end)
    c:disable()
    drain()
    check(ok == false and reason == "superseded", "superseded enable: reports why, got " .. tostring(reason))
end

-- main.lua tells the two apart by wantsEnabled() when the callback fires.
do
    for len = #queue, 1, -1 do queue[len] = nil end
    local c = build(false)
    local by_disable, by_enable
    c:enable(function() by_disable = c:wantsEnabled() end)
    c:disable()
    drain()
    c:enable(function() by_enable = c:wantsEnabled() end)
    c:enable()
    drain()
    check(by_disable == false, "superseded by a disable: no longer wants on")
    check(by_enable == true, "superseded by an enable: still wants on")
end

-- A tap during a restore's enable joins it instead of starting a second
-- enable, which used to supersede the restore and skip its reconnect
-- (decision 2026-10-27).
do
    for len = #queue, 1, -1 do queue[len] = nil end
    holds = 0
    local on = false
    local c, calls = build(false)
    fake.status = function() return on end
    local a, b = {}, {}
    c:enableWhenDisabled(function(ok) table.insert(a, ok) end)
    table.remove(queue, 1)() -- debounce fires, enable sent, radio still off
    c:enableWhenDisabled(function(ok) table.insert(b, ok) end)
    on = true
    drain()
    check(#a == 1 and a[1] == true, "join: first caller confirmed once, got " .. #a .. " " .. tostring(a[1]))
    check(#b == 1 and b[1] == true, "join: joiner confirmed once, got " .. #b .. " " .. tostring(b[1]))
    check(calls.enable == 1, "join: one enable sent, got " .. tostring(calls.enable))
    check(holds == 0, "join: no standby hold left, got " .. holds)
end

-- A disable supersedes the enable for its joiners too.
do
    for len = #queue, 1, -1 do queue[len] = nil end
    holds = 0
    local c = build(false)
    local a, b = {}, {}
    c:enableWhenDisabled(function(ok, why) table.insert(a, tostring(ok) .. ":" .. tostring(why)) end)
    c:enableWhenDisabled(function(ok, why) table.insert(b, tostring(ok) .. ":" .. tostring(why)) end)
    c:disable()
    drain()
    check(#a == 1 and a[1] == "false:superseded", "join disabled: first caller superseded once, got " .. table.concat(a, ","))
    check(#b == 1 and b[1] == "false:superseded", "join disabled: joiner superseded once, got " .. table.concat(b, ","))
    check(holds == 0, "join disabled: no standby hold left, got " .. holds)
end

-- The other way round: a tap starts the enable and the restore joins it.
do
    for len = #queue, 1, -1 do queue[len] = nil end
    holds = 0
    local on = false
    local c, calls = build(false)
    fake.status = function() return on end
    fake.enable = function() calls.enable = (calls.enable or 0) + 1; on = true end
    local tap, restore = {}, {}
    c:enableWhenDisabled(function(ok) table.insert(tap, ok) end)
    c:enableWhenDisabled(function(ok) table.insert(restore, ok) end)
    drain()
    check(#tap == 1 and tap[1] == true, "join reversed: tap confirmed once, got " .. #tap .. " " .. tostring(tap[1]))
    check(#restore == 1 and restore[1] == true, "join reversed: restore confirmed once, got " .. #restore .. " " .. tostring(restore[1]))
    check(calls.enable == 1, "join reversed: one enable sent, got " .. tostring(calls.enable))
    check(holds == 0, "join reversed: no standby hold left, got " .. holds)
end

-- A joiner that asks again from its callback finds the radio on and starts
-- nothing new.
do
    for len = #queue, 1, -1 do queue[len] = nil end
    holds = 0
    local on = false
    local c, calls = build(false)
    fake.status = function() return on end
    fake.enable = function() calls.enable = (calls.enable or 0) + 1; on = true end
    local again = {}
    c:enableWhenDisabled(function() end)
    c:enableWhenDisabled(function()
        c:enableWhenDisabled(function(ok) table.insert(again, ok) end)
    end)
    drain()
    check(#again == 1 and again[1] == true, "join again: confirmed once, got " .. #again .. " " .. tostring(again[1]))
    check(calls.enable == 1, "join again: no second enable, got " .. tostring(calls.enable))
    check(holds == 0, "join again: no standby hold left, got " .. holds)
end

-- Only the user's own switch blocks the menu, and it still does on the
-- controller built after a view change.
do
    for len = #queue, 1, -1 do queue[len] = nil end
    local c = build(false)
    c:enable()
    check(not c:isUserSwitching(), "user switch: a restore's enable doesn't count")
    drain()
    c:toggle()
    local after_view_change = build(true)
    check(after_view_change:isUserSwitching(), "user switch: seen by a new instance")
    drain()
    check(not c:isUserSwitching(), "user switch: cleared once confirmed")
end

-- Pairing while another session runs: the menu is told "busy", not a
-- failed pairing.
do
    local Devices = require("bluetooth/controller/devices")
    local dev = Devices:new({ mac = "AA:AA", name = "Phone",
        backend = { pair = function() return false, "busy" end },
        controller = { enableWhenDisabled = function(_, cb) cb(true) end } })
    local ok, reason
    dev:pair(function(confirmed, why) ok, reason = confirmed, why end)
    check(ok == false and reason == "busy", "pair busy: reported as busy, got " .. tostring(reason))
end

-- A pairing session that reports failure ends the wait at once, rather than
-- after the whole confirm budget (about 22 s).
do
    for len = #queue, 1, -1 do queue[len] = nil end
    local Devices = require("bluetooth/controller/devices")
    local finish
    local dev = Devices:new({ mac = "AA:AA", name = "Phone",
        backend = {
            pair = function(_, _, on_done) finish = on_done; return true end,
            info = function() return "Device AA:AA (public)\n\tPaired: no\n" end,
        },
        controller = { enableWhenDisabled = function(_, cb) cb(true) end } })
    local results = {}
    dev:pair(function(confirmed) table.insert(results, confirmed) end)
    check(#results == 0, "pair failure: still waiting before the session ends")
    finish(false)
    check(#results == 1 and results[1] == false, "pair failure: reported at once")
    local warned = 0
    local logger = require("logger")
    local saved_warn = logger.warn
    logger.warn = function() warned = warned + 1 end
    drain()
    logger.warn = saved_warn
    check(#results == 1, "pair failure: the poll ending later does not report twice")
    check(warned == 0, "pair failure: the leftover poll stops without a WARN, got " .. warned)
end

-- Phones often pair without staying connected as an input: once Paired
-- reads yes the device is trusted and the pairing reported, connect or not
-- (code review finding 12, decision 2026-10-27).
do
    for len = #queue, 1, -1 do queue[len] = nil end
    local Devices = require("bluetooth/controller/devices")
    local function pairBackend(state, order)
        return {
            pair = function() return true end,
            connect = function() table.insert(order, "connect") end,
            trust = function() table.insert(order, "trust"); state.trusted = true end,
            info = function(_, mac)
                local yn = function(v) return v and "yes" or "no" end
                return "Device " .. mac .. " (public)\n\tPaired: " .. yn(state.paired) .. "\n\tTrusted: "
                    .. yn(state.trusted) .. "\n\tConnected: no\n"
            end,
        }
    end
    local controller_stub = { enableWhenDisabled = function(_, cb) cb(true) end }

    local order, results = {}, {}
    local dev = Devices:new({ mac = "AA:AA", name = "Phone",
        backend = pairBackend({ paired = true }, order), controller = controller_stub })
    dev:pair(function(confirmed, why) table.insert(results, { confirmed, why }) end)
    drain()
    check(table.concat(order, ",") == "connect,trust", "pair unconnected: trusted anyway, got " .. table.concat(order, ","))
    check(dev.trusted == true, "pair unconnected: device reads trusted")
    check(#results == 1 and results[1][1] == true and results[1][2] == nil,
        "pair unconnected: reported once as paired, got " .. tostring(results[1] and results[1][1]))

    order, results = {}, {}
    dev = Devices:new({ mac = "AA:AA", name = "Phone",
        backend = pairBackend({ paired = false }, order), controller = controller_stub })
    dev:pair(function(confirmed, why) table.insert(results, { confirmed, why }) end)
    drain()
    check(#order == 0, "pair unconfirmed: no connect or trust, got " .. table.concat(order, ","))
    check(#results == 1 and results[1][1] == false, "pair unconfirmed: reported once as failed")
end

-- The other "superseded" exits, past the debounce: each calls back once with
-- the reason and gives its standby hold back.
local function recorder()
    local got = {}
    return got, function(ok, reason) table.insert(got, tostring(ok) .. ":" .. tostring(reason)) end
end

-- pollField, on a retry: a newer call landed between two polls.
do
    for len = #queue, 1, -1 do queue[len] = nil end
    holds = 0
    local c = build(false)
    local got, cb = recorder()
    c:enable(cb)
    table.remove(queue, 1)() -- debounce: enable sent, radio still off, retry queued
    c:disable()
    drain()
    check(table.concat(got, ",") == "false:superseded", "poll retry superseded: got " .. table.concat(got, ","))
    check(holds == 0, "poll retry superseded: holds balanced, got " .. holds)
end

-- pollField, after status(): a newer call landed while the status read ran.
do
    for len = #queue, 1, -1 do queue[len] = nil end
    holds = 0
    local c = build(false)
    local sent = false
    fake.enable = function() sent = true end
    fake.status = function()
        if sent then sent = false; c:disable() end
        return false
    end
    local got, cb = recorder()
    c:enable(cb)
    table.remove(queue, 1)() -- debounce: enable sent, disable arrives mid-status
    check(table.concat(got, ",") == "false:superseded", "status superseded: called back at once, got " .. table.concat(got, ","))
    drain()
    check(table.concat(got, ",") == "false:superseded", "status superseded: only once, got " .. table.concat(got, ","))
    check(holds == 0, "status superseded: holds balanced, got " .. holds)
end

-- waitForOff: an enable waiting for the radio to go off is replaced by a
-- newer disable, so its "on" is never sent.
do
    for len = #queue, 1, -1 do queue[len] = nil end
    holds = 0
    local on, order = true, {}
    local c = build(true)
    fake.status = function() return on end
    fake.disable = function() table.insert(order, "off") end
    fake.enable = function() table.insert(order, "on"); on = true end
    c:disable()
    table.remove(queue, 1)() -- disable debounce: off sent, radio still reads on
    local got, cb = recorder()
    c:enable(cb)
    table.remove(queue, 1)() -- stale disable poll ends
    table.remove(queue, 1)() -- enable debounce: waiting for off, retry queued
    c:disable()
    on = false
    drain()
    check(table.concat(got, ",") == "false:superseded", "wait superseded: got " .. table.concat(got, ","))
    check(table.concat(order, ",") == "off,off", "wait superseded: on never sent, got " .. table.concat(order, ","))
    check(holds == 0, "wait superseded: holds balanced, got " .. holds)
end

-- main.lua builds a new controller on every view change, so the switch state
-- is shared: B joins, supersedes and reports A's switch (decision 2026-10-27).
do
    for len = #queue, 1, -1 do queue[len] = nil end
    holds = 0
    local on = false
    local A = build(false)
    local B = build(false)
    fake.status = function() return on end
    local enables = 0
    fake.enable = function() enables = enables + 1 end
    local a, b = {}, {}
    A:enableWhenDisabled(function(ok) table.insert(a, ok) end)
    table.remove(queue, 1)() -- debounce fires, enable sent, radio still off
    check(B:isEnabling() == true, "shared: B sees A's enable in progress")
    B:enableWhenDisabled(function(ok) table.insert(b, ok) end)
    on = true
    drain()
    check(enables == 1, "shared: one enable sent, got " .. enables)
    check(#a == 1 and a[1] == true, "shared: A confirmed once, got " .. #a .. " " .. tostring(a[1]))
    check(#b == 1 and b[1] == true, "shared: B joined and confirmed once, got " .. #b .. " " .. tostring(b[1]))
    check(holds == 0, "shared: no standby hold left, got " .. holds)
end

-- A suspend disable() on the new instance supersedes the old one's enable.
do
    for len = #queue, 1, -1 do queue[len] = nil end
    holds = 0
    local A = build(false)
    local B = build(false)
    local got = {}
    A:enableWhenDisabled(function(ok, why) table.insert(got, tostring(ok) .. ":" .. tostring(why)) end)
    B:disable()
    drain()
    check(table.concat(got, ",") == "false:superseded", "shared disable: A superseded once, got " .. table.concat(got, ","))
    check(holds == 0, "shared disable: holds balanced, got " .. holds)
end

-- A disable sent by the old instance makes the new one's enable wait for the
-- radio to report off, or "on" races the shutdown (decision 2026-10-27).
do
    for len = #queue, 1, -1 do queue[len] = nil end
    holds = 0
    local on, order = true, {}
    local A = build(true)
    local B = build(true)
    fake.status = function() return on end
    fake.disable = function() table.insert(order, "off") end
    fake.enable = function() table.insert(order, "on"); on = true end
    A:disable()
    table.remove(queue, 1)() -- A's debounce: off sent, radio still reads on
    local got = {}
    B:enable(function(ok) table.insert(got, ok) end)
    table.remove(queue, 1)() -- A's stale poll ends
    table.remove(queue, 1)() -- B's debounce: must wait for off, not send on
    check(table.concat(order, ",") == "off", "shared disable sent: B waits for off, got " .. table.concat(order, ","))
    on = false
    drain()
    check(table.concat(order, ",") == "off,on", "shared disable sent: on after off, got " .. table.concat(order, ","))
    check(#got == 1 and got[1] == true, "shared disable sent: B confirmed once, got " .. #got .. " " .. tostring(got[1]))
    check(holds == 0, "shared disable sent: holds balanced, got " .. holds)
end


do -- Capabilities (decision 2026-10-28): the menu asks the controller.
    local c = setmetatable({ backend = { capabilities = { trust = true, block = false } } }, { __index = controller })
    check(c:can("trust") == true, "can: declared feature is true")
    check(c:can("block") == false, "can: switched-off feature is false")
    check(c:can("foo") == false, "can: unknown feature is false")
    c.backend = nil
    check(c:can("trust") == false, "can: no backend is false, not an error")
end


do -- Kobo MTK and Kindle keep their backend whatever the mode setting (decision 2026-10-28).
    local Kindle = require("bluetooth/controller/kindle")
    Kindle.isPrepared = function() return false end
    for _, case in ipairs({ { "KoboMTK", require("bluetooth/controller/kobo_mtk"):new() }, { "Kindle", Kindle:new() } }) do
    local kobo = case[2]
    for _, setting in ipairs({ "auto", "fast", "compatible" }) do
        local c = setmetatable({ type = case[1], backend = kobo,
            settings = { getBackendMode = function() return setting end } }, { __index = controller })
        c:applyMode()
        check(c.backend == kobo, "Kobo MTK keeps its backend with setting " .. setting)
        check(c:can("transport") == false, "Kobo MTK hides the mode choice")
        check(c:activeMode() == "fast", case[1] .. " is always fast, setting " .. setting)
    end
    end
end


do -- pairFailedHint: the backend's advice after a failed pairing (decision 2026-10-28).
    local c = setmetatable({ backend = nil }, { __index = controller })
    check(c:pairFailedHint() == nil, "hint: none without a backend")
    c.backend = {}
    check(c:pairFailedHint() == nil, "hint: none when the backend has no hint")
    c.backend = { pairFailedHint = function() return "set up first" end }
    check(c:pairFailedHint() == "set up first", "hint: the backend's text")
end

if failures > 0 then os.exit(1) end
print("controller_test: ok")
