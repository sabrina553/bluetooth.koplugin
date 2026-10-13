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

--- Output of a command, stdout and stderr together (a rejected command
--- reports on stderr). A field, not a local, so tests can replace it.
---@param cmd string
---@return string
function bluez.capture(cmd)
    -- A bluetoothctl that cannot reach a restarting bluetoothd never returns
    -- and froze KOReader until it was killed (13:12:52 and 13:14:08 on
    -- 2026-10-13, a read right after a quick resume). The timeout turns the
    -- hang into a failed read. BusyBox and GNU timeout both take -k.
    -- The exit status is appended because a timed-out read looks like an
    -- empty device list otherwise, and saving that wiped the starred flags.
    bluez.last_rc = nil
    local handle = io.popen("timeout -k 1 " .. CAPTURE_TIMEOUT_S .. " " .. cmd .. " 2>&1; echo __rc=$?")
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

function bluez:pair(mac)
    logger.dbg("Bluez: Pairing with Bluetooth device: " .. Parse.maskMac(mac))
    run('bluetoothctl pair ' .. mac)
    -- os.execute(string.format(
    --     'echo -e "agent NoInputNoOutput\\ndefault-agent\\npair %s\\nquit\\n" | bluetoothctl &', -- maybe worth repeating this for other commands
    --     mac
    -- ))
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
local PAIRED_COMMANDS = { "bluetoothctl devices Paired", "bluetoothctl paired-devices" }

--- MACs of paired devices as a set, or nil if no spelling is understood.
---@return table<string, boolean>|nil
function bluez:pairedMacs()
    local candidates = bluez.paired_command and { bluez.paired_command } or PAIRED_COMMANDS

    for _, cmd in ipairs(candidates) do
        local output = self.capture(cmd)
        if bluez.lastTimedOut() then
            return nil
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
    local listing = Parse.deviceList(self.capture("bluetoothctl devices"))
    if bluez.lastTimedOut() then
        logger.warn("Bluez: listing devices timed out")
        return nil -- a failed read, not an empty list
    end
    local paired = self:pairedMacs()
    if paired == nil and bluez.lastTimedOut() then
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

function bluez:search(duration)
    duration = duration or 15
    logger.dbg("Bluez: Starting background Bluetooth scan for " .. duration .. "s")
    run(string.format('bluetoothctl --timeout %d scan on', duration))
end

function bluez:info(mac)
    return self.capture("bluetoothctl info " .. mac)
end

return bluez