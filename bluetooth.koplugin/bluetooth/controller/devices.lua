local logger = require("logger")
local UIManager = require("ui/uimanager")

---@class Devices
---@field mac string
---@field name string
---@field paired boolean
---@field bonded boolean
---@field trusted boolean
---@field blocked boolean
---@field connected boolean
---@field controller any
---@field backend any The platform backend (Bluez, PocketBook, ...) used to actually talk to hardware
local Devices = {}
Devices.__index = Devices

--- Create a new device.
--- o.backend should be the platform controller (e.g. Bluez) that knows how
--- to actually pair/connect/etc. This lets a Devices instance perform its
--- own actions without the caller needing to know which platform it's on.
function Devices:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    o:init()
    return o
end

function Devices:init()
    self.mac = self.mac or ""
    self.name = self.name or ""
    self.paired = self.paired or false
    self.bonded = self.bonded or false
    self.trusted = self.trusted or false
    self.blocked = self.blocked or false
    self.connected = self.connected or false
    self.backend = self.backend
    logger:dbg("Bluetooth.koplugin.Devices Initialized")
end

--@field controller any
function Devices:fromScan(mac, name, backend, ctrl)
    return Devices:new({ mac = mac, name = name, backend = backend, controller = ctrl })
end

function Devices:parseInfo(output)
    self.mac = output:match("Device (%w+:%w+:%w+:%w+:%w+:%w+)") or self.mac

    self.name = output:match("^(Name: |Alias: )(.*)\n") or self.name

    local paired = output:match("Paired: (%w+)")
    self.paired = paired and (paired == "yes") or false

    local bonded = output:match("Bonded: (%w+)")
    self.bonded = bonded and (bonded == "yes") or false

    local trusted = output:match("Trusted: (%w+)")
    self.trusted = trusted and (trusted == "yes") or false

    local blocked = output:match("Blocked: (%w+)")
    self.blocked = blocked and (blocked == "yes") or false

    local connected = output:match("Connected: (%w+)")
    self.connected = connected and (connected == "yes") or false
    return self
end

function Devices:refresh()
    if not self.backend or not self.backend.info then
        logger.warn("Devices:refresh called with no backend set on device " .. tostring(self.mac))
        return self
    end

    local output = self.backend:info(self.mac)
    if output then
        self:parseInfo(output)
    end

    return self
end

--- Polls `refresh()` on a timer until self.field == expected, or gives up.
---@param expected boolean
---@param callback fun(confirmed: boolean)|nil called once, with true if state was confirmed
---@param attempt integer|nil internal, do not pass
local function pollField(self, field, expected, callback, attempt)
    attempt = attempt or 1
    local max_attempts = 10
    local delay_s = 0.5

    self:refresh()

    if self[field] == expected then
        if callback then callback(true) end
        return
    end

    if attempt >= max_attempts then
        logger.warn("Devices: could not confirm connection state for " .. tostring(self.mac))
        if callback then callback(false) end
        return
    end

    UIManager:scheduleIn(delay_s, function()
        pollField(self, field, expected, callback, attempt + 1)
    end)
end

function Devices:connect(callback)
    if not self.backend then
        logger.warn("Devices:connect called with no backend set on device " .. tostring(self.mac))
        if callback then callback(false) end
        return
    end

    if not self.controller then
        logger.warn("Devices:connect called with no controller set on device " .. tostring(self.mac))
        if callback then callback(false) end
        return
    end

    self.controller:enableWhenDisabled(function(enabled_confirmed)
        if not enabled_confirmed then
            if callback then callback(false) end
            return
        end

        self.backend:connect(self.mac)
        pollField(self, "connected", true, callback)
    end)
end

function Devices:disconnect(callback)
    if not self.backend then
        logger.warn("Devices:disconnect called with no backend set on device " .. tostring(self.mac))
        if callback then callback(false) end
        return
    end
    if not self.connected then
        if callback then callback(true) end
        return
    end

    self.backend:disconnect(self.mac)
    pollField(self, "connected", false, callback)
end

function Devices:toggleConnection(callback)
    if self.connected then
        return self:disconnect(callback)
    else
        return self:connect(callback)
    end
end

function Devices:pair(callback)
    if not self.backend then
        logger.warn("Devices:pair called with no backend set on device " .. tostring(self.mac))
        if callback then callback(false) end
        return
    end
    if self.paired then
        if callback then callback(false) end
        return
    end
    if not self.controller then
        logger.warn("Devices:pair called with no controller set on device " .. tostring(self.mac))
        if callback then callback(false) end
        return
    end

    self.controller:enableWhenDisabled(function(enabled_confirmed)
        if not enabled_confirmed then
            if callback then callback(false) end
            return
        end
        self.backend:pair(self.mac)
        pollField(self, "paired", true, function(paired_confirmed)
            if not paired_confirmed then
                if callback then callback(false) end
                return
            end
            self:connect(function(connected_confirmed)
                if not connected_confirmed then
                    if callback then callback(false) end
                    return
                end
                self:trust(callback)
            end)
        end)
    end)
end

function Devices:unpair(callback)
    if not self.backend then
        logger.warn("Devices:unpair called with no backend set on device " .. tostring(self.mac))
        if callback then callback(false) end
        return
    end

    if not self.paired then
        if callback then callback(false) end
        return
    end

    self.backend:unpair(self.mac)
    pollField(self, "paired", false, callback)
end

function Devices:togglePair(callback)
    if self.paired then
        return self:unpair(callback)
    else
        return self:pair(callback)
    end
end

function Devices:trust(callback)
    if not self.backend then
        logger.warn("Devices:trust called with no backend set on device " .. tostring(self.mac))
        if callback then callback(false) end
        return
    end
    if self.trusted then
        if callback then callback(true) end
        return
    end

    self.backend:trust(self.mac)
    pollField(self, "trusted", true, callback)
end

function Devices:untrust(callback)
    if not self.backend then
        logger.warn("Devices:unpair called with no backend set on device " .. tostring(self.mac))
        if callback then callback(false) end
        return
    end

    if not self.trusted then
        if callback then callback(false) end
        return
    end

    self.backend:untrust(self.mac)
    pollField(self, "trusted", false, callback)
end

function Devices:toggleTrust(callback)
    if self.trusted then
        return self:untrust(callback)
    else
        return self:trust(callback)
    end
end

function Devices:block(callback)
    if not self.backend then
        logger.warn("Devices:block called with no backend set on device " .. tostring(self.mac))
        if callback then callback(false) end
        return
    end
    if self.blocked then
        if callback then callback(true) end
        return
    end

    self.backend:block(self.mac)
    pollField(self, "blocked", true, callback)
end

function Devices:unblock(callback)
    if not self.backend then
        logger.warn("Devices:unblock called with no backend set on device " .. tostring(self.mac))
        if callback then callback(false) end
        return
    end
    if not self.blocked then
        if callback then callback(false) end
        return
    end

    self.backend:unblock(self.mac)
    pollField(self, "blocked", false, callback)
end

function Devices:toggleBlock(callback)
    if self.blocked then
        return self:unblock(callback)
    else
        return self:block(callback)
    end
end

return Devices