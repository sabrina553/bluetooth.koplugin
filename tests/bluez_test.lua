-- Run from the repo root: luajit tests/bluez_test.lua
package.path = "bluetooth.koplugin/?.lua;" .. package.path
package.preload["gettext"] = function() return function(s) return s end end
package.preload["logger"] = function()
    local noop = function() end
    return { dbg = noop, info = noop, warn = noop, err = noop }
end
package.preload["ui/uimanager"] = function() return {} end

local Bluez = require("bluetooth/controller/bluez")
-- Kept before a later test swaps in a synchronous stand-in.
local realRunAsync = Bluez.runAsync

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
        cmd and cmd:find("| timeout %-k 1 25 bluetoothctl %-%-agent NoInputNoOutput; echo; echo @@done %) >/tmp/lua_test 2>&1$") ~= nil, true)
    check("pair: one grep -e per result, no -E", cmd and cmd:find("grep -q -e '^[^ ]*Pairing successful' -e '^[^ ]*\\[[^]]*\\][^ ]*# [^ ]*Pairing successful' -e '^[^ ]*Failed to pair' ", 1, true) ~= nil, true)
    check("pair: not a MAC is refused", Bluez.pairCommand("00:11:22:33:44:55; reboot", "/tmp/x"), nil)
    check("pair: nil is refused", Bluez.pairCommand(nil, "/tmp/x"), nil)
    check("pair: an odd output path is refused", Bluez.pairCommand("00:11:22:33:44:55", "/tmp/x; reboot"), nil)

    check("pair result: success", Bluez.pairResult("...\nPairing successful\n"), true)
    check("pair result: failure", Bluez.pairResult("Failed to pair: org.bluez.Error.ConnectionAttemptFailed\n"), false)
    check("pair result: device gone", Bluez.pairResult("Device 00:11:22:33:44:55 not available\n"), false)
    check("pair result: no controller", Bluez.pairResult("No default controller available\n"), false)
    check("pair result: cut off", Bluez.pairResult("Attempting to pair\n"), nil)
    -- Only bluetoothctl's own lines count, with or without its prompt (BlueZ
    -- 5.52 client/main.c), never a nearby device's name.
    check("pair result: a device named like a failure", Bluez.pairResult("[NEW] Device 00:11:22:33:44:55 Failed to pair\n"), nil)
    check("pair result: a renamed device", Bluez.pairResult("[CHG] Device 00:11:22:33:44:55 Name: Pairing successful\n"), nil)
    check("pair result: a device named not available", Bluez.pairResult("[NEW] Device 00:11:22:33:44:55 not available\n"), nil)
    check("pair result: coloured device line",
        Bluez.pairResult("[\1\27[0;92m\2NEW\1\27[0m\2] Device 00:11:22:33:44:55 Failed to pair\n"), nil)
    check("pair result: a name hiding a prompt",
        Bluez.pairResult("[NEW] Device 00:11:22:33:44:55 x]# Pairing successful\n"), nil)
    check("pair result: success after the prompt", Bluez.pairResult("[bluetooth]# Pairing successful\r\n"), true)
    check("pair result: failure after a coloured prompt",
        Bluez.pairResult("\1\27[0;94m\2[bluetooth]\1\27[0m\2# Failed to pair: org.bluez.Error.AuthenticationFailed\n"), false)
    check("pair result: gone after a device prompt",
        Bluez.pairResult("[Someone's iPhone]# Device 00:11:22:33:44:55 not available\n"), false)
    check("pair result: after a repainted prompt", Bluez.pairResult("[bluetooth]# \r\27[KPairing successful\n"), true)

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
        text:find("default%-agent\npair 00:11:22:33:44:55\nPairing successful\nquit\n\n@@done\n$") ~= nil, true)
    check("pair: session ends once it has a result, took " .. took .. "s", took <= 4, true)

    -- A failure ends the session early too, and silence ends it once the
    -- feeder's count runs out, with quit sent.
    local function session(reply, session_s)
        Bluez.PAIR_SESSION_S = session_s
        local path = os.tmpname()
        local stand_in = "awk '{print; fflush()} " .. (reply and ('/^pair /{print \"' .. reply .. '\"; fflush()} ') or "")
            .. "/^quit/{exit}'"
        local t0 = os.time()
        -- An outer timeout, so a feeder that never counts fails instead of hanging.
        local script = os.tmpname()
        local sh = io.open(script, "w")
        sh:write((Bluez.pairCommand("00:11:22:33:44:55", path):gsub("bluetoothctl %-%-agent NoInputNoOutput", stand_in)))
        sh:close()
        os.execute("timeout 10 sh " .. script)
        os.remove(script)
        local fh = io.open(path, "r"); local got = fh and fh:read("*a") or ""; if fh then fh:close() end
        os.remove(path)
        return got, os.time() - t0
    end
    local failed, failed_took = session("Failed to pair: org.bluez.Error.AuthenticationFailed", 20)
    check("pair: a failure is reported", Bluez.pairResult(failed), false)
    check("pair: a failure ends the session early, took " .. failed_took .. "s", failed_took <= 4, true)
    local silent, silent_took = session(nil, 2)
    check("pair: silence still sends quit", silent:find("\nquit\n\n@@done\n", 1, true) ~= nil, true)
    check("pair: silence ends after the session, took " .. silent_took .. "s", silent_took >= 2 and silent_took <= 5, true)
    -- A device named like a result neither ends nor decides the session.
    local named, named_took = session("[NEW] Device 00:11:22:33:44:55 Failed to pair", 2)
    check("pair: a device name is not a result", Bluez.pairResult(named), nil)
    check("pair: a device name doesn't end the session, took " .. named_took .. "s", named_took >= 2, true)
    -- The real lines still do, behind the prompt too.
    local prompted, prompted_took = session("\\033[0;94m[bluetooth]\\033[0m# Pairing successful", 20)
    check("pair: success behind the prompt is reported", Bluez.pairResult(prompted), true)
    check("pair: success behind the prompt ends early, took " .. prompted_took .. "s", prompted_took <= 4, true)
    local gone, gone_took = session("[bluetooth]# Device 00:11:22:33:44:55 not available", 20)
    check("pair: a gone device is reported", Bluez.pairResult(gone), false)
    check("pair: a gone device ends the session early, took " .. gone_took .. "s", gone_took <= 4, true)
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

    -- Only the shell's own "@@done" line ends it, not a device of that name.
    local out_path
    os.execute = function(cmd) out_path = cmd:match(">(%S+) 2>&1") return 0 end
    check("pair: a session to watch starts", Bluez:pair("00:11:22:33:44:55"), true)
    local fh = io.open(out_path, "w")
    fh:write("[NEW] Device 00:11:22:33:44:55 @@done\n[CHG] Device 00:11:22:33:44:55 Name: @@done\n")
    fh:close()
    tick()
    check("pair: a device named @@done doesn't end it", Bluez.pair_session ~= nil, true)
    fh = io.open(out_path, "a")
    fh:write("[bluetooth]# quit\n@@done\n")
    fh:close()
    tick()
    check("pair: its own @@done line ends it", Bluez.pair_session, nil)
    local left = io.open(out_path, "r")
    check("pair: its output file is removed", left, nil)
    if left then left:close(); os.remove(out_path) end
    finish()

    -- A finishing session leaves a newer session's flag alone.
    check("pair: next session starts", Bluez:pair("00:11:22:33:44:66"), true)
    local newer = {}
    Bluez.pair_session = newer
    finish()
    check("pair: an old session doesn't clear a newer one", Bluez.pair_session == newer, true)

    os.execute, UIManager.scheduleIn, Bluez.pair_session = real_execute, saved_schedule, nil
end

-- runAsync counts ticks, not os.time: a suspend jumps the clock by hours
-- between two ticks while the timer and the command stood still.
do
    local real_execute, real_time, real_tmpname = os.execute, os.time, os.tmpname
    local UIManager = require("ui/uimanager")
    local saved_schedule = UIManager.scheduleIn
    local queue, waited = {}, 0
    UIManager.scheduleIn = function(_, delay, fn) table.insert(queue, { delay = delay, fn = fn }) end
    local function tick()
        local job = table.remove(queue, 1)
        if job then waited = waited + job.delay; job.fn() end
    end
    local clock = real_time()
    os.time = function() clock = clock + 3600; return clock end
    os.execute = function() return 0 end -- the command never runs
    local base, bases = nil, {}
    os.tmpname = function() base = real_tmpname(); table.insert(bases, base); return base end
    local function exists(path)
        local f = io.open(path, "r")
        if f then f:close() end
        return f ~= nil
    end

    -- Never finishes: gives up after the old 25 s of waiting, not on the
    -- first tick after the jump.
    local result, calls = "pending", 0
    realRunAsync("true\n", function(text) result, calls = text, calls + 1 end)
    local ticks = 0
    while #queue > 0 and ticks < 1000 do tick(); ticks = ticks + 1 end
    check("runAsync: clock jumps alone don't time it out", ticks > 100, true)
    check("runAsync: times out in the end", result, nil)
    check("runAsync: done called once", calls, 1)
    check("runAsync: waited at least 25 s", waited >= 25, true)
    check("runAsync: waited less than 25.4 s", waited < 25.4, true)
    check("runAsync: timed-out script removed", exists(base .. ".sh"), false)
    check("runAsync: timed-out temp name removed", exists(base), false)

    -- Output arriving after a jump is still read.
    result, waited, queue = "pending", 0, {}
    realRunAsync("true\n", function(text) result = text end)
    for _ = 1, 10 do tick() end
    check("runAsync: still waiting after jumps", result, "pending")
    local f = io.open(base .. ".out", "w"); f:write("hello"); f:close()
    tick()
    check("runAsync: late output read", result, "hello")
    check("runAsync: output file removed", exists(base .. ".out"), false)
    check("runAsync: script removed", exists(base .. ".sh"), false)
    check("runAsync: temp name removed", exists(base), false)

    -- Nothing left in /tmp even when a check above failed.
    for _, b in ipairs(bases) do os.remove(b); os.remove(b .. ".sh"); os.remove(b .. ".out") end
    os.execute, os.time, os.tmpname, UIManager.scheduleIn = real_execute, real_time, real_tmpname, saved_schedule
end

if failures > 0 then
    print(failures .. " failure(s)")
    os.exit(1)
end
print("all bluez tests passed")
