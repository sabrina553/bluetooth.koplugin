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

--- Output of a command, stdout and stderr together (a rejected command
--- reports on stderr). A field, not a local, so tests can replace it.
---@param cmd string
---@return string
function bluez.capture(cmd)
    local handle = io.popen(cmd .. " 2>&1")
    if not handle then
        return ""
    end
    local output = handle:read("*a") or ""
    handle:close()
    return output
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
    logger.dbg("Bluez: Pairing with Bluetooth device: " .. mac)
    run('bluetoothctl pair ' .. mac)
    -- os.execute(string.format(
    --     'echo -e "agent NoInputNoOutput\\ndefault-agent\\npair %s\\nquit\\n" | bluetoothctl &', -- maybe worth repeating this for other commands
    --     mac
    -- ))
end

function bluez:unpair(mac)
    logger.dbg("Bluez: Unpairing with Bluetooth device: " .. mac)
    run('bluetoothctl remove ' .. mac)
end

function bluez:connect(mac)
    logger.dbg("Bluez: Connecting to Bluetooth device: " .. mac)
    run('bluetoothctl connect ' .. mac) -- launch, don't wait
end

function bluez:disconnect(mac)
    logger.dbg("Bluez: Disconnecting from Bluetooth device: " .. mac)
    run('bluetoothctl disconnect ' .. mac)
end

function bluez:trust(mac)
    logger.dbg("Bluez: Trusting Bluetooth device: " .. mac)
    run('bluetoothctl trust ' .. mac)
end

function bluez:untrust(mac)
    logger.dbg("Bluez: Untrusting Bluetooth device: " .. mac)
    run('bluetoothctl untrust ' .. mac)
end

function bluez:block(mac)
    logger.dbg("Bluez: Blocking Bluetooth device: " .. mac)
    run('bluetoothctl block ' .. mac)
end

function bluez:unblock(mac)
    logger.dbg("Bluez: Unblocking Bluetooth device: " .. mac)
    run('bluetoothctl unblock ' .. mac)
end

function bluez:knownDevices()
    local output = self.capture("bluetoothctl devices")

    local devices = {}
    for line in string.gmatch(output, "[^\r\n]+") do
        local mac, name = Parse.deviceLine(line)
        if mac then
            table.insert(devices, Devices:fromScan(mac, name, self, self.controller))
        end
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