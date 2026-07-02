-- bluetooth/pocketbook.lua
--[[--
---pocketboot has the netagent command, which we will assume is in the path
---"netagent bt" manages the bluetooth connection.
---  commands that work (on my ereader)
---    netagent bt on
---    netagent bt off
---    netagent bt status
---"netagent net" manages the wifi connection
---  commands that work
---    netagent net on
---    netagent net off
---
--- Underneath this it uses bluez stack - bluetoothctl et al
--- Commands:
	list		            List available controllers
	show		            Controller information
	select		            Select default controller
x	devices		            List available devices, with an optional property as the filter
	system-alias	        Set controller alias
	reset-alias	            Reset controller alias
	power		            Set controller power
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

local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local _ = require("gettext")
local logger = require("logger")
local uimanager = require("ui.uimanager")

local pocketbook = {}

function pocketbook:new()
    local pocketbook = setmetatable({}, pocketbook)
    return pocketbook
end

    -- netagent bt status
    --  when bt is off, the state is BT_STATE_OFF,
    --  when on, it may be BT_STATE_ON, BT_STATE_READY, etc
    --  so just check for OFF
function pocketbook:isOn()
    logger.info("Checking Bluetooth status isOn..")
    return os.execute('netagent bt status | grep BT_STATE_ON') == 0
end

function pocketbook:isOff()
    logger.info("Checking Bluetooth status isOff..")
    return os.execute('netagent bt status | grep BT_STATE_OFF') == 0
end

function pocketbook:isReady()
    logger.info("Checking Bluetooth status isOff..")
    return os.execute('netagent bt status | grep BT_STATE_READY') == 0
end

function pocketbook:toggle() --menu_items
    -- PocketBook-specific Bluetooth toggle logic
    
    logger.info("Toggling Bluetooth connection...")
    local msg = ""
    if pocketbook:isOff() then
        os.execute('netagent bt on &')
        msg = 'Enabling Bluetooth'
    else
        -- isoff is not zero, which means we're in one of the "on" states disable
        os.execute('netagent bt off &')
        msg = 'Disabling Bluetooth'
    end
    UIManager:show(InfoMessage:new { text = _(msg), timeout = 2, })
end

function pocketbook:enable() --menu_items
    -- PocketBook-specific Bluetooth connection logic
    if pocketbook:isOff() then
        logger.info("Enabling Bluetooth...")
        os.execute('netagent bt on &')
    end
end

function pocketbook:disable() --menu_items
    -- PocketBook-specific Bluetooth disconnection logic
    if pocketbook:isOn() then
        logger.info("Disabling Bluetooth...")
        os.execute('netagent bt off &')
    end
end

function pocketbook:pair(mac)
    os.execute('bluetoothctl -t 4 pair ' .. mac .. ' &')
    logger.info("Pairing with Bluetooth device: " .. mac)
end

function pocketbook:unpair(mac)
    os.execute('bluetoothctl -t 4 remove ' .. mac .. ' &')
    logger.info("Unpairing with Bluetooth device: " .. mac)
end

function pocketbook:connect(mac)
    os.execute('bluetoothctl -t 4 connect ' .. mac .. ' &')
    logger.info("Connecting to Bluetooth device: " .. mac)
end

function pocketbook:disconnect(mac)
    os.execute('bluetoothctl -t 4 disconnect ' .. mac .. ' &')
    logger.info("Disconnecting from Bluetooth device: " .. mac)
end

function pocketbook:knownDevices()
    local output = io.popen("bluetoothctl devices"):read("*a")

    local devices = {}
    for mac, name in string.gmatch(output, "Device ([^ ]+) (.+)") do
        table.insert(devices, { mac = mac, name = name })
    end

    return devices
end

function pocketbook:scanBluetoothDevices()
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

function pocketbook:search() --menu_items
    -- PocketBook-specific Bluetooth search logic
    logger.info("Searching for Bluetooth devices...")
    UIManager:show(InfoMessage:new { text = _("Searching for Bluetooth devices"), timeout = 5, })
    local devices = pocketbook:scanBluetoothDevices()

end

return pocketbook