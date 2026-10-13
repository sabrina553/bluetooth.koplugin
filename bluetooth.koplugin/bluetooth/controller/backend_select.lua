--- Chooses which backend drives Bluetooth on the current device.
---
--- Pure Lua with no KOReader dependencies (the Device object is passed in),
--- so it can be tested with plain luajit.

local BackendSelect = {}

--- The order matters: Android is checked first so it never falls through to
--- a Linux-style backend, and a device we have no backend for returns nil.
---@param Device table KOReader's `device` module
---@return string|nil backend "PocketBook" or "Bluez", nil if unsupported
function BackendSelect.select(Device)
    if Device:isAndroid() then
        return nil
    elseif Device:isPocketBook() then
        return "PocketBook"
    elseif Device:isEmulator() or Device:isDesktop() then
        return "Bluez"
    end
    -- Kindle and Kobo have no backend yet.
    return nil
end

return BackendSelect
