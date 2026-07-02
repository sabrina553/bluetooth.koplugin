local Dispatcher = require("dispatcher") -- luacheck:ignore
local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")

local PocketBook = require("bluetooth/pocketbook")
local Bluez = require("bluetooth/bluez")

local Bluetooth = WidgetContainer:extend {
    name = "Bluetooth",
    is_doc_only = false,
}

-- Define a table that maps device types to their corresponding functions
local device_functions = {
    PocketBook = {
        status = function () PocketBook:status() end,
        toggle = function() PocketBook:toggle() end,
        enable = function() PocketBook:enable() end,
        disable = function() PocketBook:disable() end,
        search = function() PocketBook:search() end,
    },
    Bluez = {
        status = function () Bluez:status() end,
        toggle = function() Bluez:toggle() end,
        enable = function() Bluez:enable() end,
        disable = function() Bluez:disable() end,
        search = function() Bluez:search() end,
    }
    -- Kobo = {
    --     status = function () Kobo:status() end,
    --     toggle = function() Kobo:toggle() end,
    --     enable = function() Kobo:enable() end,
    --     disable = function() Kobo:disable() end,
    -- },
    -- Kindle = {
    --     status = function () kindle:status() end,
    --     toggle = function() Kindle:toggle() end,
    --     enable = function() Kindle:enable() end,
    --     disable = function() Kindle:disable() end,
    -- },
}

function Bluetooth:Deviceis()
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

function Bluetooth:onStatus()
    self:callDeviceFunction("status")
end

function Bluetooth:onToggle(menu_items)
    self:callDeviceFunction("toggle")
end

function Bluetooth:onEnable(menu_items)
    self:callDeviceFunction("enable")
end

function Bluetooth:onDisable(menu_items)
    self:callDeviceFunction("disable")
end

function Bluetooth:search(menu_items)
    self:callDeviceFunction("search")
end

function Bluetooth:callDeviceFunction(action)
    local device_type = self:Deviceis()
    local func = device_functions[device_type]

    if not func then
        UIManager:show(InfoMessage:new { text = _("Bluetooth not supported on this device"), timeout = 2, })
        return
    end

    if func[action] then
        func[action]()
    else
        UIManager:show(InfoMessage:new { text = _("Unsupported Bluetooth action on this device"), timeout = 2, })
    end
end

function Bluetooth:addToMainMenu(menu_items)
    menu_items.pbbt = {
        text = _("Bluetooth"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Enable Bluetooth"),
                callback =
                    function()
                        Bluetooth:onEnable()
                    end
            },
            {
                text = _("Disable Bluetooth"),
                callback =
                    function()
                        Bluetooth:onDisable()
                    end
            },
            {
                text = _("Toggle Bluetooth"),
                callback =
                    function()
                        Bluetooth:onToggle()
                    end
            },
            {
                text = _("Search Bluetooth"),
                callback =
                    function()
                        Bluetooth:search()
                    end
            },
        }
    }
end

function Bluetooth:onDispatcherRegisterActions()
    Dispatcher:registerAction("Bluetooth_toggle",
        { category = "none", event = "BluetoothToggle", title = _("Bluetooth Tooggle"), general = true, })
    Dispatcher:registerAction("Bluetooth_enable",
        { category = "none", event = "BluetoothEnable", title = _("Bluetooth Enable"), general = true, })
    Dispatcher:registerAction("Bluetooth_disable",
        { category = "none", event = "BluetoothDisable", title = _("Bluetooth Disable"), general = true, })
    Dispatcher:registerAction("Bluetooth_search",
        { category = "none", event = "BluetoothSearch", title = _("Bluetooth Search"), general = true, })
end

function Bluetooth:onExit()
    logger.info("Device exiting, disabling bluetooth")
    self:callDeviceFunction("disable")
end

function Bluetooth:onSuspend()
    logger.info("Device suspending, disabling bluetooth")
    self:callDeviceFunction("disable")
end


function Bluetooth:onPause()
    logger.info("Device pasung, disabling bluetooth")
    self:callDeviceFunction("disable")
end

function Bluetooth:onResume()
    logger.info("Device resumed, Restoring Bluetooth")
    self:callDeviceFunction("enable")
end

function Bluetooth:init()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)

    -- logger.info("Device initalised, Starting Bluetooth")
    -- self:callDeviceFunction("enable")
end

return Bluetooth



-- function NetworkMgr:getWifiToggleMenuTable()
--     local toggleCallback = function(touchmenu_instance, long_press)
--         self:queryNetworkState()
--         local fully_connected = self.is_wifi_on and self.is_connected
--         local complete_callback = function()
--             -- Notify TouchMenu to update item check state
--             touchmenu_instance:updateItems()
--         end -- complete_callback()
--         if fully_connected then
--             self:toggleWifiOff(complete_callback, true)
--         elseif self.is_wifi_on and not self.is_connected then
--             -- ask whether user wants to connect or turn off wifi
--             self:promptWifi(complete_callback, long_press, true)
--         else -- if not connected at all
--             self:toggleWifiOn(complete_callback, long_press, true)
--         end
--     end -- toggleCallback()

--     return {
--         text = _("Wi-Fi connection"),
--         enabled_func = function() return Device:hasWifiToggle() end,
--         checked_func = function() return self:isWifiOn() end,
--         callback = toggleCallback,
--         hold_callback = function(touchmenu_instance)
--             toggleCallback(touchmenu_instance, true)
--         end,
--     }
-- end
