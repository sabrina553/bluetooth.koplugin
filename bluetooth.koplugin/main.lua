local logger = require("logger")
local _ = require("gettext")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Device = require("device")

local BackendSelect = require("bluetooth/controller/backend_select")
local UIManager = require("ui/uimanager")

-- No backend for this device (Kobo, Kindle, Android): don't load at all.
-- KOReader skips a plugin whose main.lua returns { disabled = true }
-- (frontend/pluginloader.lua), so there are no menu entries or popups.
if not BackendSelect.select(Device) then
    logger.info("Bluetooth.koplugin: no backend for this device, not loading; family:", tostring(BackendSelect.family(Device)))
    return { disabled = true }
end

local BluetoothMenu = require("bluetooth/ui/menu")
local controller = require("bluetooth/controller/controller")
local BluetoothSettings = require("bluetooth/settings")
local Session = require("bluetooth/session")
local BluetoothDeviceStore = require("bluetooth/devicestore")
local GithubAPI = require("bluetooth/ota/github_api")
local BluetoothSelfUpdater = require("bluetooth/ota/self_updater")
local KeyStore = require("bluetooth/keys/store")
local Keymap = require("bluetooth/keys/keymap")
local Capture = require("bluetooth/keys/capture")
local KeysMenu = require("bluetooth/ui/keys_menu")
local InputContainer = require("ui/widget/container/inputcontainer")


-- How long a wake must hold before the radio is switched back on. PocketBook
-- bounces the app (resume, suspend ~1s later) on some wakes, and each
-- netagent toggle makes the firmware draw its own Bluetooth dialogs over the
-- cover screen. Waiting lets a bounce pass with no radio change at all.
local WAKE_SETTLE_S = 2

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

    self.key_store = KeyStore:new()
    self.keys_menu = KeysMenu:new({
        controller = self.controller,
        store = self.key_store,
        on_change = function() self:applyKeys() end,
    })

    self.menu = BluetoothMenu:new({
        ui = self.ui,
        settings = self.settings,
        controller = self.controller,
        devices = self.devices,
        updater = self.updater,
        keys_menu = self.keys_menu,
        on_devices_changed = function() self:applyKeys() end,
    })

    self.ui.menu:registerToMainMenu(self.menu)

    Capture.ensureHook(Device.input)
    self:applyKeys()

    if Session.isColdStart() then
        local was_on = self.settings:getRadioWasOn()
        logger.dbg("Bluetooth.koplugin: Cold start, restoring Bluetooth (was on: " .. tostring(was_on) .. ") in " .. WAKE_SETTLE_S .. "s")
        UIManager:scheduleIn(WAKE_SETTLE_S, function()
            self:restoreBluetoothState(was_on)
        end)
    end

    logger.dbg("Bluetooth.koplugin: Initialized")
end

---@param allow_enable boolean
function Bluetooth:restoreBluetoothState(allow_enable)

    local function notEnabled(reason)
        -- Only a disable (suspend) is expected here. A tap mid-enable now joins
        -- it (decision 2026-10-27), so the newer-enable WARN is a tripwire.
        if reason == "superseded" and not self.controller:wantsEnabled() then
            logger.dbg("Bluetooth.koplugin: enable replaced by a disable (suspend), skipping reconnect")
        elseif reason == "superseded" then
            logger.warn("Bluetooth.koplugin: enable replaced by a newer enable, skipping reconnect")
        else
            logger.warn("Bluetooth.koplugin: could not confirm bluetooth enabled, skipping reconnect")
        end
    end
    local function reconnect()
        self.controller:knownDevices(function(fresh)
            if fresh then
                self:applyKeys()
                self.controller:reconnectOnWake(function() self:applyKeys() end)
            else
                logger.dbg("Bluetooth.koplugin: device list went stale during wake, not reconnecting")
            end
        end)
    end

    self.controller:status()
    -- A resume right after suspend finds the radio still reading on while our
    -- disable is in flight; reconnecting then would talk to a dying daemon.
    -- enable() supersedes the disable and waits for the radio to go down.
    if self.controller:isDisabling() and allow_enable then
        self.controller:enable(function(enabled_confirmed, reason)
            if enabled_confirmed then
                reconnect()
            else
                notEnabled(reason)
            end
        end)
        return
    end
    if self.controller.is_enabled then
        return reconnect()
    end

    if not allow_enable then
        logger.dbg("Bluetooth.koplugin: Bluetooth is off, leaving it off")
        return
    end

    self.controller:enableWhenDisabled(function(enabled_confirmed, reason)
        if not enabled_confirmed then
            notEnabled(reason)
            return
        end
        reconnect()
    end)
end

function Bluetooth:onResume()
    logger.dbg("Bluetooth.koplugin: Device resumed, restoring Bluetooth in " .. WAKE_SETTLE_S .. "s")
    -- Only restore a radio that was on before the suspend; one the user had
    -- turned off stays off.
    local was_enabled = self.controller.was_enabled_before_suspend == true
    self.controller.was_enabled_before_suspend = nil
    if self._wake_restore then
        UIManager:unschedule(self._wake_restore)
    end
    self._wake_was_enabled = was_enabled
    self._wake_restore = function()
        self._wake_restore = nil
        self:restoreBluetoothState(was_enabled)
    end
    UIManager:scheduleIn(WAKE_SETTLE_S, self._wake_restore)
end

function Bluetooth:onSuspend()
    -- The radio goes down next; a monitor would only watch it go.
    self.menu:stopLiveMonitor()
    if self._wake_restore then
        -- Suspended again before the wake settled: the radio was never
        -- switched back on, so there is nothing to snapshot or disable. Hand
        -- the earlier "was on" over to the next resume.
        logger.dbg("Bluetooth.koplugin: Suspending before the wake settled, leaving the radio alone")
        UIManager:unschedule(self._wake_restore)
        self._wake_restore = nil
        self.controller.was_enabled_before_suspend = self._wake_was_enabled
        return
    end
    logger.dbg("Bluetooth.koplugin: Device suspending, disabling bluetooth")
    self.controller:snapshotBeforeSuspend(function()
        if self.settings:getDisableOnSuspend() then
            self.controller:disable()
        end
    end)
end

--- Applies the bindings of the connected remotes for this screen. Connection
--- order isn't tracked, so list order stands in for "newest wins" on clashes
--- (decision 2026-10-28).
function Bluetooth:applyKeys()
    -- Wake, cold-start and menu callbacks keep the instance they were made
    -- on; after a view change it must not apply its old screen's map
    -- (decision 2026-10-28).
    if self.closed then return end
    local screen = self.ui.document and "reader" or "filemanager"
    local active, by_remote, seen = {}, {}, {}
    for _, dev in ipairs(self.controller.known_devices or {}) do
        if dev.connected and dev.name and dev.name ~= "" and not seen[dev.name] then
            seen[dev.name] = true
            active[#active + 1] = dev.name
            by_remote[dev.name] = self.key_store:list(dev.name)
        end
    end
    local map, clashes = Keymap.resolve(by_remote, active, screen)
    for _, c in ipairs(clashes) do
        logger.warn("Bluetooth.koplugin: button", c.code, "bound by several remotes:",
            table.concat(c.remotes, ", "), "- using", c.remotes[#c.remotes])
    end
    Keymap.apply(Device.input.event_map, map)

    -- Slot handlers live on this instance; a new view builds a new plugin.
    self.key_events = self.key_events or {}
    for name in pairs(self.key_events) do
        if name:sub(1, #Keymap.SLOT_PREFIX) == Keymap.SLOT_PREFIX then
            self.key_events[name] = nil
            self["on" .. name] = nil
        end
    end
    for code, b in pairs(map) do
        if b.action.kind == "dispatcher" then
            local name = Keymap.SLOT_PREFIX .. code
            self.key_events[name] = { { name } }
            self["on" .. name] = function() return Keymap.run(code) end
        end
    end
end

--- A WidgetContainer never reads key_events: InputContainer:onKeyPress does
--- (inputcontainer.lua onKeyPress). ReaderUI and FileManager propagate
--- KeyPress to their modules, plugins included (WidgetContainer:handleEvent,
--- registerModule), so borrowing the matcher is enough. decision 2026-10-28
function Bluetooth:onKeyPress(key)
    self.key_events = self.key_events or {}
    return InputContainer.onKeyPress(self, key)
end

--- The plugin closes with its view (file manager <-> book) and on exit.
function Bluetooth:onCloseWidget()
    self.closed = true
    if self.menu then self.menu:stopLiveMonitor() end
end

return Bluetooth