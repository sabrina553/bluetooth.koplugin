local logger = require("logger")
local _ = require("gettext")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Device = require("device")

local BackendSelect = require("bluetooth/controller/backend_select")

-- No backend for this device (Kobo, Kindle, Android): don't load at all.
-- KOReader skips a plugin whose main.lua returns { disabled = true }
-- (frontend/pluginloader.lua), so there are no menu entries or popups.
if not BackendSelect.select(Device) then
    logger.info("Bluetooth.koplugin: no backend for this device, not loading")
    return { disabled = true }
end

local BluetoothMenu = require("bluetooth/ui/menu")
local controller = require("bluetooth/controller/controller")
local BluetoothSettings = require("bluetooth/settings")
local Session = require("bluetooth/session")
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

    -- init also runs on every view change (file manager <-> book), where
    -- nothing woke up: restoring then switched Bluetooth back on after the
    -- user had turned it off. Wake-ups are handled by onResume.
    if Session.isColdStart() then
        self:restoreBluetoothState(false)
    end

    logger.dbg("Bluetooth.koplugin: Initialized")
end

--- Reconnects devices after a start or wake-up. The radio is only switched
--- on again (`allow_enable`) to undo our own disable-on-suspend; it is never
--- turned on just because the reader started or woke.
--- Decision: 2026-10-13 session note (auto-connect, never auto-enable).
---@param allow_enable boolean
function Bluetooth:restoreBluetoothState(allow_enable)
    local function reconnect()
        self.controller:knownDevices(function()
            self.controller:reconnectOnWake()
        end)
    end

    self.controller:status()
    if self.controller.is_enabled then
        return reconnect()
    end

    if not allow_enable then
        logger.dbg("Bluetooth.koplugin: Bluetooth is off, leaving it off")
        return
    end

    self.controller:enableWhenDisabled(function(enabled_confirmed)
        if not enabled_confirmed then
            logger.warn("Bluetooth.koplugin: could not confirm bluetooth enabled, skipping reconnect")
            return
        end
        reconnect()
    end)
end

function Bluetooth:onResume()
    logger.dbg("Bluetooth.koplugin: Device resumed, Restoring Bluetooth")
    -- Only restore a radio that was on before the suspend; one the user had
    -- turned off stays off.
    local was_enabled = self.controller.was_enabled_before_suspend
    self.controller.was_enabled_before_suspend = nil
    self:restoreBluetoothState(was_enabled == true)
end

function Bluetooth:onSuspend()
    logger.dbg("Bluetooth.koplugin: Device suspending, disabling bluetooth")
    self.controller:snapshotBeforeSuspend(function()
        if self.settings:getDisableOnSuspend() then
            self.controller:disable()
        end
    end)
end

return Bluetooth