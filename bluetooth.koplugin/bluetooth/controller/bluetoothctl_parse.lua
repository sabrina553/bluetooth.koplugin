--- Parsers for `bluetoothctl` output.
---
--- Pure Lua with no KOReader dependencies, so it can be tested with plain luajit.

local Parse = {}

--- One line of `bluetoothctl devices`: "Device AA:BB:CC:DD:EE:FF Some Name".
--- A device with no name is listed under its MAC with dashes, which is
--- reported as "Unknown".
---@param line string
---@return string|nil mac
---@return string|nil name
function Parse.deviceLine(line)
    local mac, rest = string.match(line, "Device (%x%x:%x%x:%x%x:%x%x:%x%x:%x%x)%s+(.*)")
    if not mac then
        return nil
    end
    rest = rest and rest:gsub("^%s+", ""):gsub("%s+$", "") or ""
    local dashMac = mac:gsub(":", "-")
    local name = (rest == "" or rest:upper() == dashMac:upper()) and "Unknown" or rest
    return mac, name
end

---@class BluetoothctlInfo
---@field mac string|nil
---@field name string|nil
---@field paired boolean
---@field bonded boolean
---@field trusted boolean
---@field blocked boolean
---@field connected boolean

--- Output of `bluetoothctl info <mac>`. Flags missing from the output are false.
---@param output string
---@return BluetoothctlInfo
function Parse.info(output)
    local function flag(key)
        return output:match(key .. ": (%w+)") == "yes"
    end

    -- Fields sit on indented lines after the "Device ..." header. Alias is
    -- what `bluetoothctl devices` (and so the menu) shows; Name is the fallback.
    local function text(key)
        return output:match("\n%s*" .. key .. ": ([^\r\n]+)")
    end

    local mac = output:match("Device (%w+:%w+:%w+:%w+:%w+:%w+)")
    local name = text("Alias") or text("Name")
    -- An unnamed device's alias is its MAC with dashes; leave it unset, as
    -- deviceLine() does, so the menu keeps showing it as "Unknown".
    if name and mac and name:upper() == mac:gsub(":", "-"):upper() then
        name = nil
    end

    return {
        mac = mac,
        name = name,
        paired = flag("Paired"),
        bonded = flag("Bonded"),
        trusted = flag("Trusted"),
        blocked = flag("Blocked"),
        connected = flag("Connected"),
    }
end

return Parse
