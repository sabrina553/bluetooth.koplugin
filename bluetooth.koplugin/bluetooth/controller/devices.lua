local logger = require("logger")
local UIManager = require("ui/uimanager")

local Parse = require("bluetooth/controller/bluetoothctl_parse")
local Standby = require("bluetooth/standby")
local Poll = require("bluetooth/controller/poll")

---@class Devices
---@field mac string
---@field name string
---@field paired boolean
---@field bonded boolean
---@field trusted boolean
---@field blocked boolean
---@field connected boolean
---@field starred boolean
---@field held boolean Disconnected by hand: wake skips it until it is connected by hand
---@field controller any
---@field backend any The platform backend (Bluez, PocketBook, ...) used to actually talk to hardware
local Devices = {}
Devices.__index = Devices

--- Create a new device.
--- o.backend should be the platform controller (e.g. Bluez) that knows how
--- to actually pair/connect/etc. This lets a Devices instance perform its
--- own actions without the caller needing to know which platform it's on.
function Devices:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    o:init()
    return o
end

function Devices:init()
    self.mac = self.mac or ""
    self.name = self.name or ""
    self.paired = self.paired or false
    self.bonded = self.bonded or false
    self.trusted = self.trusted or false
    self.blocked = self.blocked or false
    self.connected = self.connected or false
    self.starred = self.starred or false
    self.held = self.held or false
    self.backend = self.backend
end

--@field controller any
function Devices:fromScan(mac, name, backend, ctrl)
    return Devices:new({ mac = mac, name = name, backend = backend, controller = ctrl })
end

function Devices:parseInfo(output)
    return self:applyInfo(Parse.info(output))
end

--- State in the shape of Parse.info, from either backend.
function Devices:applyInfo(info)
    self.mac = info.mac or self.mac
    self.name = info.name or self.name
    self.paired = info.paired
    self.bonded = info.bonded
    self.trusted = info.trusted
    self.blocked = info.blocked
    self.connected = info.connected
    return self
end

function Devices:refresh()
    if not self.backend or not self.backend.info then
        logger.warn("Devices:refresh called with no backend set on device " .. Parse.maskMac(self.mac))
        return self
    end

    -- Fast mode reads typed state over D-Bus; Compatible parses bluetoothctl.
    if self.backend.readInfo then
        local info = self.backend:readInfo(self.mac)
        if info then
            self:applyInfo(info)
        end
        return self
    end

    local output = self.backend:info(self.mac)
    if output then
        self:parseInfo(output)
    end

    return self
end

--- Polls `refresh()` on a timer until self.field == expected, or gives up.
---@param expected boolean
---@param callback fun(confirmed: boolean)|nil called once, with true if state was confirmed
---@param attempt integer|nil internal, do not pass
---@param max_attempts integer|nil defaults to Poll.MAX_ATTEMPTS
---@param stopped (fun(): boolean)|nil when true, the answer came another way: stop quietly
local function pollField(self, field, expected, callback, attempt, release, max_attempts, stopped)
    attempt = attempt or 1
    -- Held from the first check to the final answer, see bluetooth/standby.lua.
    release = release or Standby.hold()
    max_attempts = max_attempts or Poll.MAX_ATTEMPTS
    if stopped and stopped() then
        release()
        return
    end

    self:refresh()

    if self[field] == expected then
        logger.dbg("Devices: " .. field .. " of " .. Parse.maskMac(self.mac) ..
            " is " .. tostring(expected) .. " after " .. attempt .. " check(s)")
        release()
        if callback then callback(true) end
        return
    end

    if attempt >= max_attempts then
        logger.warn("Devices: could not confirm " .. field .. " state for " .. Parse.maskMac(self.mac))
        release()
        if callback then callback(false) end
        return
    end

    UIManager:scheduleIn(Poll.delay(attempt), function()
        pollField(self, field, expected, callback, attempt + 1, release, max_attempts, stopped)
    end)
end

function Devices:connect(callback)
    if not self.backend then
        logger.warn("Devices: connect called with no backend set on device " .. Parse.maskMac(self.mac))
        if callback then callback(false) end
        return
    end

    if not self.controller then
        logger.warn("Devices: connect called with no controller set on device " .. Parse.maskMac(self.mac))
        if callback then callback(false) end
        return
    end

    self.controller:enableWhenDisabled(function(enabled_confirmed)
        if not enabled_confirmed then
            if callback then callback(false) end
            return
        end

        self.backend:connect(self.mac)
        pollField(self, "connected", true, callback)
    end)
end

function Devices:disconnect(callback)
    if not self.backend then
        logger.warn("Devices:disconnect called with no backend set on device " .. Parse.maskMac(self.mac))
        if callback then callback(false) end
        return
    end
    if not self.connected then
        if callback then callback(true) end
        return
    end

    self.backend:disconnect(self.mac)
    pollField(self, "connected", false, callback)
end

--- Manual disconnect. Held is set first and from intent, so a suspend
--- mid-action still skips the device on wake, and a failed untrust or
--- disconnect does not undo what the user asked for. Untrust comes before
--- the disconnect, or a trusted device can reconnect in the gap.
--- Decision: vault Docs/Controller design, "Stage 3 plan" (2026-10-13).
function Devices:disconnectAndHold(callback)
    self.held = true
    if self.controller then self.controller:setHeld(self.mac, true) end
    self:untrust(function(untrusted)
        if not untrusted then
            logger.warn("Devices: could not untrust " .. Parse.maskMac(self.mac) .. ", disconnecting anyway")
        end
        self:disconnect(callback)
    end)
end

--- Manual connect: releases the hold and trusts again, so the device
--- reconnects by itself as before. A failed trust still connects; the toast
--- reports the connect.
function Devices:trustAndConnect(callback)
    if not self.controller then
        return self:connect(callback)
    end
    self.held = false
    self.controller:setHeld(self.mac, false)
    self.controller:enableWhenDisabled(function(enabled_confirmed)
        if not enabled_confirmed then
            if callback then callback(false) end
            return
        end
        self:trust(function(trusted)
            if not trusted then
                logger.warn("Devices: could not trust " .. Parse.maskMac(self.mac) .. ", connecting anyway")
            end
            self:connect(callback)
        end)
    end)
end

--- Only the menu calls this, so it is the manual path; wake uses connect().
function Devices:toggleConnection(callback)
    if self.connected then
        return self:disconnectAndHold(callback)
    else
        return self:trustAndConnect(callback)
    end
end

function Devices:pair(callback)
    if not self.backend then
        logger.warn("Devices:pair called with no backend set on device " .. Parse.maskMac(self.mac))
        if callback then callback(false) end
        return
    end
    if self.paired then
        if callback then callback(false) end
        return
    end
    if not self.controller then
        logger.warn("Devices:pair called with no controller set on device " .. Parse.maskMac(self.mac))
        if callback then callback(false) end
        return
    end

    self.controller:enableWhenDisabled(function(enabled_confirmed)
        if not enabled_confirmed then
            if callback then callback(false) end
            return
        end
        -- The first answer wins: the session's own result (a failure is
        -- known within a second, not after the whole confirm budget) or the
        -- paired poll. Only an explicit false from pair() means "not
        -- started" (another session is running).
        local settled = false
        local function settle(ok, reason)
            if settled then return end
            settled = true
            if not ok then
                if callback then callback(false, reason) end
                return
            end
            self:connect(function(connected_confirmed)
                if not connected_confirmed then
                    if callback then callback(false) end
                    return
                end
                self:trust(callback)
            end)
        end
        local started = self.backend:pair(self.mac, function(result)
            if result == false then
                logger.info("Devices: pairing " .. Parse.maskMac(self.mac) .. " failed, see the pair session lines")
                settle(false)
            end
        end)
        if started == false then
            settled = true
            if callback then callback(false, "busy") end
            return
        end
        -- Stops once the session has answered, or it would warn "could not
        -- confirm" long after the failure was shown (reader log 10:48:20).
        pollField(self, "paired", true, function(paired_confirmed)
            settle(paired_confirmed)
        end, nil, nil, Poll.PAIR_ATTEMPTS, function() return settled end)
    end)
end

function Devices:unpair(callback)
    if not self.backend then
        logger.warn("Devices:unpair called with no backend set on device " .. Parse.maskMac(self.mac))
        if callback then callback(false) end
        return
    end

    if not self.paired then
        if callback then callback(false) end
        return
    end

    self.backend:unpair(self.mac)
    pollField(self, "paired", false, callback)
end

function Devices:togglePair(callback)
    if self.paired then
        return self:unpair(callback)
    else
        return self:pair(callback)
    end
end

function Devices:trust(callback)
    if not self.backend then
        logger.warn("Devices:trust called with no backend set on device " .. Parse.maskMac(self.mac))
        if callback then callback(false) end
        return
    end
    if self.trusted then
        if callback then callback(true) end
        return
    end

    self.backend:trust(self.mac)
    pollField(self, "trusted", true, callback)
end

function Devices:untrust(callback)
    if not self.backend then
        logger.warn("Devices:untrust called with no backend set on device " .. Parse.maskMac(self.mac))
        if callback then callback(false) end
        return
    end

    -- Already in the asked-for state counts as done, as in trust().
    if not self.trusted then
        if callback then callback(true) end
        return
    end

    self.backend:untrust(self.mac)
    pollField(self, "trusted", false, callback)
end

function Devices:toggleTrust(callback)
    if self.trusted then
        return self:untrust(callback)
    else
        return self:trust(callback)
    end
end

function Devices:block(callback)
    if not self.backend then
        logger.warn("Devices:block called with no backend set on device " .. Parse.maskMac(self.mac))
        if callback then callback(false) end
        return
    end
    if self.blocked then
        if callback then callback(true) end
        return
    end

    self.backend:block(self.mac)
    pollField(self, "blocked", true, callback)
end

function Devices:unblock(callback)
    if not self.backend then
        logger.warn("Devices:unblock called with no backend set on device " .. Parse.maskMac(self.mac))
        if callback then callback(false) end
        return
    end
    if not self.blocked then
        if callback then callback(false) end
        return
    end

    self.backend:unblock(self.mac)
    pollField(self, "blocked", false, callback)
end

function Devices:toggleBlock(callback)
    if self.blocked then
        return self:unblock(callback)
    else
        return self:block(callback)
    end
end

--- Stars/unstars this device. Starring is pure app-level state — bluetoothctl
--- has no concept of it. Multiple devices may be starred at once: this only
--- ever touches this device's own flag and asks the controller to persist;
--- it never affects any other device's starred state.
function Devices:setStarred(starred, callback)
    if not self.controller then
        logger.warn("Devices:setStarred called with no controller set on device " .. Parse.maskMac(self.mac))
        if callback then callback(false) end
        return
    end

    self.starred = starred
    -- The menu re-reads the list every few seconds, so self may be an older
    -- copy than the one that gets saved; star the live one too or the save
    -- writes the old value (lost stars on the reader, 2026-10-19).
    local live = self.controller:getDevice(self.mac)
    if live and live ~= self then
        live.starred = starred
    end
    self.controller:persistDeviceState()

    if callback then callback(true) end
end

function Devices:toggleStar(callback)
    return self:setStarred(not self.starred, callback)
end

return Devices