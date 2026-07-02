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

local bluez = {}

function bluez:new()
    local bluez = setmetatable({}, pocketbook)
    return bluez
end

function bluez:isOn()
    return os.execute('bluetoothctl show  | grep -o "Powered: yes"') == 0
end

function bluez:isOff()
    return os.execute('bluetoothctl show  | grep -o "Powered: no"') == 0
end

function bluez:toggle() --menu_items
    -- PocketBook-specific Bluetooth toggle logic
    logger.info("Toggling Bluetooth connection...")
    local msg = ""
    if self:isOff() then
        self:enable()
    else
        self:disable()
    end
end

function bluez:enable() --menu_items
    -- PocketBook-specific Bluetooth connection logic
    if self:isOff() then
        logger.info("Enabling Bluetooth...")
        os.execute('bluetoothctl power on &')
    end
end

function bluez:disable() --menu_items
    -- PocketBook-specific Bluetooth disconnection logic
    if self:isOn() then
        logger.info("Disabling Bluetooth...")
        os.execute('bluetoothctl power off &')
    end
end

function bluez:pair(mac)
    os.execute('bluetoothctl -t 4 pair ' .. mac .. ' &')
    logger.info("Pairing with Bluetooth device: " .. mac)
end

function bluez:unpair(mac)
    os.execute('bluetoothctl -t 4 remove ' .. mac .. ' &')
    logger.info("Unpairing with Bluetooth device: " .. mac)
end

function bluez:connect(mac)
    os.execute('bluetoothctl -t 4 connect ' .. mac .. ' &')
    logger.info("Connecting to Bluetooth device: " .. mac)
end

function bluez:disconnect(mac)
    os.execute('bluetoothctl -t 4 disconnect ' .. mac .. ' &')
    logger.info("Disconnecting from Bluetooth device: " .. mac)
end

function bluez:knownDevices()
    local handle = io.popen("bluetoothctl devices")
    local output = handle:read("*a")
    handle:close()

    local devices = {}
    for mac, name in string.gmatch(output, "Device ([^ ]+) (.+)") do
        table.insert(devices, { mac = mac, name = name })
    end

    return devices
end

function bluez:scanBluetoothDevices()
    local handle = io.popen("bluetoothctl -t 4 scan on")
    local output = handle:read("*a")
    handle:close()

    -- Strip ANSI escape/color codes (e.g. ESC[0;92m ... ESC[0m)
    output = output:gsub("\27%[[%d;]*m", "")

    local devices = {}
    for line in string.gmatch(output, "[^\r\n]+") do
        local mac, rest = string.match(line, "%[NEW%] Device (%x%x:%x%x:%x%x:%x%x:%x%x:%x%x)%s+(.*)")
        if mac then
            rest = rest and rest:gsub("^%s+", ""):gsub("%s+$", "") or ""
            local dashMac = mac:gsub(":", "-")
            local name = (rest == "" or rest:upper() == dashMac:upper()) and "Unknown" or rest
            table.insert(devices, { mac = mac, name = name })
        end
    end
    return devices
end

function bluez:search() --menu_items
    -- PocketBook-specific Bluetooth search logic
    logger.info("Searching for Bluetooth devices...")
    local devices = self:scanBluetoothDevices()
end

return bluez