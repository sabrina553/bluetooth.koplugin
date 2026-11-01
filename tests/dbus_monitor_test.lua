-- Run from the repo root: luajit tests/dbus_monitor_test.lua
-- The shell is faked; the output file is a real temporary file.
package.path = "bluetooth.koplugin/?.lua;" .. package.path
package.preload["gettext"] = function() return function(s) return s end end
local warnings = {}
package.preload["logger"] = function()
    local noop = function() end
    return { dbg = noop, info = noop, err = noop, warn = function(...) table.insert(warnings, table.concat({ ... }, " ")) end }
end
local queue = {}
package.preload["ui/uimanager"] = function()
    return {
        scheduleIn = function(_, _, fn) table.insert(queue, fn) end,
        unschedule = function(_, fn) for i = #queue, 1, -1 do if queue[i] == fn then table.remove(queue, i) end end end,
    }
end

local Bluez = require("bluetooth/controller/bluez")
local DbusMonitor = require("bluetooth/controller/dbus_monitor")

local failures = 0
local function check(description, actual, expected)
    if actual ~= expected then
        failures = failures + 1
        print(("FAIL %s: got %s, expected %s"):format(description, tostring(actual), tostring(expected)))
    end
end
local function runQueued()
    local q = queue
    queue = {}
    for _, fn in ipairs(q) do fn() end
end

DbusMonitor.PID_FILE = os.tmpname()
os.remove(DbusMonitor.PID_FILE)
Bluez.timeout_style = "k"

-- The fake shell records commands; starting the monitor writes the PID the
-- way `echo $! >file` would.
local commands = {}
local real_execute = os.execute
os.execute = function(cmd)
    table.insert(commands, cmd)
    local pidfile = cmd:match("echo %$! >(%S+)$")
    if pidfile then
        local f = io.open(pidfile, "w"); f:write("4242\n"); f:close()
    end
    return 0
end

local changes = 0
local m = DbusMonitor.start(function() changes = changes + 1 end)
check("started", m ~= nil, true)
check("start command is capped and filtered", commands[#commands]:find(
    "^timeout %-k 1 600 dbus%-monitor %-%-system 'type=signal,sender=org%.bluez' >") ~= nil, true)
check("pid read back", m and m.pid, 4242)

local function append(text)
    local f = io.open(m.out, "a"); f:write(text); f:close()
end
local CONNECTED = 'signal time=5 sender=:1.1 -> destination=(null destination) serial=5 path=/org/bluez/hci0/dev_00_11_22_33_44_02; interface=org.freedesktop.DBus.Properties; member=PropertiesChanged\n'
    .. '   string "org.bluez.Device1"\n   array [\n      dict entry(\n         string "Connected"\n         variant             boolean true\n      )\n   ]\n'

append("")
runQueued()
check("nothing written: no change", changes, 0)
append(CONNECTED)
runQueued()
check("a change is reported", changes, 1)
runQueued()
check("old output is not read again", changes, 0 + 1)
check("keeps checking", #queue, 1)

m:stop()
check("stop kills the pid", commands[#commands], "kill 4242 >/dev/null 2>&1")
check("stop cancels the timer", #queue, 0)
check("stop removes the output", io.open(m.out, "r"), nil)
check("stop removes the pid file", io.open(DbusMonitor.PID_FILE, "r"), nil)
local n = #commands
m:stop()
check("stopping twice is harmless", #commands, n)

-- Too much output: stop rather than fill /tmp.
m = DbusMonitor.start(function() end)
local saved_max = DbusMonitor.MAX_BYTES
DbusMonitor.MAX_BYTES = 10
append(CONNECTED)
runQueued()
check("over the cap: stopped", m.stopped, true)
check("over the cap: warned", warnings[#warnings]:find("stopping live updates", 1, true) ~= nil, true)
DbusMonitor.MAX_BYTES = saved_max

-- No PID came back: no monitor, the poll carries on.
os.execute = function(cmd) table.insert(commands, cmd); return 0 end
check("could not start", DbusMonitor.start(function() end), nil)

-- A PID file left by a crash is cleaned up; a reused PID that is not
-- dbus-monitor is left alone. Our own PID (this luajit) stands in for it.
local own = io.open("/proc/self/stat", "r")
local self_pid = own and tonumber(own:read("*l"):match("^(%d+)"))
if own then own:close() end
if self_pid then
    local f = io.open(DbusMonitor.PID_FILE, "w"); f:write(self_pid .. "\n"); f:close()
    commands = {}
    DbusMonitor.cleanupStale()
    check("reused pid not killed", #commands, 0)
    check("stale pid file removed", io.open(DbusMonitor.PID_FILE, "r"), nil)
end

os.execute = real_execute
if failures > 0 then
    print(failures .. " failure(s)")
    os.exit(1)
end
print("all dbus_monitor tests passed")
