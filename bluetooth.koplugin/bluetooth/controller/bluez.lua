-- bluetooth/pocketbook.lua
--[[--
--- Underneath this it uses bluez stack - bluetoothctl et al
--- Commands:
	list		            List available controllers
	show		            Controller information
	select		            Select default controller
x	devices		            List available devices, with an optional property as the filter
	system-alias	        Set controller alias
	reset-alias	            Reset controller alias
x	power		            Set controller power
	pairable		        Set controller pairable mode
	discoverable		    Set controller discoverable mode
	discoverable-timeout    Set discoverable timeout
	agent		            Enable/disable agent with given capability
	default-agent	        Set agent as the default one
	advertise	            Enable/disable advertising with given type
	set-alias	            Set device alias
x	scan		            Scan for devices
	info		            Device/Set information
m	pair		            Pair with device
	cancel-pairing	        Cancel pairing with device
	trust		            Trust device
	untrust		            Untrust device
	block		            Block device
	unblock		            Unblock device
m	remove		            Remove device
m	connect		            Connect a device and all its profiles or optionally connect a single profile only
m	disconnect		        Disconnect a device or optionally disconnect a single profile only
	wake		            Get/Set wake support
	bearer		            Get/Set preferred bearer
---
--]] --
local _ = require("gettext")
local logger = require("logger")
local Devices = require("bluetooth/controller/devices")
local Parse = require("bluetooth/controller/bluetoothctl_parse")

local bluez = {}

-- bluetoothctl and netagent write progress to stdout/stderr, which KOReader
-- inherits and logs, so background commands are silenced. Output is only
-- captured where we actually parse it.
local function run(cmd)
    os.execute(cmd .. " >/dev/null 2>&1 &")
end

local CAPTURE_TIMEOUT_S = 5

--- Whether a shell command exits with status 0. A field, not a local, so
--- tests can replace it.
---@param cmd string
---@return boolean
function bluez.shellSucceeds(cmd)
    local rc = os.execute(cmd .. " >/dev/null 2>&1")
    -- LuaJIT returns the status; with Lua 5.2 compatibility it returns true.
    return rc == 0 or rc == true
end

--- Which `timeout` syntax the reader understands, found once and kept:
--- "k" (GNU and newer BusyBox: `timeout -k 1 SECS`), "t" (BusyBox 1.22, on
--- PocketBook firmware 6.10: `timeout -t SECS`, no -k) or "none".
--- A tester's reader rejected -k, so every wrapped read failed (crash.log
--- 2026-10-18, "timeout: invalid option -- 'k'").
---@return string
function bluez.timeoutStyle()
    if not bluez.timeout_style then
        if bluez.shellSucceeds("timeout -k 1 1 true") then
            bluez.timeout_style = "k"
        elseif bluez.shellSucceeds("timeout -t 1 true") then
            bluez.timeout_style = "t"
        else
            bluez.timeout_style = "none"
            logger.warn("Bluez: no usable timeout command, reads run without a limit")
        end
        logger.dbg("Bluez: timeout style", bluez.timeout_style)
    end
    return bluez.timeout_style
end

--- Prefix that limits a command to `secs` seconds, in the reader's syntax.
--- Old BusyBox has no -k, so it sends KILL straight away: the wrapped
--- commands only read, so nothing is lost by killing them.
---@param secs number
---@return string
function bluez.timeoutPrefix(secs)
    local style = bluez.timeoutStyle()
    if style == "k" then
        return ("timeout -k 1 %d "):format(secs)
    elseif style == "t" then
        return ("timeout -t %d -s KILL "):format(secs)
    end
    return ""
end

--- Output of a command, stdout and stderr together (a rejected command
--- reports on stderr). A field, not a local, so tests can replace it.
---@param cmd string
---@return string
function bluez.capture(cmd)
    -- A bluetoothctl that cannot reach a restarting bluetoothd never returns
    -- and froze KOReader until it was killed (13:12:52 and 13:14:08 on
    -- 2026-10-13, a read right after a quick resume). The timeout turns the
    -- hang into a failed read.
    -- The exit status is appended because a timed-out read looks like an
    -- empty device list otherwise, and saving that wiped the starred flags.
    bluez.last_rc = nil
    local handle = io.popen(bluez.timeoutPrefix(CAPTURE_TIMEOUT_S) .. cmd .. " 2>&1; echo __rc=$?")
    if not handle then
        return ""
    end
    local output = handle:read("*a") or ""
    handle:close()
    local rc = output:match("__rc=(%d+)%s*$")
    if rc then
        bluez.last_rc = tonumber(rc)
        output = output:gsub("__rc=%d+%s*$", "")
    end
    return output
end

--- Whether the last capture was cut off by the timeout: 124 (GNU), 143 (BusyBox
--- after SIGTERM, measured on the reader) or 137 (it needed the kill).
function bluez.lastTimedOut()
    return bluez.last_rc == 124 or bluez.last_rc == 143 or bluez.last_rc == 137
end

--- Whether a read with this exit status and output failed: it timed out, or
--- the command exited with an error that is not just bluetoothctl rejecting
--- an unknown spelling. A failed read is never an empty list (a `timeout`
--- that rejected its options printed its usage with status 1, and that was
--- read as "no devices", crash.log 2026-10-18).
---@param rc number|nil
---@param output string|nil
---@return boolean
function bluez.readFailed(rc, output)
    if rc == nil then return false end -- no status captured, as in tests
    if rc == 124 or rc == 143 or rc == 137 then return true end
    return rc ~= 0 and not Parse.isUnsupportedCommand(output)
end

function bluez:new(ctrl)
    self.__index = self
    return setmetatable({ controller = ctrl }, self)
end

function bluez:status()
    local output = self.capture('bluetoothctl show')

    if output:find("Powered: yes") then
        logger.dbg("Bluez: Bluetooth is enabled")
        return true
    elseif output:find("Powered: no") then
        logger.dbg("Bluez: Bluetooth is disabled")
        return false
    end
    logger.warn("Bluez: could not determine power state")
    return false
end

function bluez:enable()
    logger.dbg("Bluez: Enabling Bluetooth...")
    run('bluetoothctl power on')
end

function bluez:disable()
    logger.dbg("Bluez: Disabling Bluetooth...")
    run('bluetoothctl power off')
end

-- Pairing needs an agent that stays on the bus to answer the other side
-- (a phone asks to confirm). A one-shot `bluetoothctl pair` exits at once and
-- takes its agent with it, so phones failed while keyboards and remotes,
-- which ask nothing, paired fine (vault Docs/D-Bus findings, 2026-10-13).
-- One session runs the agent, pairs, and stays open PAIR_SESSION_S.
-- bluetoothctl registers its own agent at start, so the capability goes on
-- the command line: a later `agent NoInputNoOutput` is refused ("Agent is
-- already registered") and the default KeyboardDisplay agent then waits for
-- a typed "yes" to the phone's code (reader log 2026-10-26 10:17). With
-- NoInputNoOutput, pairing is Just Works. Showing the code on the reader to
-- confirm is backlog, after the stable release (Sabrina, 2026-10-26).
bluez.PAIR_SESSION_S = 20

-- A field so tests can move time.
bluez.clock = os.time

--- The shell command for one pairing session, or nil if `mac` isn't a MAC
--- (it goes into a shell command).
---@param mac string
---@return string|nil
function bluez.pairCommand(mac)
    if type(mac) ~= "string" or not mac:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") then
        return nil
    end
    return ("(printf 'default-agent\\npair %s\\n'; sleep %d; printf 'quit\\n') | %sbluetoothctl --agent NoInputNoOutput")
        :format(mac, bluez.PAIR_SESSION_S, bluez.timeoutPrefix(bluez.PAIR_SESSION_S + 5))
end

-- Lines from the pairing session worth keeping: which agent answered, what
-- the other side asked for, and how it ended. A phone failing to pair left
-- nothing to go on (reader log 2026-10-26 10:15).
local PAIR_LOG_PATTERNS = { "[Aa]gent", "[Aa]ttempting", "[Rr]equest", "[Pp]asskey", "[Cc]onfirm", "[Ff]ailed",
    "[Pp]airing successful", "[Pp]aired: ", "[Ee]rror", "[Nn]ot available", "[Aa]uthenticat" }

--- The session's lines worth logging, masked. Pure, for tests.
---@param text string
---@return string[]
function bluez.pairLogLines(text)
    local lines = {}
    -- bluetoothctl repaints its prompt with escape codes and \r. The prompt
    -- shows a device name ("[Someone's iPhone]#"), so it goes, and so does
    -- any 6-digit pairing code: logs are shared with testers.
    text = (text or ""):gsub("\27%[[%d;]*%a", ""):gsub("\r", "\n")
    for line in text:gmatch("[^\n]+") do
        line = line:gsub("%[[^%]]*%]#%s*", ""):gsub("^%s+", "")
        for _, pattern in ipairs(PAIR_LOG_PATTERNS) do
            if line:find(pattern) then
                line = Parse.maskMac(line):gsub("%f[%d]%d%d%d%d%d%d%f[%D]", "NNNNNN")
                table.insert(lines, line)
                break
            end
        end
    end
    return lines
end

--- Starts a pairing session; false when it didn't start. One session at a
--- time: two at once both claimed the default agent and mixed their output
--- (reader log 2026-10-26 10:23:09 and 10:23:11).
---@param mac string
---@return boolean
function bluez:pair(mac)
    local cmd = bluez.pairCommand(mac)
    if not cmd then
        logger.warn("Bluez: not pairing, not a MAC: " .. Parse.maskMac(tostring(mac)))
        return false
    end
    local now = bluez.clock()
    if bluez.pair_busy_until and now < bluez.pair_busy_until then
        logger.info("Bluez: a pairing session is still running, not starting another for " .. Parse.maskMac(mac))
        return false
    end
    -- The session's own cap (PAIR_SESSION_S + 5).
    bluez.pair_busy_until = now + bluez.PAIR_SESSION_S + 5
    logger.dbg("Bluez: Pairing with Bluetooth device (agent session " .. bluez.PAIR_SESSION_S .. "s): " .. Parse.maskMac(mac))
    local out = os.tmpname()
    -- Not run(): its >/dev/null would come last and win over this file.
    os.execute(cmd .. " >" .. out .. " 2>&1 &")
    -- Read once the session has ended (capped at PAIR_SESSION_S + 5).
    require("ui/uimanager"):scheduleIn(bluez.PAIR_SESSION_S + 7, function()
        local f = io.open(out, "r")
        local text = f and f:read("*a") or ""
        if f then f:close() end
        os.remove(out)
        for _, line in ipairs(bluez.pairLogLines(text)) do
            logger.info("Bluez: pair session:", line)
        end
    end)
    return true
end

function bluez:unpair(mac)
    logger.dbg("Bluez: Unpairing with Bluetooth device: " .. Parse.maskMac(mac))
    run('bluetoothctl remove ' .. mac)
end

function bluez:connect(mac)
    logger.dbg("Bluez: Connecting to Bluetooth device: " .. Parse.maskMac(mac))
    run('bluetoothctl connect ' .. mac) -- launch, don't wait
end

function bluez:disconnect(mac)
    logger.dbg("Bluez: Disconnecting from Bluetooth device: " .. Parse.maskMac(mac))
    run('bluetoothctl disconnect ' .. mac)
end

function bluez:trust(mac)
    logger.dbg("Bluez: Trusting Bluetooth device: " .. Parse.maskMac(mac))
    run('bluetoothctl trust ' .. mac)
end

function bluez:untrust(mac)
    logger.dbg("Bluez: Untrusting Bluetooth device: " .. Parse.maskMac(mac))
    run('bluetoothctl untrust ' .. mac)
end

function bluez:block(mac)
    logger.dbg("Bluez: Blocking Bluetooth device: " .. Parse.maskMac(mac))
    run('bluetoothctl block ' .. mac)
end

function bluez:unblock(mac)
    logger.dbg("Bluez: Unblocking Bluetooth device: " .. Parse.maskMac(mac))
    run('bluetoothctl unblock ' .. mac)
end

-- Spellings of "list paired devices", newest first. BlueZ 5.65 added
-- `devices Paired`; older versions (5.52 on PocketBook) only have
-- `paired-devices`, and newer ones dropped it. Whichever works is remembered.
bluez.PAIRED_COMMANDS = { "bluetoothctl devices Paired", "bluetoothctl paired-devices" }
local PAIRED_COMMANDS = bluez.PAIRED_COMMANDS

--- MACs of paired devices as a set, or nil if no spelling is understood.
--- A failed read returns nil, true.
---@return table<string, boolean>|nil, boolean|nil
function bluez:pairedMacs()
    local candidates = bluez.paired_command and { bluez.paired_command } or PAIRED_COMMANDS

    for _, cmd in ipairs(candidates) do
        local output = self.capture(cmd)
        if bluez.readFailed(bluez.last_rc, output) then
            return nil, true
        end
        if not Parse.isUnsupportedCommand(output) then
            if bluez.paired_command ~= cmd then
                bluez.paired_command = cmd
                logger.info("Bluez: listing paired devices with", cmd,
                    "| bluetoothctl", (self.capture("bluetoothctl version"):gsub("%s+$", "")))
            end
            local paired = {}
            for _, entry in ipairs(Parse.deviceList(output)) do
                paired[entry.mac] = true
            end
            return paired
        end
    end

    logger.warn("Bluez: no supported command lists paired devices")
    return nil
end

--- Every device BlueZ remembers, including everything a scan has seen.
--- Unpaired ones are marked `skip_info`: their name is already in the
--- listing, and running `bluetoothctl info` on each one is what made
--- refreshes slow once a scan had cached a few dozen devices.
function bluez:knownDevices()
    local output = self.capture("bluetoothctl devices")
    if bluez.readFailed(bluez.last_rc, output) then
        logger.warn("Bluez: listing devices failed, status", bluez.last_rc)
        return nil -- a failed read, not an empty list
    end
    local listing = Parse.deviceList(output)
    local paired, failed = self:pairedMacs()
    if failed then
        return nil
    end

    local devices = {}
    for _, entry in ipairs(listing) do
        local dev = Devices:fromScan(entry.mac, entry.name, self, self.controller)
        if paired then
            dev.paired = paired[entry.mac] == true
            dev.skip_info = not dev.paired
        end
        table.insert(devices, dev)
    end
    logger.dbg("Bluez: Found " .. #devices .. " known devices")
    return devices
end

local SNAPSHOT_TIMEOUT_S = 20
-- First check soon, then back off: a D-Bus read finishes in about 5 ms but
-- waited a full 0.2 s to be picked up (0.23 s against 0.42 s for
-- bluetoothctl on the reader, 2026-10-13). Slow reads cost a few more checks.
local SNAPSHOT_POLL_FIRST_S = 0.05
local SNAPSHOT_POLL_S = 0.2
local snapshot_counter = 0

--- One shell script that reads everything a refresh needs: the device list,
--- the paired list (both spellings until one is known to work) and `info`
--- for each paired device. Each step has its own 5 s timeout, and the
--- sections are parsed by Parse.snapshot.
---@return string
function bluez.snapshotScript()
    local t = bluez.timeoutPrefix(CAPTURE_TIMEOUT_S)
    -- PAIRED collects the paired listings so the MACs need no second run.
    local lines = {
        'PAIRED=""',
        'section() { name=$1; shift; out=$("$@" 2>&1); rc=$?; echo "@@section $name"; echo "$out"; echo "@@rc $rc";'
            .. ' case "$name" in paired*) PAIRED="$PAIRED\n$out";; esac; }',
        "section devices " .. t .. " bluetoothctl devices",
    }
    for i, cmd in ipairs(bluez.PAIRED_COMMANDS) do
        if not bluez.paired_command or bluez.paired_command == cmd then
            table.insert(lines, ("section paired%d %s %s"):format(i, t, cmd))
        end
    end
    table.insert(lines, "macs=$(printf '%s' \"$PAIRED\" | sed -n 's/^Device \\([0-9A-Fa-f:]*\\) .*/\\1/p' | sort -u)")
    table.insert(lines, 'for m in $macs; do section "info $m" ' .. t .. ' bluetoothctl info "$m"; done')
    return table.concat(lines, "\n") .. "\n"
end

--- Runs a script in the background and calls done(text) with its output, or
--- done(nil) if it never finishes. Polled from the UI loop, so nothing
--- blocks. A field, not a local, so tests can replace it with a synchronous one.
---@param script string
---@param done fun(text: string|nil)
function bluez.runAsync(script, done)
    local UIManager = require("ui/uimanager")
    snapshot_counter = snapshot_counter + 1
    local base = os.tmpname()
    local script_path, out_path = base .. ".sh", base .. ".out"
    local f = io.open(script_path, "w")
    if not f then
        os.remove(base)
        return done(nil)
    end
    f:write(script)
    f:close()
    -- Written to .part and renamed, so a half-written file is never read.
    -- If the script file is gone afterwards, the poll gave up (its cleanup
    -- removes it), so the late output is deleted instead of leaking in /tmp.
    os.execute(("( %ssh %s > %s.part 2>&1; mv %s.part %s; [ -e %s ] || rm -f %s ) >/dev/null 2>&1 &")
        :format(bluez.timeoutPrefix(SNAPSHOT_TIMEOUT_S), script_path, out_path, out_path, out_path, script_path, out_path))

    local deadline = os.time() + SNAPSHOT_TIMEOUT_S + 5
    local function cleanup()
        os.remove(base); os.remove(script_path); os.remove(out_path)
    end
    local delay = SNAPSHOT_POLL_FIRST_S
    local function poll()
        local out = io.open(out_path, "r")
        if out then
            local text = out:read("*a")
            out:close()
            cleanup()
            return done(text)
        end
        if os.time() > deadline then
            cleanup()
            return done(nil)
        end
        delay = math.min(delay * 2, SNAPSHOT_POLL_S)
        UIManager:scheduleIn(delay, poll)
    end
    UIManager:scheduleIn(delay, poll)
end

--- Devices from the output of snapshotScript, or nil if the read failed
--- (anything timed out), like knownDevices(). Paired devices come with their
--- info already parsed; every device is marked `skip_info` so the controller
--- does not query them again.
---@param text string|nil
function bluez:devicesFromSnapshot(text)
    if not text then return nil end
    local sections = Parse.snapshot(text)
    -- A section without a status was cut off.
    local function failed(section)
        return section == nil or section.rc == nil or bluez.readFailed(section.rc, section.text)
    end

    local listing = sections.devices
    if failed(listing) then
        logger.warn("Bluez: listing devices failed, status", listing and listing.rc)
        return nil
    end

    local paired
    for i, cmd in ipairs(bluez.PAIRED_COMMANDS) do
        local section = sections["paired" .. i]
        if section then
            if failed(section) then return nil end
            if not Parse.isUnsupportedCommand(section.text) then
                bluez.paired_command = cmd
                paired = {}
                for _, entry in ipairs(Parse.deviceList(section.text)) do
                    paired[entry.mac] = true
                end
                break
            end
        end
    end

    local devices = {}
    for _, entry in ipairs(Parse.deviceList(listing.text)) do
        local dev = Devices:fromScan(entry.mac, entry.name, self, self.controller)
        if paired then
            dev.paired = paired[entry.mac] == true
            local info = sections["info " .. entry.mac]
            if dev.paired and info and not failed(info) then
                dev:parseInfo(info.text)
            end
        end
        dev.skip_info = paired ~= nil
        table.insert(devices, dev)
    end
    logger.dbg("Bluez: Found " .. #devices .. " known devices (snapshot)")
    return devices
end

--- Starts a read without blocking; done(devices) gets nil on a failed read.
---@param done fun(devices: table|nil)
function bluez:readSnapshot(done)
    bluez.runAsync(bluez.snapshotScript(), function(text)
        done(self:devicesFromSnapshot(text))
    end)
end

function bluez:search(duration)
    duration = duration or 15
    logger.dbg("Bluez: Starting background Bluetooth scan for " .. duration .. "s")
    run(string.format('bluetoothctl --timeout %d scan on', duration))
end

function bluez:info(mac)
    return self.capture("bluetoothctl info " .. mac)
end

return bluez