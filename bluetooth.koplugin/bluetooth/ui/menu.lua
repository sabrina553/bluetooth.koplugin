local _ = require("gettext")

local Menu = require("ui/widget/menu")
local InfoMessage = require("ui/widget/infomessage")
local ButtonDialogTitle = require("ui/widget/buttondialogtitle")
local UIManager = require("ui/uimanager")
local Event = require("ui/event")

local function displayName(dev)
    if dev.name and dev.name ~= "" then
        return dev.name
    end
    return dev.mac
end

local function isNamed(dev)
    return dev.name ~= nil and dev.name ~= ""
end

local function buildItemTable(devices)
    local sorted = {}
    for _, dev in ipairs(devices or {}) do
        if not dev.paired then
            table.insert(sorted, dev)
        end
    end
    table.sort(sorted, function(a, b)
        local a_named, b_named = isNamed(a), isNamed(b)
        if a_named ~= b_named then
            return a_named -- named devices float to the top
        end
        if a_named then
            return a.name:lower() < b.name:lower()
        end
        return a.mac < b.mac
    end)

    local item_table = {}
    for _, dev in ipairs(sorted) do
        table.insert(item_table, { text = displayName(dev), dev = dev })
    end
    return item_table
end

---@class BluetoothMenu
---@field ui any This is a ReaderUI
---@field controller any
---@field devices any
---@field menu_instance any
---@field settings BluetoothSettings
local BluetoothMenu = {}

function BluetoothMenu:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

function BluetoothMenu:addToMainMenu(menu_items)
    menu_items.bluetooth = {
        text = _("Bluetooth"),
        sorting_hint = "tools",
        sub_item_table_func = function(touchmenu_instance)
            self.touchmenu_instance = touchmenu_instance
            return self:getTopMenu()
        end,
    }
end

function BluetoothMenu:refreshMenu(touchmenu_instance)
    touchmenu_instance = touchmenu_instance or self.touchmenu_instance
    if not touchmenu_instance then
        return
    end
    touchmenu_instance.item_table = self:buildMenuTable()
    touchmenu_instance:updateItems()
end

--- Builds the full Bluetooth submenu item table from current state.
function BluetoothMenu:buildMenuTable()
    --self:refreshKnownDevicesAsync()
    local menu = {
        {
            text = _("Bluetooth"),
            callback = function(touchmenu_instance)
                self.controller:toggle(function(confirmed)
                    self.controller:knownDevices()
                    self:refreshMenu(touchmenu_instance)
                end)
            end,
            checked_func = function()
                return self.controller.is_enabled
            end,
            keep_menu_open = true,
        },
        {
            text = _("Settings"),
            sub_item_table = self:getSettingsMenu(),
        },
        {
            text = _("Search Bluetooth"),
            callback = function(touchmenu_instance)
                self:showSearchResults(function(confirmed)
                    self:refreshMenu(touchmenu_instance)
                end)
            end,
            keep_menu_open = true,
            separator = true,
        },
    }

    self:pairedDevices(menu, self.controller.known_devices)
    return menu
end

function BluetoothMenu:getTopMenu()
    self:refreshKnownDevicesAsync()
    return self:buildMenuTable()
end

function BluetoothMenu:refreshKnownDevicesAsync()
    --UIManager:scheduleIn(0, function()
    self.controller:status()
    self.controller:knownDevices()
    self:refreshMenu()
    --end)
end

function BluetoothMenu:pairedDevices(menu, knownDevices)
    if knownDevices ~= nil then
        -- Iterate over the known Devices objects
        for i, dev in ipairs(knownDevices) do
            -- Insert the menu item
            if dev.paired == true then
                table.insert(menu, {
                    text = (dev.starred and "★ " or "") .. dev.name,
                    callback = function(touchmenu_instance)

                        local msg
                        if dev.connected then
                            msg = InfoMessage:new{ text = _("Disconnecting…") }
                        else
                            msg = InfoMessage:new{ text = _("Connecting…") }
                        end
                        UIManager:show(msg)
                        dev:toggleConnection(function(confirmed)
                            UIManager:close(msg)
                            if confirmed and dev.connected then
                                UIManager:show(InfoMessage:new{
                                    text = _("Connected to ") .. dev.name,
                                    timeout = 1,
                                })
                            elseif not dev.connected then
                                UIManager:show(InfoMessage:new{
                                    text = _("Disconnected from ") .. dev.name,
                                    timeout = 1,
                                })
                            else
                                UIManager:show(InfoMessage:new{
                                    text = _("Could not confirm connection to ") .. dev.name,
                                    timeout = 2,
                                })
                            end

                            self:refreshMenu(touchmenu_instance)
                        end)
                    end,
                    checked_func = function()
                        return dev.connected
                    end,
                    hold_callback = function(touchmenu_instance)
                        self:showDeviceActions(dev, touchmenu_instance)
                    end,
                    keep_menu_open = true,
                })
            end
        end
    end
end

function BluetoothMenu:getSettingsMenu()
     return {
        {
            text = _("Enable on Wake"),
            checked_func = function()
                return self.settings:getEnableOnWake()
            end,
            callback = function()
                self.settings:toggleEnableOnWake()
                UIManager:broadcastEvent(Event:new("BluetoothSettingsChanged"))
            end,
            keep_menu_open = true,
        },
        {
            text = _("Disable on lock"),
            checked_func = function()
                return self.settings:getDisableOnLock()
            end,
            callback = function()
                self.settings:toggleDisableOnLock() -- toggles :? 
                UIManager:broadcastEvent(Event:new("BluetoothSettingsChanged"))
            end,
            keep_menu_open = true,
        },
        {
            text = _("Disable on Suspend"),
            checked_func = function()
                return self.settings:getDisableOnSuspend()
            end,
            callback = function()
                self.settings:toggleDisableOnSuspend()
                UIManager:broadcastEvent(Event:new("BluetoothSettingsChanged"))
            end,
            keep_menu_open = true,
            separator = true,
        },
        {
            text = _("Starred on Wake"),
            checked_func = function()
                return self.settings:getStarredOnWake()
            end,
            callback = function()
                self.settings:toggleStarredOnWake()
                UIManager:broadcastEvent(Event:new("BluetoothSettingsChanged"))
            end,
            keep_menu_open = true,
        },
        {
            text = _("Last on Wake"),
            checked_func = function()
                return self.settings:getLastOnWake()
            end,
            callback = function()
                self.settings:toggleLastOnWake()
                UIManager:broadcastEvent(Event:new("BluetoothSettingsChanged"))
            end,
            keep_menu_open = true,
        }}
end

function BluetoothMenu:showSearchResults(on_refresh)
    local scan_duration = 15
    local poll_interval = 1

    self.controller:search(on_refresh, scan_duration)
    self.search_menu_closed = false

    self.search_menu = Menu:new{
        title = _("Searching for devices…"),
        item_table = buildItemTable(self.controller.known_devices),
        onMenuSelect = function(_, item)
            self:pairFoundDevice(item.dev, on_refresh)
        end,
        close_callback = function()
            self.search_menu_closed = true
            UIManager:close(self.search_menu)
        end,
    }
    UIManager:show(self.search_menu)

    local elapsed = 0
    local function poll()
        if self.search_menu_closed then
            return
        end
        elapsed = elapsed + poll_interval
        self.controller:knownDevices() -- re-shells bluetoothctl devices + refreshes each dev
        local done = elapsed >= scan_duration
        self.search_menu:switchItemTable(
            done and _("Search complete") or _("Searching for devices…"),
            buildItemTable(self.controller.known_devices)
        )
        if not done then
            UIManager:scheduleIn(poll_interval, poll)
        end
    end
    UIManager:scheduleIn(poll_interval, poll)
end

function BluetoothMenu:pairFoundDevice(dev, on_refresh)
    if dev.paired then
        return -- already paired, nothing to do from here
    end

    local msg = InfoMessage:new{ text = _("Pairing with ") .. displayName(dev) .. "…" }
    UIManager:show(msg)

    dev:pair(function(confirmed)
        UIManager:close(msg)
        if confirmed then
            UIManager:show(InfoMessage:new{
                text = _("Paired with ") .. displayName(dev),
                timeout = 1,
            })
            local already_known = false
            for _, known in ipairs(self.controller.known_devices or {}) do
                if known.mac == dev.mac then
                    already_known = true
                    break
                end
            end
            if not already_known then
                table.insert(self.controller.known_devices, dev)
            end
        else
            UIManager:show(InfoMessage:new{
                text = _("Could not confirm pairing with ") .. displayName(dev),
                timeout = 2,
            })
        end
        if on_refresh then
            on_refresh(confirmed)
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
                        self:refreshMenu(touchmenu_instance)
                    end,
                },
                {
                    text = dev.paired and _("Unpair") or _("Pair"),
                    callback = function()
                        UIManager:close(dialog)
                        dev:togglePair(function(confirmed)
                            if not confirmed then
                                UIManager:show(InfoMessage:new{
                                    text = _("Could not confirm pairing change for ") .. dev.name,
                                    timeout = 2,
                                })
                            end
                            self:refreshMenu(touchmenu_instance)
                        end)
                    end,
                },
                {
                    text = dev.trusted and _("Untrust") or _("Trust"),
                    callback = function()
                        UIManager:close(dialog)
                        dev:toggleTrust(function(confirmed)
                            if not confirmed then
                                UIManager:show(InfoMessage:new{
                                    text = _("Could not confirm trust change for ") .. dev.name,
                                    timeout = 2,
                                })
                            end
                            self:refreshMenu(touchmenu_instance)
                        end)
                    end,
                },
                {
                    text = dev.blocked and _("Unblock") or _("Block"),
                    callback = function()
                        UIManager:close(dialog)
                        dev:toggleBlock(function(confirmed)
                            if not confirmed then
                                UIManager:show(InfoMessage:new{
                                    text = _("Could not confirm block change for ") .. dev.name,
                                    timeout = 2,
                                })
                            end
                            self:refreshMenu(touchmenu_instance)
                        end)
                    end,
                    separator = true,
                },

            },
            {
                {
                    text = dev.connected and _("Disconnect") or _("Connect"),
                    callback = function()
                        UIManager:close(dialog)
                        dev:toggleConnection(function(confirmed)
                            if not confirmed then
                                UIManager:show(InfoMessage:new{
                                    text = _("Could not confirm connection change for ") .. dev.name,
                                    timeout = 2,
                                })
                            end
                            self:refreshMenu(touchmenu_instance)
                        end)
                    end,
                },
            },
            {
                {
                    text = dev.starred and _("Unstar") or _("Star"),
                    callback = function()
                        UIManager:close(dialog)
                        dev:toggleStar(function()
                            self:refreshMenu(touchmenu_instance)
                        end)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

return BluetoothMenu