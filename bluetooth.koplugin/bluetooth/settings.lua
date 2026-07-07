local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local logger = require("logger")

---@class BluetoothSettingsData
---@field disable_on_lock boolean
---@field disable_on_suspend boolean
---@field enable_on_wake boolean
---@field starred_on_wake boolean
---@field last_on_wake boolean
---@field update_channel string "stable" | "development"

local UPDATE_CHANNELS = {
    stable = true,
    development = true,
}

local DEFAULTS = {
    disable_on_lock = false,
    disable_on_suspend = false,
    enable_on_wake = false,
    starred_on_wake = false,
    last_on_wake = false,
    update_channel = "stable",
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
        logger:err("Bluetooth Settings: Error reading settings, using defaults", result)
        self.data = shallowCopy(DEFAULTS)
        self:write()
    end
end

function BluetoothSettings:write()
    local success, error_msg = pcall(function()
        if not self.settings then
            logger:err("Bluetooth Settings: No settings object available for write")
            return false
        end

        logger:dbg("Bluetooth: Saving settings data", self.data)
        self.settings:saveSetting(SETTING_KEY, self.data)
        self.settings:flush()
        logger:dbg("Settings saved and flushed successfully")
        return true
    end)

    if not success then
        logger:err("error writing settings:", error_msg)
        return false
    end

    return true
end

function BluetoothSettings:getDisableOnLock()
    return self.data.disable_on_lock or DEFAULTS.disable_on_lock
end

function BluetoothSettings:setDisableOnLock(disable_on_lock)
    self.data.disable_on_lock = disable_on_lock
    self:write()
end

function BluetoothSettings:toggleDisableOnLock()
    self.data.disable_on_lock = not self:getDisableOnLock()
    self:write()
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

function BluetoothSettings:getEnableOnWake()
    return self.data.enable_on_wake or DEFAULTS.enable_on_wake
end

function BluetoothSettings:setEnableOnWake(enable_on_wake)
    self.data.enable_on_wake = enable_on_wake
    self:write()
end

function BluetoothSettings:toggleEnableOnWake()
    self.data.enable_on_wake = not self:getEnableOnWake()
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

function BluetoothSettings:getUpdateChannel()
    local channel = self.data.update_channel or DEFAULTS.update_channel
    if not UPDATE_CHANNELS[channel] then
        -- Guards against a corrupted/unknown value ending up on disk; falls
        -- back to stable rather than passing a bogus channel down into the
        -- updater/GitHub API.
        return DEFAULTS.update_channel
    end
    return channel
end

---@param channel string "stable" | "development"
function BluetoothSettings:setUpdateChannel(channel)
    if not UPDATE_CHANNELS[channel] then
        logger:warn("Bluetooth Settings: ignoring unknown update channel", tostring(channel))
        return
    end
    self.data.update_channel = channel
    self:write()
end

return BluetoothSettings