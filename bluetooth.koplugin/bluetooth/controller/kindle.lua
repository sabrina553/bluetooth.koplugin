--- Kindle backend over lipc, against Kindle's own `com.lab126.btfd`.
---
--- Stock firmware pairs only audio devices; remotes need a one-time root
--- setup the plugin never does (decision 2026-10-28, vault Docs/Kindle backend
--- design). Power and state follow finlater/kindlebtcontroller.koplugin (MIT),
--- lists, scan and actions ZenOS (GPL-3.0); see CREDITS.md. Untested on a device.

local logger = require("logger")
local _ = require("gettext")
local Bluez = require("bluetooth/controller/bluez")
local Devices = require("bluetooth/controller/devices")
local Parse = require("bluetooth/controller/bluetoothctl_parse")
local KoboInput = require("bluetooth/keys/kobo_input")

local SERVICE = "com.lab126.btfd"
local LIPC_TIMEOUT_S = 2
local DEFAULT_SCAN_S = 15
local PAIR_TIMEOUT_S = 30
local PAIR_POLL_S = 2
-- finlater's setup guide creates these; both present means remotes can pair.
local UDEV_RULE = "/etc/udev/rules.d/99-bt-keyboard.rules"

local ADDRESS_KEYS = { "address", "Address", "addr", "mac", "MAC", "bdaddr", "BDAddr",
    "bd_address", "deviceAddress", "macAddress" }
local NAME_KEYS = { "name", "Name", "bd_name", "deviceName", "friendlyName" }

local Kindle = {
    SERVICE = SERVICE,
    capabilities = { trust = false, block = false, transport = false, info = false, address_pair = false },
}
Kindle.__index = Kindle

local function isMac(mac)
    return type(mac) == "string" and mac:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") ~= nil
end

local function shellOk(cmd)
    local ok, _, code = os.execute(cmd)
    return ok == true or ok == 0 or code == 0
end

--- The lipc calls, one table so tests can replace it. Ints and strings go
--- through the lipc-* tools (finlater); hashes need libopenlipclua (ZenOS).
Kindle.lipc = {
    getInt = function(prop)
        local out = Bluez.capture(("timeout %d lipc-get-prop -i %s %s 2>/dev/null"):format(LIPC_TIMEOUT_S, SERVICE, prop))
        return tonumber(out and out:match("%-?%d+"))
    end,
    setInt = function(prop, n)
        return shellOk(("timeout %d lipc-set-prop -i %s %s %d >/dev/null 2>&1"):format(LIPC_TIMEOUT_S, SERVICE, prop, n))
    end,
    -- A fixed value, so nothing caller-supplied reaches the shell.
    enable = function()
        return shellOk(("timeout %d lipc-set-prop -s %s BTenable 1:1 >/dev/null 2>&1"):format(LIPC_TIMEOUT_S, SERVICE))
    end,
    -- Every string property we set is an address, and it goes into a shell
    -- command unquoted: refuse anything else here, not only in the callers.
    setString = function(prop, s)
        if not isMac(s) then
            logger.warn("Kindle: refusing lipc " .. tostring(prop) .. ", not a MAC: " .. Parse.maskMac(tostring(s)))
            return false
        end
        return shellOk(("timeout %d lipc-set-prop -s %s %s %s >/dev/null 2>&1"):format(LIPC_TIMEOUT_S, SERVICE, prop, s))
    end,
    readHash = function(prop)
        local ok, lipc = pcall(require, "libopenlipclua")
        if not ok or type(lipc) ~= "table" or type(lipc.open_no_name) ~= "function" then
            logger.warn("Kindle: libopenlipclua unavailable")
            return nil
        end
        local opened, handle = pcall(lipc.open_no_name)
        if not opened or not handle then return nil end
        -- Kept outside the pcall so they are freed even when a read throws.
        local input, result
        local read_ok, values = pcall(function()
            input = handle:new_hasharray()
            result = handle:access_hash_property(SERVICE, prop, input)
            return result and result:to_table() or {}
        end)
        if result then pcall(result.destroy, result) end
        if input then pcall(input.destroy, input) end
        pcall(handle.close, handle)
        if not read_ok then
            logger.warn("Kindle: reading", prop, "failed:", Parse.maskMac(tostring(values)))
            return nil
        end
        return values
    end,
}

--- Whether this Kindle has had the one-time setup for remotes. Checked once:
--- it needs root, so it can't change while KOReader runs.
function Kindle.isPrepared()
    if Kindle._prepared == nil then
        local f = io.open(UDEV_RULE, "r")
        if f then f:close() end
        Kindle._prepared = f ~= nil and shellOk("command -v ace_bt_cli >/dev/null 2>&1")
        logger.info("Kindle: set up for remotes:", tostring(Kindle._prepared))
    end
    return Kindle._prepared
end

--- address_pair is looked up on demand: the controller builds every backend
--- at load on every device, and the setup check runs shell commands.
function Kindle:new(ctrl)
    local o = setmetatable({ controller = ctrl }, Kindle)
    o.capabilities = setmetatable({ trust = false, block = false, transport = false, info = false }, {
        __index = function(_, key)
            if key == "address_pair" then return Kindle.isPrepared() end
        end,
    })
    return o
end

function Kindle:status()
    local state = Kindle.lipc.getInt("BTstate")
    if state ~= Kindle.last_state then
        logger.info("Kindle: BTstate", tostring(state))
        Kindle.last_state = state
    end
    return state ~= nil and state ~= 0
end

function Kindle:enable()
    logger.dbg("Kindle: Enabling Bluetooth...")
    -- BTflightMode 0 only restores a state saved by BTflightMode 1: after
    -- btfd drops the radio on suspend there is none, and it does nothing
    -- (PW 5.17.1, 2026-11-11). BTenable turns it on either way.
    if not Kindle.lipc.enable() then
        Kindle.lipc.setInt("BTflightMode", 0)
    end
end

function Kindle:disable()
    logger.dbg("Kindle: Disabling Bluetooth...")
    Kindle.lipc.setInt("BTflightMode", 1)
end

local function firstOf(raw, keys)
    for _, key in ipairs(keys) do
        if raw[key] ~= nil then return raw[key] end
    end
end

--- Reads one list into `by_mac`; false when the read failed.
function Kindle:mergeList(prop, by_mac, order, flag)
    local list = Kindle.lipc.readHash(prop)
    if type(list) ~= "table" then return false end
    for _, raw in ipairs(list) do
        local mac = type(raw) == "table" and firstOf(raw, ADDRESS_KEYS)
        if isMac(mac) then
            mac = mac:upper()
            local dev = by_mac[mac]
            if not dev then
                local name = firstOf(raw, NAME_KEYS)
                dev = Devices:fromScan(mac, type(name) == "string" and name ~= "" and name or mac, self, self.controller)
                dev.skip_info = true
                by_mac[mac] = dev
                table.insert(order, dev)
            end
            if flag then dev[flag] = true end
        else
            -- Field names vary by firmware; a tester's log shows the real shape.
            local keys = {}
            if type(raw) == "table" then
                for k in pairs(raw) do table.insert(keys, tostring(k)) end
            end
            logger.warn("Kindle: unexpected", prop, "entry, keys:", table.concat(keys, ","))
        end
    end
    return true
end

--- Paired, connected and discovered lists merged by address; nil on a failed read.
function Kindle:knownDevices()
    local by_mac, order = {}, {}
    if not (self:mergeList("ListPaired", by_mac, order, "paired")
            and self:mergeList("ListConnected", by_mac, order, "connected")
            and self:mergeList("ListDiscovered", by_mac, order, nil)) then
        return nil
    end
    logger.dbg("Kindle: Found " .. #order .. " known devices")
    KoboInput.onDevices(order, Bluez.capture)
    return order
end

--- Typed state for Devices:refresh, from the paired and connected lists.
---@return table|nil
function Kindle:readInfo(mac)
    if not isMac(mac) then return nil end
    local function inList(prop)
        local list = Kindle.lipc.readHash(prop)
        if type(list) ~= "table" then return nil end
        for _, raw in ipairs(list) do
            local addr = type(raw) == "table" and firstOf(raw, ADDRESS_KEYS)
            if type(addr) == "string" and addr:upper() == mac:upper() then return true end
        end
        return false
    end
    local paired, connected = inList("ListPaired"), inList("ListConnected")
    if paired == nil or connected == nil then return nil end
    return { paired = paired, bonded = paired, connected = connected, trusted = false, blocked = false }
end

function Kindle:isPaired(mac)
    local info = self:readInfo(mac)
    return info ~= nil and info.paired
end

function Kindle:readSnapshot(done)
    done(self:knownDevices())
end

function Kindle:action(prop, mac)
    if not isMac(mac) then
        logger.warn("Kindle: not a MAC for " .. prop .. ": " .. Parse.maskMac(tostring(mac)))
        return
    end
    logger.dbg("Kindle: " .. prop .. " " .. Parse.maskMac(mac))
    Kindle.lipc.setString(prop, mac)
end

--- Then opens the remote's input device, as on Kobo: finlater opens it the
--- same way, with Device.input:open.
function Kindle:connect(mac)
    self:action("Connect", mac)
    if isMac(mac) then KoboInput.openLater(Bluez.capture) end
end
function Kindle:disconnect(mac) self:action("Disconnect", mac) end
function Kindle:unpair(mac) self:action("Unbond", mac) end

--- A2DP discovery: Kindle's own scan, built for headphones.
function Kindle:search(duration)
    duration = duration or DEFAULT_SCAN_S
    local UIManager = require("ui/uimanager")
    if Kindle.scan_timer then UIManager:unschedule(Kindle.scan_timer) end
    Kindle.lipc.setInt("DiscoverA2DP", 1)
    Kindle.scan_timer = function()
        Kindle.scan_timer = nil
        Kindle.lipc.setInt("DiscoverA2DP", 0)
    end
    UIManager:scheduleIn(duration, Kindle.scan_timer)
end

--- ace_bt_cli on a Kindle set up for remotes, Bond (headphones) otherwise.
--- Success is the address in the paired list either way: neither tool's
--- output is documented (decision 2026-10-28).
---@return boolean, string|nil
function Kindle:pair(mac, on_done)
    if not isMac(mac) then
        logger.warn("Kindle: not pairing, not a MAC: " .. Parse.maskMac(tostring(mac)))
        return false, "invalid"
    end
    local function finish(ok)
        if ok then
            logger.info("Kindle: paired " .. Parse.maskMac(mac))
        else
            logger.warn("Kindle: pairing " .. Parse.maskMac(mac) .. " failed")
        end
        if on_done then on_done(ok) end
    end
    if Kindle.isPrepared() then
        local script = ("printf 'pair %s\\nquit\\n' | %sace_bt_cli 2>&1\n"):format(mac, Bluez.timeoutPrefix(PAIR_TIMEOUT_S))
        Bluez.runAsync(script, function()
            finish(self:isPaired(mac))
        end)
        return true
    end
    Kindle.lipc.setString("Bond", mac)
    local UIManager = require("ui/uimanager")
    local polls_left = math.floor(PAIR_TIMEOUT_S / PAIR_POLL_S)
    local function poll()
        if self:isPaired(mac) then return finish(true) end
        polls_left = polls_left - 1
        if polls_left <= 0 then return finish(false) end
        UIManager:scheduleIn(PAIR_POLL_S, poll)
    end
    UIManager:scheduleIn(PAIR_POLL_S, poll)
    return true
end

--- Shown after a failed pairing; nil once the Kindle is set up for remotes.
function Kindle:pairFailedHint()
    if Kindle.isPrepared() then return nil end
    return _("Couldn't pair. Remotes and keyboards need a one-time setup on Kindle: see \"Kindle\" in the plugin's README. Headphones: put them in pairing mode and try again.")
end

return Kindle
