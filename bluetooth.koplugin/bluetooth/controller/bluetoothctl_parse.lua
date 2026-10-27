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

--- A MAC address reduced to its last two bytes, for logs: the reader's
--- crash.log is shared when people ask for help, and full addresses identify
--- devices. Every MAC in the text is masked, including the underscore form in
--- D-Bus object paths (`dev_00_11_…`); anything else is passed through.
---@param mac any
---@return string
function Parse.maskMac(mac)
    local masked = tostring(mac):gsub("%x%x([:_])%x%x%1%x%x%1%x%x%1(%x%x%1%x%x)", function(sep, tail)
        return ("XX" .. sep):rep(4) .. tail
    end)
    return masked
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

--- Splits the output of the snapshot script (see Bluez.snapshotScript) into
--- its sections. Each section is introduced by `@@section <name>` and closed
--- by `@@rc <exit status>`; a section with no `@@rc` was cut off, which is
--- reported as `rc = nil` so the caller treats it as timed out.
---@param output string
---@return table<string, {text: string, rc: integer|nil}>
function Parse.snapshot(output)
    local sections = {}
    local current
    for line in string.gmatch((output or "") .. "\n", "([^\r\n]*)\r?\n") do
        local name = line:match("^@@section (.+)$")
        local rc = line:match("^@@rc (%d+)$")
        if name then
            current = { text = "", rc = nil }
            sections[name] = current
        elseif rc and current then
            current.rc = tonumber(rc)
            current = nil
        elseif current then
            current.text = current.text .. line .. "\n"
        end
    end
    return sections
end

return Parse
