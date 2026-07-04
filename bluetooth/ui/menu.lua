local _ = require("gettext")

local logger = require("logger")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local controller = require("bluetooth/controller/controller")


---@class BluetoothMenu
---@field ui any This is a ReaderUI
---@field controller any
local BluetoothMenu = {}

function BluetoothMenu:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

function BluetoothMenu:addToMainMenu(menu_items)
    menu_items.bluetooth = {
        text = "Bluetooth",
        sorting_hint = "tools",
        sub_item_table_func = function()
            return self:getTopMenu()
        end,
    }
end

function BluetoothMenu:getTopMenu()
    local menu = {
        {
            text = _("Bluetooth"),
            callback = function()
                self.controller:toggle()
            end,
            checked_func = function()
                return self.controller.is_enabled
            end,
            keep_menu_open = true,
        },
        {
            text = _("Search Bluetooth"),
            callback = function()
                self.controller:search()
            end,
            separator = true,
        }
    }

    local knownDevices = self.controller.knownDevices

    if knownDevices ~= nil then
        -- Iterate over the known Devices objects
        for _, dev in ipairs(knownDevices) do
            -- Insert the menu item
            table.insert(menu, {
                text = string.format(dev.connected and (dev.name .. " (connected)") or dev.name),
                callback = function()
                    -- Each Devices instance knows its own backend, so it
                    -- can connect itself without going back through the
                    -- controller with a raw mac address.
                    dev:connect()
                end,
            })
        end
        if touchmenu_instance then
            touchmenu_instance:updateItems()
        end
    end)
end

function BluetoothMenu:showDeviceActions(dev, touchmenu_instance)
    local dialog
    dialog = ButtonDialogTitle:new{
        title = dev.name,
        buttons = {
            {
                {
                    text = "info",
                    callback = function()
                        UIManager:close(dialog)
                        local info_msg = InfoMessage:new{
                            text = _("Device: ") .. dev.name .. "\n" ..
                                   _("MAC: ") .. dev.mac .. "\n" ..
                                   _("Paired: ") .. tostring(dev.paired) .. "\n" ..
                                   _("Connected: ") .. tostring(dev.connected) .. "\n" ..
                                   _("Trusted: ") .. tostring(dev.trusted) .. "\n" ..
                                   _("Blocked: ") .. tostring(dev.blocked),
                            
                        }
                        UIManager:show(info_msg)
                        if touchmenu_instance then
                            touchmenu_instance:updateItems()
                        end
                    end,
                },
                {
                    text = dev.paired and _("Unpair") or _("Pair"),
                    callback = function()
                        UIManager:close(dialog)
                        dev:togglePairing(dev, function(confirmed)
                            if not confirmed then
                                UIManager:show(InfoMessage:new{
                                    text = _("Could not confirm pairing change for ") .. dev.name,
                                    timeout = 2,
                                })
                            end
                            if touchmenu_instance then
                                touchmenu_instance:updateItems()
                            end
                            
                        end)
                    end,
                },
                {
                    text = dev.trusted and _("Untrust") or _("Trust"),
                    callback = function()
                        UIManager:close(dialog)
                        dev:toggleTrust(dev, function(confirmed)
                            if not confirmed then
                                UIManager:show(InfoMessage:new{
                                    text = _("Could not confirm trust change for ") .. dev.name,
                                    timeout = 2,
                                })
                            end
                            if touchmenu_instance then
                                touchmenu_instance:updateItems()
                            end
                        end)
                    end,
                },
                {
                    text = dev.blocked and _("Unblock") or _("Block"),
                    callback = function()
                        UIManager:close(dialog)
                        dev:toggleBlock(dev, function(confirmed)
                            if not confirmed then
                                UIManager:show(InfoMessage:new{
                                    text = _("Could not confirm block change for ") .. dev.name,
                                    timeout = 2,
                                })
                            end
                            if touchmenu_instance then
                                touchmenu_instance:updateItems()
                            end
                        end)
                    end,
                    separator = true,
                },

            },
            {
                {
                    text = dev.connected and _("Disonnect") or _("Connect"),
                    callback = function()
                        UIManager:close(dialog)
                        dev:toggleConnection(dev, function(confirmed)
                            if not confirmed then
                                UIManager:show(InfoMessage:new{
                                    text = _("Could not confirm connection change for ") .. dev.name,
                                    timeout = 2,
                                })
                            end
                            if touchmenu_instance then
                                touchmenu_instance:updateItems()
                            end
                        end)
                    end,
                },
            },
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

return BluetoothMenu