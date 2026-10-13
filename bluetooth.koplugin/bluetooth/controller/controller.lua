local logger = require("logger")
local Device = require("device")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local _ = require("gettext")

local BackendSelect = require("bluetooth/controller/backend_select")
local PocketBook = require("bluetooth/controller/pocketbook")
local Bluez = require("bluetooth/controller/bluez")
local Parse = require("bluetooth/controller/bluetoothctl_parse")
local Devices = require("bluetooth/controller/devices")

-- Sub-second clock for timing logs; os.time is only whole seconds.
local socket_ok, socket = pcall(require, "socket")
local function now()
    return socket_ok and socket.gettime() or os.time()
end

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

    -- Only read devices when the radio is already on: on PocketBook a read
    -- powers the radio on and off again, which flickered it on every view
    -- change. The menu refreshes when it is opened.
    self:status()
    if self.is_enabled then
        self:knownDevices()
    end

    logger.dbg("Bluetooth.koplugin.Controller Initialized")
end

function controller:Devicetype()
    self.type = BackendSelect.select(Device)
end

function controller:callDeviceFunction(action, variable)
    if self.backend and self.backend[action] then
        return self.backend[action](self.backend, variable)
    else
        logger.warn("Bluetooth: backend has no action", tostring(action))
        UIManager:show(InfoMessage:new { text = _("Unsupported Bluetooth action on this device"), timeout = 2, })
    end
end

--- Look up a previously-known Devices instance by mac address.
---@param mac string
---@return Devices|nil
function controller:getDevice(mac)
    logger.dbg("Looking up known device by MAC: " .. Parse.maskMac(mac))
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

--- Call right before bluetooth gets torn down for suspend. Records whether
--- the radio was on (so resume only restores a radio that was on), and, if
--- it was, refreshes device state one last time and snapshots it to disk -
--- bluetoothctl won't remember "was connected right before suspend" once
--- the radio's been power-cycled, so this is our only record.
--- With the radio off there is nothing to snapshot, and reading devices
--- would power it on (PocketBook), so it is skipped.
--- Takes a callback because knownDevices() can be async; persisting before
--- that finishes would risk writing stale `connected` values.
---@param callback fun()|nil
function controller:snapshotBeforeSuspend(callback)
    self:status()
    self.was_enabled_before_suspend = self.is_enabled
    if not self.is_enabled then
        logger.dbg("Bluetooth: radio is off at suspend, nothing to snapshot")
        if callback then callback() end
        return
    end

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
            logger.dbg("Bluetooth: reconnecting to " .. Parse.maskMac(mac) .. " on wake")
            dev:connect()
        else
            logger.warn("Bluetooth: stored device " .. Parse.maskMac(mac) .. " not found among known_devices, skipping wake reconnect")
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
--- The callback always fires exactly once: true if confirmed, false if it
--- timed out or a newer enable/disable superseded this call (the newer call
--- decides the final state). Dropping it silently left connect/scan waiting
--- forever after a suspend/resume.
---@param generation integer the poll generation this call belongs to, captured
---  by enable()/disable() at the moment they started polling. If a newer
---  enable()/disable() call has since bumped self._poll_generation, this
---  loop has been superseded and should stop quietly rather than keep
---  polling and firing its own (now-stale) callback alongside the new one.
local function pollField(self, field, expected, callback, attempt, generation)
    if generation ~= self._poll_generation then
        logger.dbg("Bluetooth: pollField for " .. field .. " superseded by a newer enable/disable call, stopping")
        if callback then callback(false) end
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
        if callback then callback(false) end
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

--- True while a disable() has been called and not yet confirmed or superseded.
--- The radio may still read as on in this window, but it is going off, so
--- nothing should talk to bluetoothd. Resume 1s after suspend hit this on
--- 2026-10-13: a device read ran mid-shutdown and KOReader stopped logging.
function controller:isDisabling()
    return self._disabling_generation ~= nil
        and self._disabling_generation == self._poll_generation
end

-- After a disable command has been sent, the next "on" must wait for the
-- radio to report off, or it races the shutdown. Gives up after the same
-- budget as pollField and sends anyway, since a stuck radio is worse.
local function waitForOff(self, generation, send, callback, attempt)
    if generation ~= self._poll_generation then
        if callback then callback(false) end
        return
    end
    attempt = attempt or 1
    self:status()
    if not self.is_enabled or attempt >= 10 then
        if self.is_enabled then
            logger.warn("Bluetooth: radio still on after disable, enabling anyway")
        end
        self._disable_sent = false
        return send()
    end
    UIManager:scheduleIn(1, function()
        waitForOff(self, generation, send, callback, attempt + 1)
    end)
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

    local function send()
        self:callDeviceFunction("enable")
        pollField(self, "is_enabled", true, callback, nil, my_generation)
    end

    UIManager:scheduleIn(ENABLE_DISABLE_DEBOUNCE_S, function()
        if my_generation ~= self._poll_generation then
            logger.dbg("Bluetooth: enable() superseded before its command was sent, skipping")
            if callback then callback(false) end
            return
        end
        if self._disable_sent then
            return waitForOff(self, my_generation, send, callback)
        end
        send()
    end)
end

function controller:disable(callback)
    logger.dbg("Disabling Bluetooth Controller")
    self._poll_generation = (self._poll_generation or 0) + 1
    local my_generation = self._poll_generation
    self._disabling_generation = my_generation

    local function done(confirmed)
        if self._disabling_generation == my_generation then
            self._disabling_generation = nil
        end
        if callback then callback(confirmed) end
    end

    UIManager:scheduleIn(ENABLE_DISABLE_DEBOUNCE_S, function()
        if my_generation ~= self._poll_generation then
            logger.dbg("Bluetooth: disable() superseded before its command was sent, skipping")
            return done(false)
        end
        self:callDeviceFunction("disable")
        self._disable_sent = true
        pollField(self, "is_enabled", false, function(confirmed)
            if confirmed then self._disable_sent = false end
            done(confirmed)
        end, nil, my_generation)
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

--- Rebuilds known_devices from the persisted store, for when the radio is
--- off. With the radio off there is no bluetoothd, so bluetoothctl returns
--- nothing at all (checked on the reader, 2026-10-13); the cache is the only
--- source. Nothing is connected while the radio is off.
--- Decision: Docs/Controller design in the vault ("Reads are pure").
---@return Devices[]
function controller:devicesFromStore()
    local list = {}
    if not (self.device_store and self.device_store.data) then
        return list
    end
    for mac, entry in pairs(self.device_store.data) do
        table.insert(list, Devices:new({
            mac = mac,
            name = entry.name,
            paired = entry.paired,
            bonded = entry.bonded,
            trusted = entry.trusted,
            blocked = entry.blocked,
            connected = false,
            starred = entry.starred,
            backend = self.backend,
            controller = self,
        }))
    end
    table.sort(list, function(x, y) return x.name < y.name end)
    return list
end

--- Refreshes self.known_devices. A read never changes the radio's power:
--- on PocketBook with the radio off it serves the cached list instead.
--- Explicit actions (connect, pair, scan) enable the radio themselves.
---
---@param callback fun(confirmed: boolean)|nil invoked exactly once
function controller:knownDevices(callback)
    logger.dbg("Refreshing known devices")

    local function refresh()
        local started = now()
        local previous = {}
        for _, dev in ipairs(self.known_devices or {}) do
            previous[dev.mac] = dev
        end

        self.known_devices = self:callDeviceFunction("knownDevices") or {}

        local queried = 0
        for _, dev in ipairs(self.known_devices) do
            -- Backends mark devices whose state they already know (unpaired
            -- scan results) so we don't spawn a process for each one.
            if not dev.skip_info then
                dev:refresh()
                queried = queried + 1
            end
        end

        -- Devices are rebuilt on every refresh, so changes show up as a
        -- difference from the previous list. This is what shows a device
        -- reconnecting by itself, see the 2026-10-13 session note.
        for _, dev in ipairs(self.known_devices) do
            local before = previous[dev.mac]
            if before then
                for _, field in ipairs({ "connected", "paired", "trusted", "blocked" }) do
                    if before[field] ~= dev[field] then
                        logger.info("Bluetooth: " .. field .. " of " .. Parse.maskMac(dev.mac) ..
                            " changed " .. tostring(before[field]) .. " -> " .. tostring(dev[field]))
                    end
                end
            end
        end

        logger.dbg(string.format("Bluetooth: refreshed %d devices (%d queried) in %.2fs",
            #self.known_devices, queried, now() - started))

        self:applyStoredDeviceState()
        return self.known_devices
    end

    if self.backend == backends.PocketBook then
        self:status()
        if not self.is_enabled or self:isDisabling() then
            self.known_devices = self:devicesFromStore()
            self:applyStoredDeviceState()
            logger.dbg(string.format("Bluetooth: radio off or going off, using %d cached devices", #self.known_devices))
            if callback then callback(true) end
            return self.known_devices
        end
    end

    refresh()
    -- Keep the cache current for the radio-off case, not just at suspend.
    self:persistDeviceState()
    if callback then callback(true) end
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
    logger.dbg("Fetching info for device with MAC: " .. Parse.maskMac(mac))
    return self:callDeviceFunction("info", mac)
end

return controller