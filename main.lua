local logger = require("logger")
--local Device = require("device")
local Dispatcher = require("dispatcher") -- luacheck:ignore
local _ = require("gettext")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

local BluetoothMenu = require("bluetooth/ui/menu")
local controller = require("bluetooth/controller/controller")
local devices = require("bluetooth/controller/devices")

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
    --self.devices = devices:new({})
    self.controller = controller:new({
        devices = self.devices
    })
    self.menu = BluetoothMenu:new({
        ui = self.ui,
        controller = self.controller,
        devices = self.devices,
    })

    self.ui.menu:registerToMainMenu(self.menu)

    logger:dbg("Bluetooth.koplugin Initialized")
end

function Bluetooth:onExit()
    logger.info("Device exiting, disabling bluetooth")
    self.controller:disable()
end

function Bluetooth:onSuspend()
    logger.info("Device suspending, disabling bluetooth")
    self.controller:disable()
end

function Bluetooth:onPause()
    logger.info("Device pasung, disabling bluetooth")
    self.controller:disable()
end

function Bluetooth:onResume()
    logger.info("Device resumed, Restoring Bluetooth")
    self.controller:enableWhenDisabled()
end

return Bluetooth