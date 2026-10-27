local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local logger = require("logger")
local Version = require("bluetooth/ota/version")
local BackendSelect = require("bluetooth/controller/backend_select")

---@class BluetoothSettingsData
---@field disable_on_suspend boolean
---@field starred_on_wake boolean
---@field last_on_wake boolean
---@field radio_was_on boolean
---@field update_channel string "stable" | "beta" | "development"
---@field backend_mode string "auto" | "fast" | "compatible"
---@field live_updates boolean

local DEFAULTS = {
    disable_on_suspend = false,
    starred_on_wake = false,
    last_on_wake = false,
    radio_was_on = false,
    update_channel = "stable",
    backend_mode = "auto",
    live_updates = false,
}

local function shallowCopy(t)
    local copy = {}
    for k, v in pairs(t) do copy[k] = v end
    return copy
end

---@class BluetoothSettings
---@field settings any
---@field data BluetoothSettingsData
local BluetoothSettings = {
    data = DEFAULTS,
}

local SETTING_KEY = "bluetooth"

local function openSettingsHandle()
    local path = DataStorage:getSettingsDir() .. "/" .. SETTING_KEY .. ".lua"
    return LuaSettings:open(path)
end

function BluetoothSettings:new()
    local o = {}
    setmetatable(o, self)
    self.__index = self
    o:init()
    return o
end

function BluetoothSettings:init()
    self.settings = openSettingsHandle()
    local success, result = pcall(function()
        return self.settings:readSetting(SETTING_KEY, {}) or {}
    end)

    if success then
        self.data = result
    else
        logger.err("Bluetooth Settings: Error reading settings, using defaults", result)
        self.data = shallowCopy(DEFAULTS)
        self:write()
    end
end

function BluetoothSettings:write()
    local success, error_msg = pcall(function()
        if not self.settings then
            logger.err("Bluetooth Settings: No settings object available for write")
            return false
        end

        logger.dbg("Bluetooth: Saving settings data", self.data)
        self.settings:saveSetting(SETTING_KEY, self.data)
        self.settings:flush()
        logger.dbg("Settings saved and flushed successfully")
        return true
    end)

    if not success then
        logger.err("error writing settings:", error_msg)
        return false
    end

    return true
end

function BluetoothSettings:getDisableOnSuspend()
    return self.data.disable_on_suspend or DEFAULTS.disable_on_suspend
end

function BluetoothSettings:setDisableOnSuspend(disable_on_suspend)
    self.data.disable_on_suspend = disable_on_suspend
    self:write()
end

function BluetoothSettings:toggleDisableOnSuspend()
    self.data.disable_on_suspend = not self:getDisableOnSuspend()
    self:write()
end

function BluetoothSettings:getStarredOnWake()
    return self.data.starred_on_wake or DEFAULTS.starred_on_wake
end

function BluetoothSettings:setStarredOnWake(starred_on_wake)
    self.data.starred_on_wake = starred_on_wake
    self:write()
end

function BluetoothSettings:toggleStarredOnWake()
    self.data.starred_on_wake = not self:getStarredOnWake()
    self:write()
end

function BluetoothSettings:getLastOnWake()
    return self.data.last_on_wake or DEFAULTS.last_on_wake
end

function BluetoothSettings:setLastOnWake(last_on_wake)
    self.data.last_on_wake = last_on_wake
    self:write()
end

function BluetoothSettings:toggleLastOnWake()
    self.data.last_on_wake = not self:getLastOnWake()
    self:write()
end

--- Last radio state the user chose (menu) or had at suspend, restored at a
--- cold start. Decision: 2026-10-26 session note (boot behaves like wake).
function BluetoothSettings:getRadioWasOn()
    return self.data.radio_was_on or DEFAULTS.radio_was_on
end

function BluetoothSettings:setRadioWasOn(radio_was_on)
    if self.data.radio_was_on == radio_was_on then return end
    self.data.radio_was_on = radio_was_on
    self:write()
end

--- Live updates while the menu is open (Fast mode only). Experimental and
--- off by default for the stable release (decision 2026-10-26).
function BluetoothSettings:getLiveUpdates()
    return self.data.live_updates or DEFAULTS.live_updates
end

function BluetoothSettings:toggleLiveUpdates()
    self.data.live_updates = not self:getLiveUpdates()
    self:write()
end

function BluetoothSettings:getUpdateChannel()
    local channel = self.data.update_channel or DEFAULTS.update_channel
    if not Version.isChannel(channel) then
        -- Guards against a corrupted/unknown value ending up on disk; falls
        -- back to stable rather than passing a bogus channel down into the
        -- updater/GitHub API.
        return DEFAULTS.update_channel
    end
    return channel
end

---@param channel string "stable" | "beta" | "development"
function BluetoothSettings:setUpdateChannel(channel)
    if not Version.isChannel(channel) then
        logger.warn("Bluetooth Settings: ignoring unknown update channel", tostring(channel))
        return
    end
    self.data.update_channel = channel
    self:write()
end

function BluetoothSettings:getBackendMode()
    local mode = self.data.backend_mode
    return BackendSelect.MODES[mode] and mode or DEFAULTS.backend_mode
end

---@param mode string "auto" | "fast" | "compatible"
function BluetoothSettings:setBackendMode(mode)
    if not BackendSelect.MODES[mode] then
        logger.warn("Bluetooth Settings: ignoring unknown backend mode", tostring(mode))
        return
    end
    self.data.backend_mode = mode
    self:write()
end

return BluetoothSettings