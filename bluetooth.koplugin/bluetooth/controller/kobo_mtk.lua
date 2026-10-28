--- Kobo MTK backend (Libra Colour, Clara BW/Colour, Tolino Shine 5).
---
--- Kobo's own `com.kobo.mtk.bluedroid` service speaks the BlueZ Adapter1 and
--- Device1 interfaces, so reads and device actions come from BluezDbus. Power,
--- scan and pairing differ, and there is no bluetoothctl to fall back to.
--- Sequences adapted from ZenOS (GPL-3.0), see CREDITS.md; untested on a
--- device (decision 2026-10-28, vault Docs/Kobo MTK backend design).

local logger = require("logger")
local Bluez = require("bluetooth/controller/bluez")
local BluezDbus = require("bluetooth/controller/bluez_dbus")
local Dbus = require("bluetooth/controller/dbus")
local DbusParse = require("bluetooth/controller/dbus_parse")
local Parse = require("bluetooth/controller/bluetoothctl_parse")
local KoboInput = require("bluetooth/keys/kobo_input")

local KoboMTK = setmetatable({
    service = "com.kobo.mtk.bluedroid",
    -- info is bluetoothctl's; readInfo still reads details over D-Bus.
    capabilities = { trust = true, block = true, transport = false, info = false },
    -- Set once the service has been seen running this session, whoever
    -- started it: quitting to Nickel then needs a reboot (KOReader #12739).
    used = false,
}, { __index = BluezDbus })
KoboMTK.__index = KoboMTK
KoboMTK.SERVICE = KoboMTK.service

local MANAGER = "com.kobo.bluetooth.BluedroidManager1"
-- Bluetooth only starts while Wi-Fi is on (shared chip); ZenOS waits 1 s.
local WIFI_SETTLE_S = 1
local POWER_TIMEOUT_S = 20
local PAIR_TIMEOUT_S = 30
local DEFAULT_SCAN_S = 10

function KoboMTK:new(ctrl)
    return setmetatable({ controller = ctrl }, KoboMTK)
end

--- Lazily, so tests can set it and other devices never load it.
function KoboMTK:networkManager()
    KoboMTK.network = KoboMTK.network or require("ui/network/manager")
    return KoboMTK.network
end

function KoboMTK:fallenBack()
    return false
end

function KoboMTK:hasBluetoothctl()
    return false
end

function KoboMTK:shouldFallBack(err, msg)
    logger.warn("KoboMTK: D-Bus call failed:", tostring(err), Parse.maskMac(msg))
    return false
end

--- Not owned means Kobo's Bluetooth service isn't running, so the radio is off.
function KoboMTK:status()
    local owner = DbusParse.property(self.capture(Dbus.command("org.freedesktop.DBus",
        "/org/freedesktop/DBus", "org.freedesktop.DBus.NameHasOwner", "string:" .. self.service)))
    local powered = false
    if owner == true then
        KoboMTK.used = true
        powered = BluezDbus.status(self)
    end
    local state = tostring(owner) .. "/" .. tostring(powered)
    if state ~= KoboMTK.last_state then
        logger.info("KoboMTK: service owned/powered:", state)
        KoboMTK.last_state = state
    end
    return powered
end

local function setPowered(service, adapter, value)
    return Dbus.command(service, adapter, "org.freedesktop.DBus.Properties.Set",
        "string:org.bluez.Adapter1", "string:Powered", "variant:boolean:" .. tostring(value))
end

--- Runs a power script in the background and logs how it ended.
function KoboMTK:runPower(label, script, done)
    script = script .. 'echo "@@rc $?"\n'
    Bluez.runAsync(script, function(text)
        local rc = text and tonumber(text:match("@@rc (%d+)%s*$"))
        if rc == 0 then
            logger.info("KoboMTK: " .. label .. " done")
        else
            logger.warn("KoboMTK: " .. label .. " failed:", tostring(text and text:gsub("%s+", " ")))
        end
        if done then done(rc == 0) end
    end)
end

function KoboMTK:powerOn(done)
    local t = Bluez.timeoutPrefix(POWER_TIMEOUT_S)
    local on = Dbus.command(self.service, "/", MANAGER .. ".On")
    local off = Dbus.command(self.service, "/", MANAGER .. ".Off")
    -- If Powered can't be set, stop the service again rather than leave it half up.
    local script = ("%s%s >/dev/null 2>&1 || exit 1\n%s%s >/dev/null 2>&1 || { echo '@@failed powered'; %s%s >/dev/null 2>&1; false; }\n")
        :format(t, on, t, setPowered(self.service, self.adapter, true), t, off)
    self:runPower("power on", script, done)
end

--- Switches Wi-Fi on for the power-up if it was off, then off again
--- (decision 2026-10-28: silently, no prompt).
--- A second enable while one is under way is ignored: its Wi-Fi off would
--- otherwise land in the middle of the other's power-up.
function KoboMTK:enable()
    if KoboMTK.enabling then
        logger.info("KoboMTK: already powering on, ignoring enable")
        return
    end
    KoboMTK.enabling = true
    logger.dbg("KoboMTK: Enabling Bluetooth...")
    local network = self:networkManager()
    if network:isWifiOn() then
        return self:powerOn(function() KoboMTK.enabling = false end)
    end
    logger.info("KoboMTK: Wi-Fi off, switching it on for the power-up")
    network:restoreWifiAsync()
    local UIManager = require("ui/uimanager")
    UIManager:scheduleIn(WIFI_SETTLE_S, function()
        self:powerOn(function()
            KoboMTK.enabling = false
            logger.info("KoboMTK: switching Wi-Fi off again")
            network:disableWifi(nil, false)
        end)
    end)
end

function KoboMTK:disable()
    logger.dbg("KoboMTK: Disabling Bluetooth...")
    local t = Bluez.timeoutPrefix(POWER_TIMEOUT_S)
    local script = ("%s%s >/dev/null 2>&1\n%s%s >/dev/null 2>&1\n")
        :format(t, setPowered(self.service, self.adapter, false), t, Dbus.command(self.service, "/", MANAGER .. ".Off"))
    self:runPower("power off", script)
end

--- A one-shot dbus-send keeps discovery running on Kobo's service (unlike
--- bluetoothd), so it is stopped on a timer.
function KoboMTK:search(duration)
    duration = duration or DEFAULT_SCAN_S
    logger.dbg("KoboMTK: scanning for " .. duration .. "s")
    self.capture(self:command(self.adapter, "org.bluez.Adapter1.StartDiscovery"))
    local UIManager = require("ui/uimanager")
    UIManager:scheduleIn(duration, function()
        self.capture(self:command(self.adapter, "org.bluez.Adapter1.StopDiscovery"))
    end)
end

--- Connects as BluezDbus does, then opens the remote's input device once it
--- appears (see kobo_input.lua).
function KoboMTK:connect(mac)
    BluezDbus.connect(self, mac)
    KoboInput.openLater(self.capture)
end

function KoboMTK:devicesFrom(objects)
    local devices = BluezDbus.devicesFrom(self, objects)
    KoboInput.onDevices(devices, self.capture)
    return devices
end

--- Agentless Device1.Pair: remotes and keyboards, not PIN devices (decision
--- 2026-10-28). Same return and on_done shape as bluez:pair.
---@param mac string
---@param on_done fun(result: boolean|nil)|nil
---@return boolean, string|nil
function KoboMTK:pair(mac, on_done)
    local path = Dbus.devicePath(self.adapter, mac)
    if not path then
        logger.warn("KoboMTK: not pairing, not a MAC: " .. Parse.maskMac(tostring(mac)))
        return false, "invalid"
    end
    local cmd = Dbus.commandWithTimeout(PAIR_TIMEOUT_S * 1000, self.service, path, "org.bluez.Device1.Pair")
    logger.dbg("KoboMTK: pairing with " .. Parse.maskMac(mac))
    local script = ("%s%s 2>&1\necho \"@@rc $?\"\n"):format(Bluez.timeoutPrefix(PAIR_TIMEOUT_S + 5), cmd)
    Bluez.runAsync(script, function(text)
        local rc = text and tonumber(text:match("@@rc (%d+)%s*$"))
        local _, err, msg = DbusParse.reply(text and text:gsub("@@rc %d+%s*$", "") or "")
        local ok = rc == 0 and err == nil
        if ok then
            logger.info("KoboMTK: paired " .. Parse.maskMac(mac))
        else
            logger.warn("KoboMTK: pairing " .. Parse.maskMac(mac) .. " failed:", tostring(err or rc), Parse.maskMac(msg))
        end
        if on_done then on_done(ok) end
    end)
    return true
end

return KoboMTK
