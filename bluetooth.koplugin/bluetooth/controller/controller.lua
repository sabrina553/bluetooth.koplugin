local logger = require("logger")
local Device = require("device")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local _ = require("gettext")

local PocketBook = require("bluetooth/controller/pocketbook")
local Bluez = require("bluetooth/controller/bluez")

---@class controller
---@field type string
---@field is_enabled boolean
---@field is_scanning boolean
---@field is_connected boolean
---@field is_disconnected boolean
---@field device_store any
---@field KnownDevices Devices[]
---@field backend any
---@return controller
local controller = {}

function controller:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    o:init()
    return o
end

-- Maps a device type name to the backend *instance* that implements it.
-- Using instances (rather than re-deriving the type each call) means we
-- only construct PocketBook/Bluez once and reuse them across the app.
-- NOTE: these are shared singletons, so we (re)assign `.controller` on
-- whichever one gets selected in init(), rather than passing it in here.
local backends = {
    PocketBook = PocketBook:new(),
    Bluez = Bluez:new(),
}

function controller:init()
    self:Devicetype()

    self.backend = backends[self.type]
    if self.backend then
        -- Give the backend a way to call back into this controller (and,
        -- via the backend, so can any Devices instance it constructs).
        self.backend.controller = self
    end

    self:status()
    self:knownDevices()

    logger:dbg("Bluetooth.koplugin.Controller Initialized")
end

function controller:Devicetype()
    if Device:isAndroid() then
        self.type = "Android"
    elseif Device:isPocketBook() then
        self.type = "PocketBook"
    elseif Device:isEmulator() or Device:isDesktop() then
        self.type = "Bluez"
    elseif Device:isKindle() then
        self.type = "Kindle"
    elseif Device:isKobo() then
        self.type = "Kobo"
    end
end

function controller:callDeviceFunction(action, variable)
    if self.backend and self.backend[action] then
        return self.backend[action](self.backend, variable)
    else
        UIManager:show(InfoMessage:new { text = _("Unsupported Bluetooth action on this device"), timeout = 2, })
    end
end

--- Look up a previously-known Devices instance by mac address.
---@param mac string
---@return Devices|nil
function controller:getDevice(mac)
    logger.dbg("Looking up known device by MAC: " .. mac)
    if not self.known_devices then
        return nil
    end

    for _, dev in ipairs(self.known_devices) do
        if dev.mac == mac then
            return dev
        end
    end
    return nil
end

--- Re-applies persisted per-device app state (currently just `starred`) onto
--- the live known_devices list, since knownDevices() builds fresh Devices
--- instances every time it runs and bluetoothctl doesn't track this for us.
function controller:applyStoredDeviceState()
    if not self.device_store then
        return
    end
    for _, dev in ipairs(self.known_devices or {}) do
        local stored = self.device_store:get(dev.mac)
        if stored then
            dev.starred = stored.starred or false
        end
    end
end

--- Writes the current known_devices list to disk.
function controller:persistDeviceState()
    if not self.device_store then
        return
    end
    self.device_store:saveAll(self.known_devices)
end

--- Returns every currently-known device with `starred == true`. Multiple
--- devices may be starred simultaneously.
---@return Devices[]
function controller:getStarredDevices()
    local starred = {}
    for _, dev in ipairs(self.known_devices or {}) do
        if dev.starred then
            table.insert(starred, dev)
        end
    end
    return starred
end

--- Call right before bluetooth gets torn down for suspend/pause. Refreshes
--- device state one last time (so `connected` reflects reality) and snapshots
--- it to disk — bluetoothctl won't remember "was connected right before
--- suspend" once the radio's been power-cycled, so this is our only record.
--- Takes a callback because knownDevices() can be async (e.g. on PocketBook,
--- which needs to confirm the radio is on before it can query device info);
--- persisting before that finishes would risk writing stale `connected`
--- values.
---@param callback fun()|nil
function controller:snapshotBeforeSuspend(callback)
    self:knownDevices(function()
        self:persistDeviceState()
        if callback then callback() end
    end)
end

--- Call after bluetooth's been re-enabled and known_devices refreshed on
--- wake. Reconnects every starred device and/or whatever was connected right
--- before suspend, gated by the corresponding settings.
function controller:reconnectOnWake()
    if not self.settings or not self.device_store then
        return
    end

    local wanted_macs = {}

    if self.settings:getStarredOnWake() then
        for _, entry in ipairs(self.device_store:getStarred()) do
            wanted_macs[entry.mac] = true
        end
    end

    if self.settings:getLastOnWake() then
        for _, entry in ipairs(self.device_store:getConnected()) do
            wanted_macs[entry.mac] = true
        end
    end

    for mac in pairs(wanted_macs) do
        local dev = self:getDevice(mac)
        if dev then
            logger.dbg("Bluetooth: reconnecting to " .. mac .. " on wake")
            dev:connect()
        else
            logger.warn("Bluetooth: stored device " .. mac .. " not found among known_devices, skipping wake reconnect")
        end
    end
end

-- How long enable()/disable() wait before actually issuing the radio
-- command. If a closely-spaced opposite call (e.g. resume right after
-- suspend) supersedes this one within the window, the command is never
-- sent at all - rather than sending "off" and "on" back-to-back straight
-- to the daemon, which is what produced "No default controller available"
-- on some devices. Adds a small, mostly-imperceptible delay to every
-- deliberate single enable/disable too, which is the tradeoff for not
-- sending contradictory commands to the radio in quick succession.
local ENABLE_DISABLE_DEBOUNCE_S = 0.15

---@param expected boolean 
---@param callback fun(confirmed: boolean)|nil 
---@param attempt integer|nil internal, do not pass
---@param generation integer the poll generation this call belongs to, captured
---  by enable()/disable() at the moment they started polling. If a newer
---  enable()/disable() call has since bumped self._poll_generation, this
---  loop has been superseded and should stop quietly rather than keep
---  polling and firing its own (now-stale) callback alongside the new one.
local function pollField(self, field, expected, callback, attempt, generation)
    if generation ~= self._poll_generation then
        logger.dbg("Bluetooth: pollField for " .. field .. " superseded by a newer enable/disable call, stopping")
        return
    end

    logger.dbg ("Polling field: " .. field .. " for value: " .. tostring(expected))

    attempt = attempt or 1
    local max_attempts = 10
    local delay_s = 1

    self:status()

    -- self:status() can itself take a moment on some backends; re-check
    -- here too in case a newer enable/disable call landed while it ran.
    if generation ~= self._poll_generation then
        logger.dbg("Bluetooth: pollField for " .. field .. " superseded by a newer enable/disable call, stopping")
        return
    end

    if self[field] == expected then
        if callback then callback(true) end
        return
    end

    if attempt >= max_attempts then
        logger.warn("Controller could not confirm connection state")
        if callback then callback(false) end
        return
    end
    UIManager:scheduleIn(delay_s, function()
        pollField(self, field, expected, callback, attempt + 1, generation)
    end)
end


function controller:status()
    logger.dbg("Checking Bluetooth status")
    self.is_enabled = self:callDeviceFunction("status")
end

function controller:enable(callback)
    logger.dbg("Enabling Bluetooth Controller")
    -- Bumping the generation here - before the debounced command even
    -- fires - immediately supersedes any disable()/enable() call that
    -- might still be pending or polling from an earlier, closely-spaced
    -- call (e.g. suspend immediately followed by resume). Without this,
    -- both could end up issuing os.execute('netagent bt on/off') and
    -- polling status() concurrently against the same underlying radio.
    self._poll_generation = (self._poll_generation or 0) + 1
    local my_generation = self._poll_generation

    UIManager:scheduleIn(ENABLE_DISABLE_DEBOUNCE_S, function()
        if my_generation ~= self._poll_generation then
            logger.dbg("Bluetooth: enable() superseded before its command was sent, skipping")
            return
        end
        self:callDeviceFunction("enable")
        pollField(self, "is_enabled", true, callback, nil, my_generation)
    end)
end

function controller:disable(callback)
    logger.dbg("Disabling Bluetooth Controller")
    self._poll_generation = (self._poll_generation or 0) + 1
    local my_generation = self._poll_generation

    UIManager:scheduleIn(ENABLE_DISABLE_DEBOUNCE_S, function()
        if my_generation ~= self._poll_generation then
            logger.dbg("Bluetooth: disable() superseded before its command was sent, skipping")
            return
        end
        self:callDeviceFunction("disable")
        pollField(self, "is_enabled", false, callback, nil, my_generation)
    end)
end

function controller:toggle(callback)
    self:status()
    if self.is_enabled then
        return self:disable(callback)
    else
        return self:enable(callback)
    end
end

function controller:enableWhenDisabled(callback)
    self:status()
    if not self.is_enabled then
        return self:enable(callback)
    elseif callback then
        -- Deferred to the next tick rather than called inline, so this
        -- matches enable()'s async timing regardless of whether Bluetooth
        -- happened to already be on - callers shouldn't have to care which
        -- path fired to reason about ordering.
        UIManager:scheduleIn(0, function() callback(true) end)
    end
end

--- Refreshes self.known_devices from the backend.
---
--- Only PocketBook's netagent needs the radio actually on to answer a
--- device query at all - other backends can just refresh directly. For
--- PocketBook, if the radio is currently off, this enables it just long
--- enough to read device info, then (by default) turns it back off again
--- afterward, since being asked "what devices do you know about" shouldn't
--- by itself leave the radio running.
---
---@param callback fun(confirmed: boolean)|nil invoked exactly once
---@param opts table|nil { leave_enabled: boolean } - pass { leave_enabled =
---  true } when the caller needs Bluetooth to stay on after this refresh
---  completes (e.g. reconnectOnWake(), which needs to actually connect to
---  devices right afterward - if this function turned the radio back off
---  first, that connect would immediately fail).
function controller:knownDevices(callback, opts)
    logger.dbg("Refreshing known devices")
    opts = opts or {}

    local function refresh()
        self.known_devices = self:callDeviceFunction("knownDevices") or {}

        for _, dev in ipairs(self.known_devices) do
            dev:refresh()
        end

        self:applyStoredDeviceState()
        return self.known_devices
    end

    if self.backend ~= backends.PocketBook then
        refresh()
        if callback then callback(true) end
        return self.known_devices
    end

    self:status()
    if self.is_enabled then
        refresh()
        if callback then callback(true) end
        return self.known_devices
    end

    self:enable(function(enabled_confirmed)
        if not enabled_confirmed then
            if callback then callback(false) end
            return
        end

        refresh()

        if not opts.leave_enabled then
            -- We were the one who turned it on just to read this. Its
            -- confirmation is independent of whether the refresh itself
            -- succeeded, so it must NOT invoke `callback` again below -
            -- that already fired once, and calling it a second time
            -- (possibly with a contradictory result) is exactly the bug
            -- this replaced.
            self:disable(function(disable_confirmed)
                if not disable_confirmed then
                    logger.warn("Bluetooth: could not confirm re-disable after a knownDevices()-triggered enable")
                end
            end)
        end

        if callback then callback(true) end
    end)

    -- Necessarily stale here - the enable/refresh/disable chain above is
    -- still in flight. Callers that need the fresh list must use the
    -- callback, not this return value.
    return self.known_devices
end

function controller:search(callback, duration)
    logger.dbg("Starting Bluetooth scan for " .. tostring(duration) .. " seconds")
    self:enableWhenDisabled(function(enabled_confirmed)
        if not enabled_confirmed then
            if callback then callback(false) end
            return
        end
        self:callDeviceFunction("search", duration)
        if callback then callback(true) end
    end)
end

---@param mac string
function controller:info(mac)
    logger.dbg("Fetching info for device with MAC: " .. tostring(mac))
    return self:callDeviceFunction("info", mac)
end

return controller