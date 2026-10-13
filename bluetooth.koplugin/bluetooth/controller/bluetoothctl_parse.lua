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
    -- Anchored: scan notices such as "[CHG] Device <mac> AdvertisingFlags: ..."
    -- also contain "Device <mac>" and used to be listed as a device.
    local mac, rest = string.match(line, "^%s*Device (%x%x:%x%x:%x%x:%x%x:%x%x:%x%x)%s+(.*)")
    if not mac then
        return nil
    end
    rest = rest and rest:gsub("^%s+", ""):gsub("%s+$", "") or ""
    local dashMac = mac:gsub(":", "-")
    local name = (rest == "" or rest:upper() == dashMac:upper()) and "Unknown" or rest
    return mac, name
end

--- Every device line of a listing, such as `bluetoothctl devices` or its
--- paired variant. Lines that aren't devices (errors, notices) are skipped.
---@param output string
---@return {mac: string, name: string}[]
function Parse.deviceList(output)
    local list = {}
    for line in string.gmatch(output or "", "[^\r\n]+") do
        local mac, name = Parse.deviceLine(line)
        if mac then
            table.insert(list, { mac = mac, name = name })
        end
    end
    return list
end

--- Whether bluetoothctl rejected the command itself (as opposed to running it
--- and finding nothing). The command set differs between BlueZ versions, so
--- callers use this to fall back to another spelling.
---@param output string
---@return boolean
function Parse.isUnsupportedCommand(output)
    output = (output or ""):lower()
    return output:find("too many arguments", 1, true) ~= nil
        or output:find("invalid command", 1, true) ~= nil
        or output:find("invalid argument", 1, true) ~= nil
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
