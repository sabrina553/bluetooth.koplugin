local logger = require("logger")
local _ = require("gettext")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

local BluetoothMenu = require("bluetooth/ui/menu")
local controller = require("bluetooth/controller/controller")
local BluetoothSettings = require("bluetooth/settings")


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

    self.controller = controller:new({
        devices = self.devices,
        settings = self.settings
    })

    self.menu = BluetoothMenu:new({
        ui = self.ui,
        settings = self.settings,
        controller = self.controller,
        devices = self.devices,
    })

    self.ui.menu:registerToMainMenu(self.menu)

    logger:dbg("Bluetooth.koplugin: Initialized")
end

function Bluetooth:onExit()
    logger.dbg("Bluetooth.koplugin: Device exiting, disabling bluetooth")
    self.controller:disable()
end

function Bluetooth:onSuspend()
    logger.dbg("Bluetooth.koplugin: Device suspending, disabling bluetooth")
    self.controller:disable()
end

function Bluetooth:onPause()
    logger.dbg("Bluetooth.koplugin: Device pausing, disabling bluetooth")
    self.controller:disable()
end

function Bluetooth:onResume()
    logger.dbg("Bluetooth.koplugin: Device resumed, Restoring Bluetooth")
    self.controller:enableWhenDisabled()
end

return Bluetooth