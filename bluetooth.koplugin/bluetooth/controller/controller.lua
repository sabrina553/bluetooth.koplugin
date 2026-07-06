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
-- only construct PocketBook/Bluez once and reuse them across the app.
-- NOTE: these are shared singletons, so we (re)assign `.controller` on
-- whichever one gets selected in init(), rather than passing it in here.
local backends = {
    PocketBook = PocketBook:new(),
    Bluez = Bluez:new(),
}

function controller:init()
    self:Devicetype()

    self.backend = backends[self.type]
    if self.backend then
        -- Give the backend a way to call back into this controller (and,
        -- via the backend, so can any Devices instance it constructs).
        self.backend.controller = self
    end

    self:status()
    self:knownDevices()

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
    logger.dbg("Looking up known device by MAC: " .. mac)
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
    logger.dbg ("Polling field: " .. field .. " for value: " .. tostring(expected))

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
    logger.dbg("Checking Bluetooth status")
    self.is_enabled = self:callDeviceFunction("status")
end

function controller:enable(callback)
    logger.dbg("Enabling Bluetooth Controller")
    self:callDeviceFunction("enable")
    pollField(self, "is_enabled", true, callback)
end

function controller:disable(callback)
    logger.dbg("Disabling Bluetooth Controller")
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
    elseif callback then
        callback(true)
    end
end

function controller:knownDevices(callback)
    logger.dbg("Refreshing known devices")

    local function refresh()
        self.known_devices = self:callDeviceFunction("knownDevices") or {}

        for _, dev in ipairs(self.known_devices) do
            dev:refresh()
        end

        if callback then callback(true) end
        return self.known_devices
    end

    if self.backend == backends.PocketBook then
        self:enableWhenDisabled(function(enabled_confirmed) -- this might need adjusting, such that it only enables on init, and not each time the function is called.
            if not enabled_confirmed then
                if callback then callback(false) end
                return
            end
            refresh()
        end)

        return self.known_devices
    end

    return refresh()
end

function controller:search(callback, duration)
    logger.dbg("Starting Bluetooth scan for " .. tostring(duration) .. " seconds")
    self:enableWhenDisabled(function(enabled_confirmed)
        if not enabled_confirmed then
            if callback then callback(false) end
            return
        end
        self:callDeviceFunction("search", duration)
        if callback then callback(true) end
    end)
end

---@param mac string
function controller:info(mac)
    logger.dbg("Fetching info for device with MAC: " .. tostring(mac))
    return self:callDeviceFunction("info", mac)
end

return controller