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
local Parse = require("bluetooth/controller/bluetoothctl_parse")

-- Power is always netagent's; everything else goes to the transport, Bluez
-- (Compatible) or BluezDbus (Fast), chosen by controller:applyMode().
local pocketbook = { transport = Bluez }

function pocketbook:new(ctrl)
    self.__index = self
    return setmetatable({ controller = ctrl }, self)
end

function pocketbook:status()
    logger.dbg("Pocketbook-Netagent: Checking Bluetooth status..")
    local handle = io.popen(Bluez.timeoutPrefix(5) .. 'netagent bt status 2>/dev/null')
    local output = handle:read("*a")
    handle:close()
    -- Empty output (timed out) falls through to "ON" below, as before; the
    -- poll that follows corrects it.

    if output:find("BT_STATE_OFF") then
        logger.dbg("Pocketbook-Netagent: Bluetooth is OFF")
        return false
    end
    logger.dbg("Pocketbook-Netagent: Bluetooth is ON")
    return true
end

---@param done fun(enabled: boolean|nil)
function pocketbook:readStatus(done)
    Bluez.runAsync(Bluez.timeoutPrefix(5) .. "netagent bt status 2>/dev/null\n", function(output)
        if not output or output:match("^%s*$") then
            return done(nil)
        end
        done(output:find("BT_STATE_OFF") == nil)
    end)
end

function pocketbook:enable()
    logger.dbg("Pocketbook-Netagent: Enabling Bluetooth...")
    os.execute('netagent bt on >/dev/null 2>&1 &')
end

function pocketbook:disable()
    logger.dbg("Pocketbook-Netagent: Disabling Bluetooth...")
    os.execute('netagent bt off >/dev/null 2>&1 &')
end

function pocketbook:setTransport(transport)
    self.transport = transport
end

function pocketbook:pair(mac, on_done)
    return self.transport:pair(mac, on_done)
end

function pocketbook:unpair(mac)
    self.transport:unpair(mac)
end

function pocketbook:connect(mac)
    self.transport:connect(mac)
end

function pocketbook:disconnect(mac)
    self.transport:disconnect(mac)
end

function pocketbook:trust(mac)
    self.transport:trust(mac)
end

function pocketbook:untrust(mac)
    self.transport:untrust(mac)
end

function pocketbook:block(mac)
    self.transport:block(mac)
end

function pocketbook:unblock(mac)
    self.transport:unblock(mac)
end

function pocketbook:knownDevices()
    self.transport.controller = self.controller
    return self.transport:knownDevices()
end

function pocketbook:readSnapshot(done)
    self.transport.controller = self.controller
    return self.transport:readSnapshot(done)
end

function pocketbook:search(duration)
    return self.transport:search(duration)
end

function pocketbook:info(mac)
    return self.transport:info(mac)
end

--- Typed device state for Devices:refresh. Cached devices carry this
--- backend rather than the transport, so it forwards either way.
function pocketbook:readInfo(mac)
    if self.transport.readInfo then
        return self.transport:readInfo(mac)
    end
    local output = self.transport:info(mac)
    return output and Parse.info(output)
end

return pocketbook