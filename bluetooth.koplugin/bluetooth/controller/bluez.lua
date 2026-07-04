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

local function execOk(cmd)
    local ok, exit_type, code = os.execute(cmd)
    if type(ok) == "number" then
        return ok == 0          -- Lua 5.1
    end
    return ok == true or code == 0  -- Lua 5.2+
end

function bluez:isOn()
    return execOk('bluetoothctl show | grep -o "Powered: yes"')
end

function bluez:isOff()
    return execOk('bluetoothctl show | grep -o "Powered: no"')
end

function bluez:status()
    if self:isOn() then
        logger.info("Bluetooth is enabled")
        return true
    elseif self:isOff() then
        logger.info("Bluetooth is disabled")
        return false
    end
end

function bluez:enable()
    logger.info("Enabling Bluetooth...")
    os.execute('bluetoothctl power on')
end

function bluez:disable()
    logger.info("Disabling Bluetooth...")
    os.execute('bluetoothctl power off')
end

function bluez:pair(mac)
    if not self:isOn() then
        self:enable()
    end
    logger.info("Pairing with Bluetooth device: " .. mac)
    os.execute('bluetoothctl pair ' .. mac .. ' &')
end

function bluez:unpair(mac)
    -- doesn't know if it is paired?
    logger.info("Unpairing with Bluetooth device: " .. mac)
    os.execute('bluetoothctl remove ' .. mac .. ' &')
end

function bluez:connect(mac)
    if not self:isOn() then
        self:enable()
    end

    logger.info("Connecting to Bluetooth device: " .. mac)
    os.execute('bluetoothctl connect ' .. mac .. ' &') -- launch, don't wait
end

function bluez:disconnect(mac)
    logger.info("Disconnecting from Bluetooth device: " .. mac)
    os.execute('bluetoothctl disconnect ' .. mac .. ' &')
end

--- Parses one line of `bluetoothctl devices`/scan-style output of the form
--- "Device AA:BB:CC:DD:EE:FF Some Name" (with an optional [NEW] prefix
--- handled by the caller). Returns mac, name or nil if the line doesn't match.
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
            table.insert(devices, Devices:fromScan(mac, name, self))
        end
    end
    logger.info("Found " .. #devices .. " known devices")
    return devices
end

function bluez:search(duration)
    duration = duration or 15
    logger.info("Starting background Bluetooth scan for " .. duration .. "s")
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
