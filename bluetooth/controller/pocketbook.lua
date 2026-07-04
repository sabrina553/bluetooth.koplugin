-- bluetooth/pocketbook.lua
--[[--
---pocketboot has the netagent command, which we will assume is in the path
---"netagent bt" manages the bluetooth connection.
---  commands that work (on my ereader)
---    netagent bt on
---    netagent bt off
---    netagent bt status
---
--]]--

local logger = require("logger")
local Bluez = require("bluetooth/controller/bluez")

local pocketbook = {}

function pocketbook:new(ctrl)
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

function pocketbook:isOn()
    logger.info("Checking Bluetooth status isOn..")
    return execOk('netagent bt status | grep BT_STATE_ON')
end

function pocketbook:isOff()
    logger.info("Checking Bluetooth status isOff..")
    return execOk('netagent bt status | grep BT_STATE_OFF')
end

function pocketbook:isReady()
    logger.info("Checking Bluetooth status isReady..")
    return execOk('netagent bt status | grep BT_STATE_READY')
end

function pocketbook:status()
    if self:isOff() then
        return false
    else
        return true
    end
end

function pocketbook:enable() --menu_items
    -- PocketBook-specific Bluetooth connection logic
    logger.info("Enabling Bluetooth...")
    os.execute('netagent bt on &')
end

function pocketbook:disable() --menu_items
    -- PocketBook-specific Bluetooth disconnection logic
    logger.info("Disabling Bluetooth...")
    os.execute('netagent bt off &')
end

function pocketbook:pair(mac)
    Bluez:pair(mac)
end

function pocketbook:unpair(mac)
    Bluez:unpair(mac)
end

function pocketbook:connect(mac)
    Bluez:connect(mac)
end

function pocketbook:disconnect(mac)
    Bluez:disconnect(mac)
end

function pocketbook:knownDevices()
    return Bluez:knownDevices()
end

function pocketbook:scan()
    return Bluez:scan()
end

function pocketbook:search() --menu_items
    logger.info("Searching for Bluetooth devices...")
    return self:scan()
end

function pocketbook:info(mac)
    return Bluez:info(mac)
end

return pocketbook