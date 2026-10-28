--- Chooses which backend drives Bluetooth on the current device.
---
--- Pure Lua with no KOReader dependencies (the Device object is passed in),
--- so it can be tested with plain luajit.

local BackendSelect = {}

--- The order matters: Android is checked first so it never falls through to
--- a Linux-style backend, and a device we have no backend for returns nil.
---@param Device table KOReader's `device` module
---@param file_exists function|nil path -> boolean, for tests
---@return string|nil backend "PocketBook", "Bluez" or "KoboMTK", nil if unsupported
function BackendSelect.select(Device, file_exists)
    if Device:isAndroid() then
        return nil
    elseif Device:isPocketBook() then
        return "PocketBook"
    elseif Device:isKobo() then
        -- Only MTK models so far; older Kobos start their stack by hand
        -- (decision 2026-10-28).
        return BackendSelect.family(Device, file_exists) == "kobo-mtk" and "KoboMTK" or nil
    elseif Device:isEmulator() or Device:isDesktop() then
        return "Bluez"
    end
    -- Kindle has no backend yet.
    return nil
end

-- Adapted from ZenOS (GPL-3.0), modules/menu/bluetooth/kobo_bluetooth.lua;
-- see CREDITS.md. MTK Kobos run Kobo's own BlueZ-like D-Bus service.
local MTK_SERVICE = "/usr/share/dbus-1/system-services/com.kobo.mtk.bluedroid.service"
-- Libra 2, Clara 2E and Sage: the stack is started by hand.
local KOBO_LEGACY = { Kobo_io = true, Kobo_goldfinch = true, Kobo_cadmus = true }

local function fileExists(path)
    local f = io.open(path, "r")
    if f then f:close() end
    return f ~= nil
end

--- Which kind of device this is, for logging and for the platform backends
--- to come (decision 2026-10-28). Detection only: `select` still returns
--- nil for Kobo and Kindle.
---@param Device table KOReader's `device` module
---@param file_exists function|nil path -> boolean, for tests
---@return string|nil family "kobo-mtk" | "kobo-legacy" | "kobo" | "kindle"
---  | "pocketbook" | "android" | "desktop"
function BackendSelect.family(Device, file_exists)
    file_exists = file_exists or fileExists
    if Device:isAndroid() then
        return "android"
    elseif Device:isPocketBook() then
        return "pocketbook"
    elseif Device:isKobo() then
        -- isMTK is missing on older KOReader builds.
        if Device.isMTK and Device:isMTK() and file_exists(MTK_SERVICE) then
            return "kobo-mtk"
        elseif KOBO_LEGACY[Device.model] then
            return "kobo-legacy"
        end
        return "kobo"
    elseif Device:isKindle() then
        return "kindle"
    elseif Device:isEmulator() or Device:isDesktop() then
        return "desktop"
    end
    return nil
end

BackendSelect.MODES = { auto = true, fast = true, compatible = true }

--- Which BlueZ transport to use: "fast" (D-Bus reads) or "compatible"
--- (bluetoothctl only). Automatic and Fast both need `dbus-send`; without it
--- Fast quietly becomes Compatible rather than leaving Bluetooth unusable.
---@param setting string|nil "auto" | "fast" | "compatible"
---@param has_dbus boolean
---@return string mode "fast" | "compatible"
function BackendSelect.mode(setting, has_dbus)
    if setting == "compatible" then
        return "compatible"
    end
    return has_dbus and "fast" or "compatible"
end

return BackendSelect
