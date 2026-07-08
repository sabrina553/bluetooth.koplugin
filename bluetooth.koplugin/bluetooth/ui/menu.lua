local _ = require("gettext")
local T = require("ffi/util").template

local Menu = require("ui/widget/menu")
local InfoMessage = require("ui/widget/infomessage")
local ButtonDialogTitle = require("ui/widget/buttondialogtitle")
local UIManager = require("ui/uimanager")
local Event = require("ui/event")
local ButtonDialog = require("ui/widget/buttondialog")
local logger = require("logger")

local PluginMetadata = require("bluetooth/plugin_metadata")

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
---@field updater BluetoothSelfUpdater
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
    self:refresh()
    local menu = {
        {
            text = _("Bluetooth"),
            callback = function(touchmenu_instance)
                --self.controller:toggle(function(confirmed)
                local msg
                if self.controller.is_enabled then
                    msg = InfoMessage:new{ text = _("Disabling Bluetooth") }
                else
                    msg = InfoMessage:new{ text = _("Enabling Bluetooth") }
                end
                UIManager:show(msg)
                self.controller:toggle(function(confirmed)
                    UIManager:close(msg)
                    if confirmed and self.controller.is_enabled then
                        UIManager:show(InfoMessage:new{
                            text = _("Bluetooth Enabled"),
                            timeout = 1,
                        })
                    elseif not self.controller.is_enabled then
                        UIManager:show(InfoMessage:new{
                            text = _("Bluetooth Disabled"),
                            timeout = 1,
                        })
                    else
                        UIManager:show(InfoMessage:new{
                            text = _("Could not confirm Bluetooth controller status "),
                            timeout = 2,
                        })
                    end
                    self:refresh(touchmenu_instance)
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
                    self:refresh(touchmenu_instance)
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
    --self:refresh()
    return self:buildMenuTable()
end

function BluetoothMenu:refresh(touchmenu_instance)
    self.controller:status()
    self.controller:knownDevices()
    self:refreshMenu(touchmenu_instance)
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

                            self:refresh(touchmenu_instance)
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
            separator = true,
        },
        {
            text = _("Update Channel"),
            sub_item_table = self:getUpdateChannelMenu(),
        },
        {
            text = _("About"),
            sub_item_table = self:getAboutMenu(),
        },
    }
end

function BluetoothMenu:getUpdateChannelMenu()
    return {
        {
            text = _("Stable"),
            checked_func = function()
                return self.settings:getUpdateChannel() == "stable"
            end,
            radio = true,
            callback = function(touchmenu_instance)
                self:setUpdateChannel("stable", touchmenu_instance)
            end,
            keep_menu_open = true,
        },
        {
            text = _("Development"),
            checked_func = function()
                return self.settings:getUpdateChannel() == "development"
            end,
            radio = true,
            callback = function(touchmenu_instance)
                self:setUpdateChannel("development", touchmenu_instance)
            end,
            keep_menu_open = true,
        },
    }
end

--- Switches the update channel and immediately re-checks for a release on
--- the new channel, since the updater's cached latest_known_version was
--- fetched against whichever channel was active before this call.
function BluetoothMenu:setUpdateChannel(channel, touchmenu_instance)
    if self.settings:getUpdateChannel() == channel then
        return
    end

    self.settings:setUpdateChannel(channel)
    UIManager:broadcastEvent(Event:new("BluetoothSettingsChanged"))

    local close_message = self:toast(_("Checking for updates…"), 0)
    self.updater:fetchLatestVersion()
    pcall(close_message)

    self:refresh(touchmenu_instance)
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
                        self:refresh(touchmenu_instance)
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
                            self:refresh(touchmenu_instance)
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
                            self:refresh(touchmenu_instance)
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
                            self:refresh(touchmenu_instance)
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
                            self:refresh(touchmenu_instance)
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
                            self:refresh(touchmenu_instance)
                        end)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function BluetoothMenu:getAboutMenu()
    -- These won't change after the plugin starts up
    local repository = PluginMetadata.getRepository()
    local version = PluginMetadata.getVersion()

    return {
        {
            text = repository,
            keep_menu_open = true,
        },
        {
            text = T(_("Version %1"), version),
            keep_menu_open = true,
            separator = true,
        },
        {
            text_func = function()
                if self.updater:isPendingRestart() then
                    return _("Update Pending Restart")
                end

                if self.updater:isUpdateAvailable() then
                    local latest_version = self.updater:getLatestReleaseVersion()
                    return T(_("Update to %1"), latest_version)
                end

                return _("Check for Updates")
            end,
            callback = function()
                if self.updater:isPendingRestart() then
                    UIManager:askForRestart(_("Bluetooth plugin update will apply on next Restart."))
                else
                    self:showPluginUpdateCheck()
                end
            end,
        },
    }
end

function BluetoothMenu:showPluginUpdateCheck(skip_version_check)
    if not skip_version_check then
        -- Refresh the latest version on open.
        local close_message = self:toast(_("Checking for Updates"), 0)
        self.updater:fetchLatestVersion()
        pcall(close_message)
    end

    local dialog
    local latest_version = self.updater:getLatestReleaseVersion()
    local is_update_available = self.updater:isUpdateAvailable()

    local update_button_text = _("No update available")
    local title = _("Bluetooth.koplugin is currently up-to-date.")

    if is_update_available then
        update_button_text = T(_("Update to %1"), latest_version)
        title = _("Update available for Bluetooth.koplugin.")
    end

    dialog = ButtonDialog:new({
        title = title,
        buttons = {
            {
                {
                    text = update_button_text,
                    callback = function()
                        if is_update_available then
                            UIManager:close(dialog)

                            self:showPluginUpdater()
                        end
                    end,
                },
                {
                    text = _("Check for Updates"),
                    callback = function()
                        self.updater:fetchLatestVersion()
                        UIManager:close(dialog)
                        self:showPluginUpdateCheck(true)
                    end,
                },
            },
            {
                {
                    text = _("Close"),
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
            },
        },
    })

    UIManager:show(dialog)
end

--- Actually performs the update: downloads the release asset, verifies it,
--- and extracts it into place, using self.updater:update()'s progress
--- callback to keep a single persistent toast up to date. This was
--- previously called from showPluginUpdateCheck's "Update to vX" button but
--- never defined, so tapping that button crashed with a nil-method error
--- instead of ever starting a download.
function BluetoothMenu:showPluginUpdater()
    self:toast(_("Starting update…"), 0)

    self.updater:update(function(stage, percent, message)
        if stage == "download" then
            self:toast(T(_("Downloading update… %1%%"), percent or 0), 0)
        elseif stage == "complete" then
            if self.info_message then
                UIManager:close(self.info_message)
                self.info_message = nil
            end
            UIManager:askForRestart(_("Bluetooth plugin update downloaded. Restart to apply."))
        elseif stage == "failed" then
            self:toast(T(_("Update failed: %1"), tostring(message or _("unknown error"))), 3)
        else
            logger:warn("Bluetooth: unexpected update progress stage", tostring(stage))
        end
    end)
end

function BluetoothMenu:toast(text, timeout)
    if self.info_message then
        UIManager:close(self.info_message)
    end

    if timeout == nil then
        timeout = 2
    elseif timeout <= 0 then
        timeout = nil
    end

    local info_message = InfoMessage:new({
        text = text,
        timeout = timeout,
    })

    UIManager:show(info_message)
    self.info_message = info_message

    return function() UIManager:close(info_message) end
end

return BluetoothMenu