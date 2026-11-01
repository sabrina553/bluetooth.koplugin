--- Fast mode: BlueZ reads and device actions over D-Bus, the rest as in
--- bluez.lua.
---
--- Inherits from Bluez and overrides reads and device actions (connect,
--- disconnect, trust, block, unpair), so scanning and pairing still go
--- through bluetoothctl. Scanning needs a client that stays on the bus and
--- pairing needs an agent, which a one-shot `dbus-send` can be neither
--- (tested 2026-10-13, see vault Docs/D-Bus findings).
---
--- If D-Bus answers in a way that means it can't work here (access denied,
--- a reply we can't parse), the session falls back to Compatible mode and
--- the same read is retried through bluetoothctl.

local logger = require("logger")
local Bluez = require("bluetooth/controller/bluez")
local Dbus = require("bluetooth/controller/dbus")
local DbusParse = require("bluetooth/controller/dbus_parse")
local Devices = require("bluetooth/controller/devices")
local Parse = require("bluetooth/controller/bluetoothctl_parse")

local BluezDbus = setmetatable({
    service = "org.bluez",
    adapter = "/org/bluez/hci0",
}, { __index = Bluez })
BluezDbus.__index = BluezDbus

function BluezDbus:new(ctrl)
    return setmetatable({ controller = ctrl }, BluezDbus)
end

-- Errors that mean "no answer this time", not "D-Bus doesn't work here".
-- ServiceUnknown is what a radio that is off looks like: no bluetoothd.
local TRANSIENT = {
    ["org.freedesktop.DBus.Error.ServiceUnknown"] = true,
    ["org.freedesktop.DBus.Error.NameHasNoOwner"] = true,
    ["org.freedesktop.DBus.Error.NoReply"] = true,
    ["org.freedesktop.DBus.Error.Timeout"] = true,
    ["org.freedesktop.DBus.Error.UnknownObject"] = true,
}

--- True when an error means Fast mode can't work in this session, and
--- switches to Compatible. Anything from bluetoothd itself (org.bluez.Error.*)
--- means D-Bus works, so only the call failed.
---@param err string|nil
---@param msg string|nil
---@return boolean
function BluezDbus.giveUp(err, msg)
    if err == nil or TRANSIENT[err] or err:find("^org%.bluez%.Error%.") then
        return false
    end
    BluezDbus.broken = err
    logger.warn("BluezDbus: switching to Compatible mode for this session:", err, Parse.maskMac(msg))
    return true
end

--- Whether this session gave up on D-Bus (see giveUp). Cleared when the user
--- picks a mode again, so choosing Fast retries it.
function BluezDbus.isBroken()
    return BluezDbus.broken ~= nil
end

function BluezDbus.reset()
    BluezDbus.broken = nil
end

function BluezDbus:command(path, method, ...)
    return Dbus.command(self.service, path, method, ...)
end

function BluezDbus:managedObjectsCommand()
    return self:command("/", "org.freedesktop.DBus.ObjectManager.GetManagedObjects")
end

--- Devices from a GetManagedObjects result. Every device comes with its full
--- state, so all are marked `skip_info`: no per-device reads afterwards.
function BluezDbus:devicesFrom(objects)
    local devices = {}
    for _, info in ipairs(objects.devices) do
        local dev = Devices:fromScan(info.mac, info.name or "Unknown", self, self.controller)
        dev:applyInfo(info)
        dev.skip_info = true
        table.insert(devices, dev)
    end
    logger.dbg("BluezDbus: Found " .. #devices .. " known devices")
    return devices
end

function BluezDbus:status()
    if BluezDbus.broken then return Bluez.status(self) end
    local output = self.capture(self:command(self.adapter, "org.freedesktop.DBus.Properties.Get",
        "string:org.bluez.Adapter1", "string:Powered"))
    if Bluez.lastTimedOut() then
        logger.warn("BluezDbus: power state read timed out")
        return false
    end
    local powered, err, msg = DbusParse.property(output)
    if powered == nil then
        if BluezDbus.giveUp(err, msg) then return Bluez.status(self) end
        -- No bluetoothd answers while the radio is off.
        logger.dbg("BluezDbus: no power state (" .. tostring(err) .. "), reading as off")
        return false
    end
    return powered == true
end

--- Blocking read, as Bluez:knownDevices(): nil on a failed read.
function BluezDbus:knownDevices()
    if BluezDbus.broken then return Bluez.knownDevices(self) end
    local output = self.capture(self:managedObjectsCommand())
    if Bluez.lastTimedOut() then
        logger.warn("BluezDbus: listing devices timed out")
        return nil
    end
    local objects, err, msg = DbusParse.managedObjects(output)
    if not objects then
        if BluezDbus.giveUp(err, msg) then return Bluez.knownDevices(self) end
        logger.warn("BluezDbus: could not list devices:", err)
        return nil
    end
    return self:devicesFrom(objects)
end

--- One dbus-send with its exit status after it, so a killed call reads as
--- timed out, as in Bluez.snapshotScript. The prefix follows the detected
--- timeout style: BusyBox 1.22 rejects -k (crash.log 2026-10-18).
function BluezDbus:snapshotScript()
    return ("%s%s 2>&1\necho \"@@rc $?\"\n"):format(Bluez.timeoutPrefix(5), self:managedObjectsCommand())
end

--- Background read, as Bluez:readSnapshot(): done(devices), or done(nil).
---@param done fun(devices: table|nil)
function BluezDbus:readSnapshot(done)
    if BluezDbus.broken then return Bluez.readSnapshot(self, done) end
    Bluez.runAsync(self:snapshotScript(), function(text)
        local rc = text and tonumber(text:match("@@rc (%d+)%s*$"))
        if rc == nil or rc == 124 or rc == 143 or rc == 137 then
            logger.warn("BluezDbus: background read timed out")
            return done(nil)
        end
        local objects, err, msg = DbusParse.managedObjects((text:gsub("@@rc %d+%s*$", "")))
        if not objects then
            if BluezDbus.giveUp(err, msg) then return Bluez.readSnapshot(self, done) end
            logger.warn("BluezDbus: could not list devices:", err)
            return done(nil)
        end
        done(self:devicesFrom(objects))
    end)
end

-- Errors that mean the action was already done or is under way, so they are
-- not failures; the caller's poll confirms. InProgress: right after pairing,
-- BlueZ is already connecting (reader log 2026-10-26 10:48:52).
local ALREADY_DONE = {
    ["org.bluez.Error.AlreadyConnected"] = true,
    ["org.bluez.Error.InProgress"] = true,
    ["org.bluez.Error.NotConnected"] = true,
    ["org.bluez.Error.DoesNotExist"] = true,
}

-- Seconds. Connect took 4.4 s on the reader and goes on inside bluetoothd
-- after dbus-send stops waiting, so it gets room to report its own error.
local CONNECT_REPLY_MS = 10000
local ACTION_TIMEOUT_S = 5

--- Runs one device action in the background, as bluetoothctl actions do;
--- the caller's poll confirms the result. Errors are logged by name. Ones
--- that mean D-Bus can't work here switch to Compatible and redo the action
--- through bluetoothctl (`fallback`).
---@param label string for the log, e.g. "Connecting to"
---@param mac string
---@param fallback fun() the same action through Bluez
---@param build fun(path: string): string|nil the dbus-send command
---@param timeout_s integer|nil
function BluezDbus:action(label, mac, fallback, build, timeout_s)
    local path = Dbus.devicePath(self.adapter, mac)
    local cmd = path and not BluezDbus.broken and build(path)
    if not cmd then return fallback() end
    timeout_s = timeout_s or ACTION_TIMEOUT_S
    logger.dbg("BluezDbus: " .. label .. " Bluetooth device: " .. Parse.maskMac(mac))
    local script = ("%s%s 2>&1\necho \"@@rc $?\"\n"):format(Bluez.timeoutPrefix(timeout_s), cmd)
    Bluez.runAsync(script, function(text)
        local rc = text and tonumber(text:match("@@rc (%d+)%s*$"))
        if rc == nil or rc == 124 or rc == 143 or rc == 137 then
            logger.warn("BluezDbus: " .. label .. " " .. Parse.maskMac(mac) .. " timed out")
            return
        end
        local _, err, msg = DbusParse.reply((text:gsub("@@rc %d+%s*$", "")))
        if not err then return end
        if ALREADY_DONE[err] then
            logger.dbg("BluezDbus: " .. label .. " " .. Parse.maskMac(mac) .. ": already done (" .. err .. ")")
        elseif BluezDbus.giveUp(err, msg) then
            fallback()
        else
            logger.warn("BluezDbus: " .. label .. " " .. Parse.maskMac(mac) .. " failed:", err, Parse.maskMac(msg))
        end
    end)
end

function BluezDbus:connect(mac)
    self:action("Connecting to", mac, function() Bluez.connect(self, mac) end, function(path)
        return Dbus.commandWithTimeout(CONNECT_REPLY_MS, self.service, path, "org.bluez.Device1.Connect")
    end, math.ceil(CONNECT_REPLY_MS / 1000) + 2)
end

function BluezDbus:disconnect(mac)
    self:action("Disconnecting from", mac, function() Bluez.disconnect(self, mac) end, function(path)
        return self:command(path, "org.bluez.Device1.Disconnect")
    end)
end

--- Device1 boolean properties (Trusted, Blocked) via Properties.Set; both
--- checked on the reader 2026-10-13.
function BluezDbus:setDeviceFlag(label, mac, property, value, fallback)
    self:action(label, mac, fallback, function(path)
        return self:command(path, "org.freedesktop.DBus.Properties.Set",
            "string:org.bluez.Device1", "string:" .. property, "variant:boolean:" .. tostring(value))
    end)
end

function BluezDbus:trust(mac)
    self:setDeviceFlag("Trusting", mac, "Trusted", true, function() Bluez.trust(self, mac) end)
end

function BluezDbus:untrust(mac)
    self:setDeviceFlag("Untrusting", mac, "Trusted", false, function() Bluez.untrust(self, mac) end)
end

function BluezDbus:block(mac)
    self:setDeviceFlag("Blocking", mac, "Blocked", true, function() Bluez.block(self, mac) end)
end

function BluezDbus:unblock(mac)
    self:setDeviceFlag("Unblocking", mac, "Blocked", false, function() Bluez.unblock(self, mac) end)
end

--- Adapter1.RemoveDevice, as `bluetoothctl remove`. A second remove answers
--- DoesNotExist, which counts as done.
function BluezDbus:unpair(mac)
    self:action("Removing", mac, function() Bluez.unpair(self, mac) end, function(path)
        return self:command(self.adapter, "org.bluez.Adapter1.RemoveDevice", "objpath:" .. path)
    end)
end

--- One device's state, in the shape of Parse.info, or nil on a failed read.
--- Used by Devices:refresh, which the connect poll runs every second.
---@param mac string
---@return table|nil
function BluezDbus:readInfo(mac)
    local path = Dbus.devicePath(self.adapter, mac)
    if BluezDbus.broken or not path then
        return Parse.info(Bluez.info(self, mac))
    end
    local output = self.capture(self:command(path, "org.freedesktop.DBus.Properties.GetAll",
        "string:org.bluez.Device1"))
    if Bluez.lastTimedOut() then
        return nil
    end
    local props, err, msg = DbusParse.properties(output)
    if not props then
        -- bluetoothd answered, but has no such device: it was removed. Read
        -- as unpaired, as bluetoothctl's "not available" is, or the unpair
        -- poll never confirms (reader log 2026-10-26 09:34). A radio that is
        -- off answers ServiceUnknown instead.
        if err == "org.freedesktop.DBus.Error.UnknownObject" then
            return { mac = mac, paired = false, bonded = false, trusted = false, blocked = false, connected = false }
        end
        if BluezDbus.giveUp(err, msg) then return Parse.info(Bluez.info(self, mac)) end
        return nil
    end
    return DbusParse.device(path, props)
end

return BluezDbus
