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
    end


    return menu
end

return BluetoothMenu