-- bluetooth/pocketbook.lua
--[[--
---pocketboot has the netagent command, which we will assume is in the path
---"netagent bt" manages the bluetooth connection.
---  commands that work (on my ereader)
---    netagent bt on
---    netagent bt off
--     netagent bt status

--  when bt is off, the state is BT_STATE_OFF,
--  when on, it may be BT_STATE_ON, BT_STATE_READY, etc
--  so just check for OFF
--]]--

local logger = require("logger")
local Bluez = require("bluetooth/controller/bluez")

local pocketbook = {}

function pocketbook:new(ctrl)
    self.__index = self
    return setmetatable({ controller = ctrl }, self)
end

function pocketbook:status()
    logger.info("Checking Bluetooth status..")
    local handle = io.popen('netagent bt status')
    local output = handle:read("*a")
    handle:close()

    if output:find("BT_STATE_OFF") then
        logger.info("Bluetooth is OFF")
        return false
    end
    logger.info("Bluetooth is ON")
    return true
end

function pocketbook:enable()
    logger.info("Enabling Bluetooth...")
    os.execute('netagent bt on &')
end

function pocketbook:disable()
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

function pocketbook:trust(mac)
    Bluez:trust(mac)
end

function pocketbook:untrust(mac)
    Bluez:untrust(mac)
end

function pocketbook:block(mac)
    Bluez:block(mac)
end

function pocketbook:unblock(mac)
    Bluez:unblock(mac)
end

function pocketbook:knownDevices()
    Bluez.controller = self.controller
    return Bluez:knownDevices()
end

function pocketbook:scan()
    return Bluez:scan()
end

function pocketbook:search()
    return Bluez:search()
end

function pocketbook:info(mac)
    return Bluez:info(mac)
end

return pocketbook