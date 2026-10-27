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
-- rcs gives exit statuses; without one, no status is captured.
local function fakeBluetoothctl(answers, rcs)
    local calls = {}
    Bluez.paired_command = nil
    Bluez.capture = function(cmd)
        table.insert(calls, cmd)
        Bluez.last_rc = rcs and rcs[cmd]
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

-- A command that exits with an error is a failed read, not an empty list
local USAGE = "timeout: invalid option -- 'k'\nUsage: timeout [-t SECS] [-s SIG] PROG ARGS\n"
fakeBluetoothctl({ ["bluetoothctl devices"] = USAGE }, { ["bluetoothctl devices"] = 1 })
check("error exit: listing is a failed read", Bluez:knownDevices(), nil)
fakeBluetoothctl({ ["bluetoothctl devices"] = ALL, ["bluetoothctl devices Paired"] = USAGE },
    { ["bluetoothctl devices"] = 0, ["bluetoothctl devices Paired"] = 1 })
check("error exit: paired read fails the whole read", Bluez:knownDevices(), nil)
check("error exit: no spelling remembered", Bluez.paired_command, nil)
fakeBluetoothctl({
    ["bluetoothctl devices"] = ALL,
    ["bluetoothctl devices Paired"] = "Too many arguments\n",
    ["bluetoothctl paired-devices"] = PAIRED,
}, { ["bluetoothctl devices"] = 0, ["bluetoothctl devices Paired"] = 1, ["bluetoothctl paired-devices"] = 0 })
devices = Bluez:knownDevices()
check("error exit: a rejected spelling still falls back", devices and devices[1].paired, true)

-- Snapshot read: one script's output becomes the device list
local function snap(sections)
    local out = {}
    for _, sec in ipairs(sections) do
        table.insert(out, "@@section " .. sec[1])
        table.insert(out, sec[2])
        if sec[3] ~= "cut" then table.insert(out, "@@rc " .. (sec[3] or 0)) end
    end
    return table.concat(out, "\n") .. "\n"
end
local INFO = "Device 00:11:22:33:44:55 (public)\n\tAlias: Test Pager\n\tPaired: yes\n\tConnected: yes\n"

Bluez.paired_command = nil
devices = Bluez:devicesFromSnapshot(snap({
    { "devices", ALL },
    { "paired1", PAIRED },
    { "paired2", "Invalid command" },
    { "info 00:11:22:33:44:55", INFO },
}))
check("snapshot: all devices", #devices, 3)
check("snapshot: paired flag", devices[1].paired, true)
check("snapshot: info parsed, connected", devices[1].connected, true)
check("snapshot: unpaired", devices[3].paired, false)
check("snapshot: nothing left to query", devices[1].skip_info and devices[3].skip_info, true)
check("snapshot: working spelling remembered", Bluez.paired_command, "bluetoothctl devices Paired")

-- Old BlueZ: first spelling rejected, second works
Bluez.paired_command = nil
devices = Bluez:devicesFromSnapshot(snap({
    { "devices", ALL },
    { "paired1", "Invalid command in menu main: devices" },
    { "paired2", PAIRED },
    { "info 00:11:22:33:44:55", INFO },
}))
check("snapshot: fallback spelling", devices[1].paired, true)
check("snapshot: fallback remembered", Bluez.paired_command, "bluetoothctl paired-devices")

-- A timed-out or cut-off part is a failed read, never an empty list
Bluez.paired_command = nil
check("snapshot: listing timed out", Bluez:devicesFromSnapshot(snap({ { "devices", "", 143 } })), nil)
check("snapshot: listing cut off", Bluez:devicesFromSnapshot(snap({ { "devices", ALL, "cut" } })), nil)
check("snapshot: paired timed out", Bluez:devicesFromSnapshot(snap({
    { "devices", ALL }, { "paired1", "", 124 } })), nil)
check("snapshot: listing exited with an error", Bluez:devicesFromSnapshot(snap({ { "devices", USAGE, 1 } })), nil)
check("snapshot: paired exited with an error", Bluez:devicesFromSnapshot(snap({
    { "devices", ALL }, { "paired1", USAGE, 1 } })), nil)
devices = Bluez:devicesFromSnapshot(snap({
    { "devices", ALL }, { "paired1", "Too many arguments", 1 }, { "paired2", PAIRED } }))
check("snapshot: rejected spelling with error status falls back", devices and devices[1].paired, true)
check("snapshot: no output", Bluez:devicesFromSnapshot(nil), nil)

-- An info that timed out leaves that device with listing data only
devices = Bluez:devicesFromSnapshot(snap({
    { "devices", ALL }, { "paired1", PAIRED }, { "info 00:11:22:33:44:55", "", 143 },
}))
check("snapshot: info timeout keeps device", #devices, 3)
check("snapshot: info timeout leaves connected false", devices[1].connected, false)

-- readSnapshot hands the parsed list to the callback
Bluez.runAsync = function(_, done) done(snap({ { "devices", ALL }, { "paired1", PAIRED } })) end
local got
Bluez:readSnapshot(function(list) got = list end)
check("readSnapshot: callback gets devices", got and #got, 3)

-- timeout syntax: found once, matching what the reader accepts
local function detectWith(accepts)
    local tried = {}
    Bluez.timeout_style = nil
    Bluez.shellSucceeds = function(cmd)
        table.insert(tried, cmd)
        return cmd:find(accepts, 1, true) ~= nil
    end
    return tried
end
local tried = detectWith("timeout -k")
check("timeout: GNU or new BusyBox uses -k", Bluez.timeoutPrefix(5), "timeout -k 1 5 ")
Bluez.timeoutPrefix(5)
check("timeout: detected only once", #tried, 1)
detectWith("timeout -t")
check("timeout: BusyBox 1.22 uses -t with KILL", Bluez.timeoutPrefix(5), "timeout -t 5 -s KILL ")
check("timeout: snapshot uses the detected syntax",
    Bluez.snapshotScript():find("section devices timeout -t 5 -s KILL  bluetoothctl devices", 1, true) ~= nil, true)
check("timeout: snapshot has no -k left", Bluez.snapshotScript():find("-k", 1, true), nil)
detectWith("nothing works")
check("timeout: none available runs the command bare", Bluez.timeoutPrefix(5), "")
Bluez.timeout_style = "k"

-- Pairing keeps one bluetoothctl session open with an agent (fix/pair-agent)
-- and ends it as soon as bluetoothctl reports a result.
do
    local saved_style, saved_s = Bluez.timeout_style, Bluez.PAIR_SESSION_S
    Bluez.timeout_style = "k"
    local cmd = Bluez.pairCommand("00:11:22:33:44:55", "/tmp/lua_test")
    check("pair: capped a little past the session, agent set at start",
        cmd and cmd:find("| timeout %-k 1 25 bluetoothctl %-%-agent NoInputNoOutput; echo @@done %) >/tmp/lua_test 2>&1$") ~= nil, true)
    check("pair: one grep -e per result, no -E", cmd and cmd:find("grep -q -e 'Pairing successful' -e 'Failed to pair' -e 'not available' ", 1, true) ~= nil, true)
    check("pair: not a MAC is refused", Bluez.pairCommand("00:11:22:33:44:55; reboot", "/tmp/x"), nil)
    check("pair: nil is refused", Bluez.pairCommand(nil, "/tmp/x"), nil)
    check("pair: an odd output path is refused", Bluez.pairCommand("00:11:22:33:44:55", "/tmp/x; reboot"), nil)

    check("pair result: success", Bluez.pairResult("...\nPairing successful\n"), true)
    check("pair result: failure", Bluez.pairResult("Failed to pair: org.bluez.Error.ConnectionAttemptFailed\n"), false)
    check("pair result: device gone", Bluez.pairResult("Device 00:11:22:33:44:55 not available\n"), false)
    check("pair result: no controller", Bluez.pairResult("No default controller available\n"), false)
    check("pair result: cut off", Bluez.pairResult("Attempting to pair\n"), nil)

    -- Run the real script with awk standing in for bluetoothctl: it echoes
    -- what it is fed, answers the pair with success, and stops at quit. The
    -- session must end within a few seconds, not after PAIR_SESSION_S.
    Bluez.timeout_style, Bluez.PAIR_SESSION_S = "none", 20
    local out = os.tmpname()
    local script = Bluez.pairCommand("00:11:22:33:44:55", out):gsub("bluetoothctl %-%-agent NoInputNoOutput",
        [[awk '{print; fflush()} /^pair /{print "Pairing successful"; fflush()} /^quit/{exit}']])
    local started = os.time()
    os.execute(script)
    local took = os.time() - started
    local f = io.open(out, "r"); local text = f and f:read("*a") or ""; if f then f:close() end
    os.remove(out)
    check("pair: fed default agent, pair, quit in order",
        text:find("default%-agent\npair 00:11:22:33:44:55\nPairing successful\nquit\n@@done") ~= nil, true)
    check("pair: session ends once it has a result, took " .. took .. "s", took <= 4, true)
    Bluez.timeout_style, Bluez.PAIR_SESSION_S = saved_style, saved_s
end

-- The pairing session's output is logged, prompt noise stripped, MACs masked.
do
    local text = "\27[0;94m[bluetooth]\27[0m# Agent registered\r\n[bluetooth]# Default agent request successful\n"
        .. "[CHG] Device 00:11:22:33:44:55 RSSI: -60\n"
        .. "[agent] Confirm passkey 123456 (yes/no): yes\n"
        .. "Failed to pair: org.bluez.Error.AuthenticationFailed\n"
    local lines = Bluez.pairLogLines(text)
    check("pair log: agent, request, confirm and failure kept, RSSI dropped", #lines, 4)
    check("pair log: escape codes and prompt stripped", lines[1], "Agent registered")
    local private = Bluez.pairLogLines("[Someone's iPhone]# Request confirmation\n[agent] Confirm passkey 123456 (yes/no):\n")
    check("pair log: device name in the prompt dropped", table.concat(private, "|"):find("iPhone", 1, true), nil)
    check("pair log: pairing code masked", private[2], "[agent] Confirm passkey NNNNNN (yes/no):")
    check("pair log: failure kept with its error", lines[4], "Failed to pair: org.bluez.Error.AuthenticationFailed")
    local masked = Bluez.pairLogLines("Attempting to pair with 00:11:22:33:44:55\nFailed to pair: x\n")
    check("pair log: MACs masked", table.concat(masked, "|"):find("00:11:22:33:44:55", 1, true), nil)
end

-- One pairing session at a time (reader log 2026-10-26 10:23:09 and 10:23:11).
do
    local real_execute = os.execute
    local started = 0
    os.execute = function(cmd) if cmd:find("bluetoothctl", 1, true) then started = started + 1 end return 0 end
    local UIManager = require("ui/uimanager")
    local saved_schedule = UIManager.scheduleIn
    local queue = {}
    UIManager.scheduleIn = function(_, _, fn) table.insert(queue, fn) end
    local function tick() local fn = table.remove(queue, 1); if fn then fn() end end
    local function finish() while #queue > 0 do tick() end end
    Bluez.pair_session = nil

    check("pair: not a MAC while idle is refused", select(2, Bluez:pair("nope")), "invalid")
    check("pair: not a MAC does not block", Bluez.pair_session, nil)
    check("pair: first session starts", Bluez:pair("00:11:22:33:44:55"), true)
    check("pair: a second one while it runs is busy", select(2, Bluez:pair("00:11:22:33:44:66")), "busy")
    check("pair: only one bluetoothctl started", started, 1)
    -- No @@done ever arrives (the os.execute above is fake): the session
    -- still ends after its ticks, whatever the wall clock does.
    for _ = 1, Bluez.PAIR_SESSION_S do tick() end
    check("pair: still busy before its ticks run out", Bluez:pair("00:11:22:33:44:66"), false)
    finish()
    check("pair: free once its check() ends", Bluez.pair_session, nil)

    -- A finishing session leaves a newer session's flag alone.
    check("pair: next session starts", Bluez:pair("00:11:22:33:44:66"), true)
    local newer = {}
    Bluez.pair_session = newer
    finish()
    check("pair: an old session doesn't clear a newer one", Bluez.pair_session == newer, true)

    os.execute, UIManager.scheduleIn, Bluez.pair_session = real_execute, saved_schedule, nil
end

if failures > 0 then
    print(failures .. " failure(s)")
    os.exit(1)
end
print("all bluez tests passed")
