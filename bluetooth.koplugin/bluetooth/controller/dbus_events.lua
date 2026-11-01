--- Reads `dbus-monitor` output for BlueZ signals and says whether anything
--- the menu draws has changed. Pure Lua, so it can be tested with plain luajit.
---
--- Only a yes/no is needed: the menu then does one normal read, so the
--- signal's values are never trusted on their own. Output arrives in chunks
--- that can split a line or a signal, so the parser keeps a small state.
--- Signal shapes recorded on the reader, 2026-10-26 (vault Docs/D-Bus findings).

local DbusEvents = {}

-- Properties the menu shows. AdvertisingFlags and RSSI arrive many times a
-- second while devices advertise nearby (63 in 90 s on the reader) and are
-- not drawn, so they are ignored.
DbusEvents.RELEVANT = {
    Connected = true, Paired = true, Trusted = true, Blocked = true,
    Name = true, Alias = true, Powered = true,
}

-- A device object itself; GATT services hang below it (…/dev_XX/service000c)
-- and come and go with every connect.
local DEVICE_PATH = "^/org/bluez/hci%d+/dev_[%x_]+$"

---@class DbusEventsState
---@field rest string the unfinished last line of the previous chunk
---@field member string|nil the signal being read
---@field path string|nil its object path

---@return DbusEventsState
function DbusEvents.newState()
    return { rest = "" }
end

--- Feeds one chunk of output. Returns true when a signal in it (or one
--- finished by it) changes something the menu draws.
---@param state DbusEventsState
---@param chunk string
---@return boolean
function DbusEvents.feed(state, chunk)
    local text = state.rest .. (chunk or "")
    local relevant = false
    local last = 1
    for line, stop in text:gmatch("([^\n]*)\n()") do
        last = stop
        local member = line:match("^signal .*member=(%w+)")
        if member then
            state.member = member
            state.path = line:match(" path=([^;]+);")
        elseif state.member == "PropertiesChanged" then
            local name = line:match('^%s+string "(%w+)"%s*$')
            if name and DbusEvents.RELEVANT[name] then
                relevant = true
            end
        elseif state.member == "InterfacesAdded" or state.member == "InterfacesRemoved" then
            local path = line:match('^%s+object path "([^"]+)"')
            if path and path:match(DEVICE_PATH) then
                relevant = true
            end
        end
    end
    state.rest = text:sub(last)
    return relevant
end

return DbusEvents
