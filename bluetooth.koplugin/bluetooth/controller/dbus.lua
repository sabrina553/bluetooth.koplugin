--- Builds `dbus-send` command lines for the system bus.
---
--- Pure Lua apart from `available()`, so it can be tested with plain luajit.
--- The service name is a parameter: `org.bluez` today, Kobo MTK's
--- `com.kobo.mtk.bluedroid` later (see vault Docs/D-Bus backend plan).

local Dbus = {}

-- Shorter than the 5 s capture timeout around it, so a slow bluetoothd comes
-- back as a NoReply error we can read rather than a killed process.
Dbus.REPLY_TIMEOUT_MS = 4000

--- Arguments go into a shell command, so only characters that appear in bus
--- names, object paths and typed arguments are allowed. Anything else is a
--- bug in the caller, not user input to escape.
local function safe(word)
    return type(word) == "string" and word:match("^[%w%._/:%-]+$") ~= nil
end

--- A `dbus-send --print-reply` command line, or nil if an argument is unsafe.
---@param service string e.g. "org.bluez"
---@param path string object path
---@param method string interface and member, e.g. "org.freedesktop.DBus.Properties.Get"
---@param ... string typed arguments, e.g. "string:org.bluez.Adapter1"
---@return string|nil
function Dbus.command(service, path, method, ...)
    local parts = {
        "dbus-send", "--system", "--print-reply",
        "--reply-timeout=" .. Dbus.REPLY_TIMEOUT_MS,
        "--dest=" .. tostring(service), tostring(path), tostring(method),
    }
    for _, word in ipairs({ service, path, method, ... }) do
        if not safe(word) then
            return nil
        end
    end
    for _, arg in ipairs({ ... }) do
        table.insert(parts, arg)
    end
    return table.concat(parts, " ")
end

--- The BlueZ object path of a device, or nil if `mac` isn't a MAC.
---@param adapter string e.g. "/org/bluez/hci0"
---@param mac string
---@return string|nil
function Dbus.devicePath(adapter, mac)
    if type(mac) ~= "string" or not mac:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") then
        return nil
    end
    return adapter .. "/dev_" .. mac:upper():gsub(":", "_")
end

--- Whether `dbus-send` is installed. Checked once: the answer can't change
--- while KOReader runs, and init runs again on every view change.
---@return boolean
function Dbus.available()
    if Dbus._available == nil then
        local handle = io.popen("command -v dbus-send 2>/dev/null")
        local out = handle and handle:read("*a") or ""
        if handle then handle:close() end
        Dbus._available = out:match("%S") ~= nil
    end
    return Dbus._available
end

return Dbus
