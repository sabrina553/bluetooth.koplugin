local logger = require("logger")
local _ = require("gettext")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

local BluetoothMenu = require("bluetooth/ui/menu")
local controller = require("bluetooth/controller/controller")
local BluetoothSettings = require("bluetooth/settings")
local BluetoothDeviceStore = require("bluetooth/devicestore")
local GithubAPI = require("bluetooth/ota/github_api")
local BluetoothSelfUpdater = require("bluetooth/ota/self_updater")


---@class Bluetooth
---@field ui any This is a ReaderUI
---@field controller any
---@field devices any
local Bluetooth = WidgetContainer:extend {
    name = "Bluetooth",
    is_doc_only = false,
    menu = nil,
    controller = nil,
    devices = nil,
}

function Bluetooth:init()
    self.settings = BluetoothSettings:new()
    self.device_store = BluetoothDeviceStore:new()

    self.updater = BluetoothSelfUpdater:new({
        github_api = GithubAPI:new(),
        settings = self.settings,
    })

    self.controller = controller:new({
        devices = self.devices,
        settings = self.settings,
        device_store = self.device_store,
    })

    self.menu = BluetoothMenu:new({
        ui = self.ui,
        settings = self.settings,
        controller = self.controller,
        devices = self.devices,
        updater = self.updater,
    })

    self.ui.menu:registerToMainMenu(self.menu)

    self:restoreBluetoothState()

    logger:dbg("Bluetooth.koplugin: Initialized")
end

function Bluetooth:restoreBluetoothState()
    local function afterEnabled(enabled_confirmed)
        if not enabled_confirmed then
            logger.warn("Bluetooth.koplugin: could not confirm bluetooth enabled, skipping reconnect")
            return
        end
        self.controller:knownDevices(function()
            self.controller:reconnectOnWake() -- Have this disconnect the controller on failures :) 
        end)
    end

    if self.settings:getEnableOnWake() then
        self.controller:enableWhenDisabled(afterEnabled)
    else
        self.controller:status()
        if self.controller.is_enabled then
            afterEnabled(true)
        end
    end
end

function Bluetooth:onResume()
    logger.dbg("Bluetooth.koplugin: Device resumed, Restoring Bluetooth")
    self:restoreBluetoothState()
end

function Bluetooth:onSuspend()
    logger.dbg("Bluetooth.koplugin: Device suspending, disabling bluetooth")
    self.controller:snapshotBeforeSuspend(function()
        if self.settings:getDisableOnSuspend() then
            self.controller:disable()
        end
    end)
end

function Bluetooth:onPause()
    logger.dbg("Bluetooth.koplugin: Device pausing, disabling bluetooth")
    self.controller:snapshotBeforeSuspend(function()
        if self.settings:getDisableOnLock() then
            self.controller:disable()
        end
    end)
end

return Bluetooth