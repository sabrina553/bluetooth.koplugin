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

local bluez = {}

function bluez:new(ctrl)
    self.__index = self
    return setmetatable({ controller = ctrl }, self)
end

function bluez:status()
    local handle = io.popen('bluetoothctl show')
    local output = handle:read("*a")
    handle:close()

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
    os.execute('bluetoothctl power on &')
end

function bluez:disable()
    logger.dbg("Bluez: Disabling Bluetooth...")
    os.execute('bluetoothctl power off &')
end

function bluez:pair(mac)
    logger.dbg("Bluez: Pairing with Bluetooth device: " .. mac)
    os.execute(string.format(
        'echo -e "agent NoInputNoOutput\\ndefault-agent\\npair %s\\nquit\\n" | bluetoothctl &', -- maybe worth repeating this for other commands
        mac
    ))
end

function bluez:unpair(mac)
    logger.dbg("Bluez: Unpairing with Bluetooth device: " .. mac)
    os.execute('bluetoothctl remove ' .. mac .. ' &')
end

function bluez:connect(mac)
    logger.dbg("Bluez: Connecting to Bluetooth device: " .. mac)
    os.execute('bluetoothctl connect ' .. mac .. ' &') -- launch, don't wait
end

function bluez:disconnect(mac)
    logger.dbg("Bluez: Disconnecting from Bluetooth device: " .. mac)
    os.execute('bluetoothctl disconnect ' .. mac .. ' &')
end

function bluez:trust(mac)
    logger.dbg("Bluez: Trusting Bluetooth device: " .. mac)
    os.execute('bluetoothctl trust ' .. mac .. ' &')
end

function bluez:untrust(mac)
    logger.dbg("Bluez: Untrusting Bluetooth device: " .. mac)
    os.execute('bluetoothctl untrust ' .. mac .. ' &')
end

function bluez:block(mac)
    logger.dbg("Bluez: Blocking Bluetooth device: " .. mac)
    os.execute('bluetoothctl block ' .. mac .. ' &')
end

function bluez:unblock(mac)
    logger.dbg("Bluez: Unblocking Bluetooth device: " .. mac)
    os.execute('bluetoothctl unblock ' .. mac .. ' &')
end

local function parseDeviceLine(line)
    local mac, rest = string.match(line, "Device (%x%x:%x%x:%x%x:%x%x:%x%x:%x%x)%s+(.*)")
    if not mac then
        return nil
    end
    rest = rest and rest:gsub("^%s+", ""):gsub("%s+$", "") or ""
    local dashMac = mac:gsub(":", "-")
    local name = (rest == "" or rest:upper() == dashMac:upper()) and "Unknown" or rest
    return mac, name
end

function bluez:knownDevices()
    local handle = io.popen("bluetoothctl devices")
    local output = handle:read("*a")
    handle:close()

    local devices = {}
    for line in string.gmatch(output, "[^\r\n]+") do
        local mac, name = parseDeviceLine(line)
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
    os.execute(string.format('bluetoothctl --timeout %d scan on &', duration))
end

function bluez:info(mac)
    local cmd = "bluetoothctl info " .. mac
    local handle = io.popen(cmd)
    local output = handle:read("*a")
    handle:close()

    return output
end

return bluez