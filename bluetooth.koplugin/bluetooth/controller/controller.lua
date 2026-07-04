local logger = require("logger")
local Device = require("device")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local _ = require("gettext")

local PocketBook = require("bluetooth/controller/pocketbook")
local Bluez = require("bluetooth/controller/bluez")

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
    self:Devicetype()

    if not backends then
        backends = {
            PocketBook = PocketBook:new(self),
            Bluez = Bluez:new(self),
        }
    end
    self.backend = backends[self.type]

    self:status()
    self:knownDevices()
    -- self.is_scanning = false
    -- self.is_connected = false
    -- self.is_disconnected = false
    logger:dbg("Bluetooth.koplugin.Controller Initialized")
end

function controller:Devicetype()
    if Device:isAndroid() then
        self.type = "Android"
    elseif Device:isPocketBook() then
        self.type = "PocketBook"
    elseif Device:isEmulator() or Device:isDesktop() then
        self.type = "Bluez"
    elseif Device:isKindle() then
        self.type = "Kindle"
    elseif Device:isKobo() then
        self.type = "Kobo"
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
    if not self.known_devices then
        return nil
    end
    for _, dev in ipairs(self.known_devices) do
        if dev.mac == mac then
            return dev
        end
    end
    return nil
end


---@param expected boolean 
---@param callback fun(confirmed: boolean)|nil 
---@param attempt integer|nil internal, do not pass
local function pollField(self, field, expected, callback, attempt)
    attempt = attempt or 1
    local max_attempts = 10
    local delay_s = 0.5

    self:status()

    if self[field] == expected then
        if callback then callback(true) end
        return
    end

    if attempt >= max_attempts then
        logger.warn("Controller could not confirm connection state")
        if callback then callback(false) end
        return
    end
    UIManager:scheduleIn(delay_s, function()
        pollField(self, field, expected, callback, attempt + 1)
    end)
end


function controller:status()
    logger.info("Checking Bluetooth status")
    self.is_enabled = self:callDeviceFunction("status")
end

function controller:enable(callback)
    self:callDeviceFunction("enable")
    pollField(self, "is_enabled", true, callback)
end

function controller:disable(callback)
    self:callDeviceFunction("disable")
    pollField(self, "is_enabled", false, callback)
end

function controller:toggle(callback)
    self:status()
    if self.is_enabled then
        return self:disable(callback)
    else
        return self:enable(callback)
    end
end

function controller:enableWhenDisabled(callback)
    self:status()
    if not self.is_enabled then
        self:enable(callback)
    else
        callback(true)
    end
end

--- Refreshes and returns the list of known Devices instances. @return Devices[]
---
function controller:knownDevices(callback)
    logger.info("Refreshing known devices")

    if self.backend == backends.PocketBook then -- and something so this only runs on init?
        self:enableWhenDisabled(callback)
    end

    self.known_devices = self:callDeviceFunction("knownDevices") or {}
    logger.info(#self.known_devices)
    for _, dev in ipairs(self.known_devices) do
        dev:refresh()
    end
    return self.known_devices
end

--- Scans for devices and merges any newly-found ones into knownDevices. @return Devices[]
---
function controller:search(callback, duration)
    self:enableWhenDisabled(callback)
    self:callDeviceFunction("search", duration)
end

---@param mac string
function controller:info(mac)
    return self:callDeviceFunction("info", mac)
end

return controller