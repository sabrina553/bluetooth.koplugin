local logger = require("logger")
local Device = require("device")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local _ = require("gettext")

local PocketBook = require("bluetooth/controller/pocketbook")
local Bluez = require("bluetooth/controller/bluez")
local BTdevices = require("bluetooth/controller/devices")

---@class controller
---@field type string
---@field is_enabled boolean
---@field is_scanning boolean
---@field is_connected boolean
---@field is_disconnected boolean
---@field KnownDevices Devices[]
---@field backend any
---@return controller
local controller = {}

function controller:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    o:init()
    return o
end

-- Maps a device type name to the backend *instance* that implements it.
-- Using instances (rather than re-deriving the type each call) means we
-- only construct PocketBook/Bluez once and reuse them.
local backends = {
    PocketBook = PocketBook:new(),
    Bluez = Bluez:new(),
}

function controller:init()
    self.type = self:Devicetype()
    self.backend = backends[self.type]
    self.is_enabled = self:status()
    self.knownDevices = self:knownDevices()
    -- self.is_scanning = false
    -- self.is_connected = false
    -- self.is_disconnected = false
end

function controller:Devicetype()
    if Device:isAndroid() then
        return "Android"
    elseif Device:isPocketBook() then
        return "PocketBook"
    elseif Device:isEmulator() or Device:isDesktop() then
        return "Bluez"
    elseif Device:isKindle() then
        return "Kindle"
    elseif Device:isKobo() then
        return "Kobo"
    end
end

function controller:callDeviceFunction(action, variable)
    if self.backend and self.backend[action] then
        return self.backend[action](self.backend, variable)
    else
        UIManager:show(InfoMessage:new { text = _("Unsupported Bluetooth action on this device"), timeout = 2, })
    end
end

--- Look up a previously-known Devices instance by mac address.
---@param mac string
---@return Devices|nil
function controller:getDevice(mac)
    if not self.knownDevices then
        return nil
    end
    for _, dev in ipairs(self.knownDevices) do
        if dev.mac == mac then
            return dev
        end
    end
    return nil
end

function controller:status()
    return self:callDeviceFunction("status")
end

function controller:toggle()
    if self.is_enabled == true then
        self:disable()
    else
        self:enable()
    end
end

function controller:enable()
    self:callDeviceFunction("enable")
    --self.is_enabled = self:status()
    self.is_enabled = true
end

function controller:disable()
    self:callDeviceFunction("disable")
    --self.is_enabled = self:status()
    self.is_enabled = false
end

function controller:enableWhenDisabled()
    if not self.is_enabled then
        self:enable()
    end
end

--- Refreshes and returns the list of known Devices instances.
---@return Devices[]
function controller:knownDevices()
    self.knownDevices = self:callDeviceFunction("knownDevices") or {}
    return self.knownDevices
end

--- Scans for devices and merges any newly-found ones into knownDevices.
---@return Devices[]
function controller:search()
    self:enableWhenDisabled()
    local found = self:callDeviceFunction("search") or {}

    self.knownDevices = self.knownDevices or {}
    for _, dev in ipairs(found) do
        if not self:getDevice(dev.mac) then
            table.insert(self.knownDevices, dev)
        end
    end

    return found
end


-- The connect/disconnect/pair/unpair/remove/info actions below now prefer
-- operating directly on a Devices object (since each Devices instance
-- knows its own backend and can act on itself). The mac-address versions
-- are kept for callers that only have a mac string, and simply look up or
-- construct the Devices object first.

---@param dev Devices|string A Devices instance, or a mac address string
function controller:connect(dev)
    self:enableWhenDisabled()
    if type(dev) == "string" then
        dev = self:getDevice(dev)
    end
    if not dev then
        logger.warn("controller:connect called with unknown device")
        return
    end
    return dev:connect()
end

---@param dev Devices|string
function controller:disconnect(dev)
    self:enableWhenDisabled()
    if type(dev) == "string" then
        dev = self:getDevice(dev)
    end
    if not dev then
        logger.warn("controller:disconnect called with unknown device")
        return
    end
    return dev:disconnect()
end

---@param dev Devices|string
function controller:pair(dev)
    self:enableWhenDisabled()
    if type(dev) == "string" then
        dev = self:getDevice(dev)
    end
    if not dev then
        logger.warn("controller:pair called with unknown device")
        return
    end
    return dev:pair()
end

---@param dev Devices|string
function controller:remove(dev)
    self:enableWhenDisabled()
    if type(dev) == "string" then
        dev = self:getDevice(dev)
    end
    if not dev then
        logger.warn("controller:remove called with unknown device")
        return
    end
    return dev:remove()
end

---@param mac string
function controller:info(mac)
    self:enableWhenDisabled()
    return self:callDeviceFunction("info", mac)
end

return controller