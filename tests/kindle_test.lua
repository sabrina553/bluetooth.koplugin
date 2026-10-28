-- Run from the repo root: luajit tests/kindle_test.lua
-- lipc replies are synthetic, shaped by ZenOS's normalisation, with made-up MACs.
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
    return {
        scheduleIn = function(_, _, fn) table.insert(scheduled, fn) end,
        unschedule = function(_, fn)
            for i = #scheduled, 1, -1 do
                if scheduled[i] == fn then table.remove(scheduled, i) end
            end
        end,
    }
end

local input_opened = {}
package.preload["device"] = function()
    return { input = { open = function(_, path) table.insert(input_opened, path) end } }
end
local Bluez = require("bluetooth/controller/bluez")
local Contract = require("bluetooth/controller/backend_contract")
local Kindle = require("bluetooth/controller/kindle")
-- The real lipc layer, kept before the tests replace Kindle.lipc.
package.loaded["bluetooth/controller/kindle_lipc_for_tests"] = Kindle.lipc

local failures = 0
local function check(cond, message)
    helpers.rejectDescription(cond)
    if not cond then
        failures = failures + 1
        print("FAIL " .. message)
    end
end

local MAC = "00:11:22:33:44:55"
local OTHER = "66:77:88:99:AA:BB"

-- A fake lipc: ints and hashes answer from tables, every write is recorded.
local writes, ints, hashes, fail_hash
local function fakeLipc()
    writes, ints, hashes, fail_hash, logs, scheduled = {}, {}, {}, false, {}, {}
    Kindle.lipc = {
        getInt = function(prop) return ints[prop] end,
        setInt = function(prop, n) table.insert(writes, prop .. "=" .. n) return true end,
        setString = function(prop, s) table.insert(writes, prop .. "=" .. s) return true end,
        readHash = function(prop)
            if fail_hash then return nil end
            return hashes[prop] or {}
        end,
    }
end
local function wrote(entry)
    for _, w in ipairs(writes) do if w == entry then return true end end
    return false
end
local function runScheduled()
    local fns = scheduled
    scheduled = {}
    for _, fn in ipairs(fns) do fn() end
end

local scripts, async_reply
Bluez.runAsync = function(script, done)
    table.insert(scripts, script)
    done(async_reply)
end
Bluez.timeoutPrefix = function(secs) return "timeout " .. secs .. " " end

local prepared = false
local prepared_checks = 0
Kindle.isPrepared = function() prepared_checks = prepared_checks + 1 return prepared end

fakeLipc()
local kindle = Kindle:new()
-- The controller builds every backend at load, on every device: the setup
-- check must wait until a Kindle actually asks (no shell calls on PocketBook).
check(prepared_checks == 0, "new: no setup check until asked")
check(kindle.capabilities.address_pair == false, "address_pair follows the setup check")
check(prepared_checks == 1, "address_pair asks the setup check")

local ok, problems = Contract.check(kindle)
check(ok, "Kindle meets the contract: " .. table.concat(problems, "; "))
check(kindle.capabilities.trust == false and kindle.capabilities.transport == false, "no trust or mode choice on Kindle")

-- Status from BTstate; a timed-out read (nil) is off.
fakeLipc()
ints.BTstate = 1
check(kindle:status() == true, "status: BTstate 1 is on")
ints.BTstate = 0
check(kindle:status() == false, "status: BTstate 0 is off")
ints.BTstate = nil
check(kindle:status() == false, "status: no answer reads off")

-- Power through flight mode: 0 is radio on.
fakeLipc()
kindle:enable()
kindle:disable()
check(writes[1] == "BTflightMode=0" and writes[2] == "BTflightMode=1", "power: flight mode 0 on, 1 off")

-- Lists: merged by address, flags from each list, name falls back to the address.
fakeLipc()
hashes.ListPaired = { { address = MAC, name = "Pager" } }
hashes.ListConnected = { { Address = MAC:lower() } }
hashes.ListDiscovered = { { bdaddr = OTHER }, { name = "no address" } }
local devices = kindle:knownDevices()
check(devices and #devices == 2, "lists: two devices, got " .. tostring(devices and #devices))
local pager, other
for _, d in ipairs(devices or {}) do
    if d.mac == MAC then pager = d elseif d.mac == OTHER then other = d end
end
check(pager and pager.paired and pager.connected and pager.name == "Pager", "lists: paired and connected merged")
check(other and not other.paired and other.name == OTHER, "lists: name falls back to the address")
local shape_logged = false
for _, line in ipairs(logs) do
    if line:find("unexpected", 1, true) then shape_logged = true end
    check(not line:find(MAC, 1, true) and not line:find(OTHER, 1, true), "lists: MAC unmasked in log: " .. line)
end
check(shape_logged, "lists: entry without an address is logged")

fakeLipc()
fail_hash = true
check(kindle:knownDevices() == nil, "lists: failed read is nil, not empty")
local done_with = "unset"
kindle:readSnapshot(function(d) done_with = d end)
check(done_with == nil, "snapshot: failed read passes nil")

-- Actions take the address; a bad MAC is refused.
fakeLipc()
kindle:connect(MAC)
kindle:disconnect(MAC)
kindle:unpair(MAC)
check(wrote("Connect=" .. MAC) and wrote("Disconnect=" .. MAC) and wrote("Unbond=" .. MAC), "actions: lipc string properties")
fakeLipc()
kindle:connect("not a mac; reboot")
check(#writes == 0, "actions: bad MAC refused")

-- Scan: A2DP discovery on, off after the duration; a new scan replaces the timer.
fakeLipc()
kindle:search(5)
check(wrote("DiscoverA2DP=1"), "scan: discovery on")
kindle:search(5)
check(#scheduled == 1, "scan: one stop timer, got " .. #scheduled)
runScheduled()
check(writes[#writes] == "DiscoverA2DP=0", "scan: discovery off when the timer fires")

-- Pairing on a prepared Kindle: ace_bt_cli, success when the address is paired.
local result
prepared = true
fakeLipc()
scripts, async_reply = {}, "done\n"
hashes.ListPaired = { { address = MAC } }
check(kindle:pair(MAC, function(r) result = r end) == true, "pair prepared: started")
check(scripts[1] and scripts[1]:find("ace_bt_cli", 1, true) and scripts[1]:find(MAC, 1, true), "pair prepared: ace_bt_cli with the address")
check(result == true, "pair prepared: success from the paired list")
hashes.ListPaired = {}
scripts = {}
kindle:pair(MAC, function(r) result = r end)
check(result == false, "pair prepared: not in the paired list is a failure")
check(kindle:pairFailedHint() == nil, "prepared: no setup hint")
local refused, reason = kindle:pair("bad", function() end)
check(refused == false and reason == "invalid", "pair: bad MAC refused")

-- Pairing on an unprepared Kindle: Bond, then poll the paired list.
prepared = false
fakeLipc()
result = nil
kindle:pair(MAC, function(r) result = r end)
check(wrote("Bond=" .. MAC), "pair unprepared: Bond")
check(result == nil, "pair unprepared: waits for the paired list")
hashes.ListPaired = { { address = MAC } }
runScheduled()
check(result == true, "pair unprepared: success once paired")
local hint = kindle:pairFailedHint()
check(type(hint) == "string" and hint:find("README", 1, true) ~= nil, "unprepared: setup hint points to the README")

-- Connecting, or a read that shows a new connection, opens the remote's input device.
local KoboInput = require("bluetooth/keys/kobo_input")
KoboInput._reset()
Bluez.capture = function() return "/sys/class/input/event7 ../../devices/virtual/misc/uhid/z/input/input7/event7\n" end
fakeLipc()
kindle:connect(MAC)
check(#input_opened == 0, "input: not before the link settles")
runScheduled()
check(input_opened[1] == "/dev/input/event7", "input: opened after connect")
KoboInput._reset()
input_opened = {}
fakeLipc()
hashes.ListConnected = { { address = MAC } }
kindle:knownDevices()
runScheduled()
check(input_opened[1] == "/dev/input/event7", "input: opened when a read shows a new connection")

-- The device layer (review 2026-10-28): refresh reads Kindle's lists, and
-- trust after pairing is skipped rather than crashing.
local Devices = require("bluetooth/controller/devices")
fakeLipc()
hashes.ListPaired = { { address = MAC } }
hashes.ListConnected = { { address = MAC } }
local dev = Devices:fromScan(MAC, "Pager", kindle, nil)
dev:refresh()
check(dev.paired == true and dev.connected == true, "refresh: paired and connected from the lists")
local trusted_cb
local ok_trust = pcall(function() dev:trust(function(r) trusted_cb = r end) end)
check(ok_trust, "trust: no crash without a trust method")
check(trusted_cb == true, "trust: skipped as done on a backend that can't trust")

-- libopenlipclua: the hash array is destroyed even when a read throws.
local destroyed, closed = 0, 0
package.loaded["libopenlipclua"] = {
    open_no_name = function()
        return {
            new_hasharray = function() return { destroy = function() destroyed = destroyed + 1 end } end,
            access_hash_property = function() error("lipc failed for 00:11:22:33:44:55") end,
            close = function() closed = closed + 1 end,
        }
    end,
}
local real_lipc = require("bluetooth/controller/kindle_lipc_for_tests")
logs = {}
check(real_lipc.readHash("ListPaired") == nil, "lipc: a throwing read is nil")
check(destroyed == 1 and closed == 1, "lipc: hash array destroyed and handle closed, got " .. destroyed .. "/" .. closed)
for _, line in ipairs(logs) do
    check(not line:find(MAC, 1, true), "lipc: MAC unmasked in log: " .. line)
end

if failures > 0 then
    os.exit(1)
end
print("kindle_test: ok")
