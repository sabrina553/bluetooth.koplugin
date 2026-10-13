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

    return {
        mac = output:match("Device (%w+:%w+:%w+:%w+:%w+:%w+)"),
        name = output:match("^(Name: |Alias: )(.*)\n"),
        paired = flag("Paired"),
        bonded = flag("Bonded"),
        trusted = flag("Trusted"),
        blocked = flag("Blocked"),
        connected = flag("Connected"),
    }
end

return Parse
