--- Fast mode: BlueZ reads over D-Bus, everything else as in bluez.lua.
---
--- Inherits from Bluez and overrides only the reads, so scanning, pairing
--- and device actions still go through bluetoothctl. Scanning needs a client
--- that stays on the bus and pairing needs an agent, which a one-shot
--- `dbus-send` can be neither (tested 2026-10-13, see vault Docs/D-Bus findings).
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
--- timed out, as in Bluez.snapshotScript.
function BluezDbus:snapshotScript()
    return ("timeout -k 1 5 %s 2>&1\necho \"@@rc $?\"\n"):format(self:managedObjectsCommand())
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
        if BluezDbus.giveUp(err, msg) then return Parse.info(Bluez.info(self, mac)) end
        return nil
    end
    return DbusParse.device(path, props)
end

return BluezDbus
