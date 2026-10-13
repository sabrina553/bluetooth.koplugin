--- Parsers for `dbus-send --print-reply` output.
---
--- Pure Lua with no KOReader dependencies, so it can be tested with plain luajit.
--- The reader has `dbus-send` but no `gdbus` or `busctl` (checked 2026-10-13,
--- see vault Docs/D-Bus findings), so its text layout is what we parse.

local DbusParse = {}

-- Scalar lines, as dbus-send prints them: "<type> <value>".
local NUMBER_TYPES = {
    byte = true, int16 = true, uint16 = true, int32 = true, uint32 = true,
    int64 = true, uint64 = true, double = true,
}

--- One scalar value, or nil for a line that isn't one.
local function scalar(line)
    local s = line:match('^string "(.*)"$') or line:match('^object path "(.*)"$')
        or line:match('^signature "(.*)"$')
    if s then
        return s
    end
    local b = line:match("^boolean (%a+)$")
    if b then
        return b == "true"
    end
    local kind, n = line:match("^(%w+) (%-?[%d%.e%+%-]+)$")
    if kind and NUMBER_TYPES[kind] then
        return tonumber(n)
    end
    -- Short byte arrays print inline, e.g. `array of bytes "" + \0` for
    -- AdvertisingFlags. Nothing we read is a byte array, so keep the text.
    local bytes = line:match("^array of bytes (.*)$")
    if bytes and bytes ~= "[" then
        return bytes
    end
    return nil
end

--- Turns an array whose items are all dict entries into a keyed table.
local function finishArray(items)
    if #items == 0 then
        return items
    end
    for _, item in ipairs(items) do
        if type(item) ~= "table" or not item.__entry then
            return items
        end
    end
    local dict = {}
    for _, entry in ipairs(items) do
        dict[entry.key] = entry.value
    end
    return dict
end

--- The values of a reply, as Lua tables: arrays become lists, arrays of dict
--- entries become keyed tables, variants are unwrapped. Returns nil, the
--- error name and message for an error reply, and nil, "parse" for text that
--- isn't a reply, so callers can tell a refused call from a broken one.
---@param output string
---@return table|nil values
---@return string|nil error_name
---@return string|nil error_message
function DbusParse.reply(output)
    output = output or ""
    local err, msg = output:match("Error ([%w%._]+): ([^\r\n]*)")
    if err then
        return nil, err, msg
    end
    if not output:find("^%s*method return") then
        return nil, "parse", "no method return"
    end

    local root = { items = {} }
    local stack = { root }
    local function add(value)
        local top = stack[#stack]
        if top.entry then
            if top.has_key then
                top.value = value
            else
                top.key, top.has_key = value, true
            end
        else
            table.insert(top.items, value)
        end
    end

    local first = true
    for raw in (output .. "\n"):gmatch("([^\r\n]*)\r?\n") do
        if first then
            first = false -- the "method return ..." header
        else
            -- A variant prints its value on the same line, after padding.
            local line = raw:gsub("^%s+", ""):gsub("%s+$", ""):gsub("^variant%s+", "")
            if line == "" then
                -- blank
            elseif line == "array [" or line == "array of bytes [" or line == "struct {" then
                table.insert(stack, { items = {} })
            elseif line == "dict entry(" then
                table.insert(stack, { entry = true })
            elseif line == "]" or line == "}" then
                if #stack < 2 or stack[#stack].entry then
                    return nil, "parse", "unbalanced " .. line
                end
                local done = table.remove(stack)
                add(line == "]" and finishArray(done.items) or done.items)
            elseif line == ")" then
                local done = table.remove(stack)
                if not done or not done.entry then
                    return nil, "parse", "unbalanced )"
                end
                add({ __entry = true, key = done.key, value = done.value })
            else
                local value = scalar(line)
                if value == nil then
                    -- Hex rows inside `array of bytes [`, or a type this
                    -- parser doesn't know: kept as text rather than failing
                    -- the whole reply over one property we don't use.
                    value = line
                end
                add(value)
            end
        end
    end

    if #stack ~= 1 then
        return nil, "parse", "unterminated reply"
    end
    return root.items
end

---@class DbusDevice
---@field path string object path, e.g. /org/bluez/hci0/dev_00_11_22_33_44_55
---@field mac string
---@field name string|nil
---@field paired boolean
---@field bonded boolean
---@field trusted boolean
---@field blocked boolean
---@field connected boolean

--- Adapters and devices from `ObjectManager.GetManagedObjects`. Devices have
--- the same fields as `Parse.info`, so either backend can build `Devices`
--- from them. The service name is not assumed: Kobo MTK's bluedroid service
--- uses the same `org.bluez.Adapter1` and `Device1` interfaces.
---@param output string
---@return {adapters: table<string, table>, devices: DbusDevice[]}|nil
---@return string|nil error_name
---@return string|nil error_message
function DbusParse.managedObjects(output)
    local values, err, msg = DbusParse.reply(output)
    if not values then
        return nil, err, msg
    end
    local objects = values[1]
    if type(objects) ~= "table" then
        return nil, "parse", "no object table"
    end

    local result = { adapters = {}, devices = {} }
    for path, interfaces in pairs(objects) do
        if type(path) == "string" and type(interfaces) == "table" then
            local adapter = interfaces["org.bluez.Adapter1"]
            local props = interfaces["org.bluez.Device1"]
            if type(adapter) == "table" then
                result.adapters[path] = adapter
            end
            -- MAC from the Address property, not the path: the path form
            -- uses underscores and other stacks may name paths differently.
            local mac = type(props) == "table" and props.Address
            if type(mac) == "string" and mac:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") then
                local name = props.Alias or props.Name
                -- An unnamed device's alias is its MAC with dashes, as in
                -- Parse.info; leave it unset so the menu shows "Unknown".
                if type(name) ~= "string" or name:upper() == mac:gsub(":", "-"):upper() then
                    name = nil
                end
                table.insert(result.devices, {
                    path = path,
                    mac = mac,
                    name = name,
                    paired = props.Paired == true,
                    bonded = props.Bonded == true,
                    trusted = props.Trusted == true,
                    blocked = props.Blocked == true,
                    connected = props.Connected == true,
                })
            end
        end
    end
    -- pairs() order is random; a stable order keeps the menu from shuffling.
    table.sort(result.devices, function(a, b) return a.path < b.path end)
    return result
end

--- The single value of a `Properties.Get` reply (`variant boolean true`).
---@param output string
---@return any|nil value
---@return string|nil error_name
---@return string|nil error_message
function DbusParse.property(output)
    local values, err, msg = DbusParse.reply(output)
    if not values then
        return nil, err, msg
    end
    if values[1] == nil then
        return nil, "parse", "empty reply"
    end
    return values[1]
end

return DbusParse
