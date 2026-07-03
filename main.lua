local logger = require("logger")
--local Device = require("device")
local Dispatcher = require("dispatcher") -- luacheck:ignore
local _ = require("gettext")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

local BluetoothMenu = require("bluetooth/ui/menu")
local controller = require("bluetooth/controller/controller")


---@class Bluetooth
---@field ui any This is a ReaderUI
---@field controller any
local Bluetooth = WidgetContainer:extend {
    name = "Bluetooth",
    is_doc_only = false,
    menu = nil,
    controller = nil,
}

function Bluetooth:init()
    self.controller = controller:new()

    self.menu = BluetoothMenu:new({
        ui = self.ui,
        controller = self.controller
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
    self.controller:enable()
end

return Bluetooth