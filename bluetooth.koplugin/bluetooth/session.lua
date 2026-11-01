--- Tells a cold start from a view change.
---
--- KOReader rebuilds every plugin instance when the view changes (file manager
--- to book and back), so `init` runs again without the reader having woken or
--- started. Lua caches this module for the whole process, so its flag outlives
--- those rebuilds. Pure Lua, so it can be tested with plain luajit.
--- Decision: 2026-10-13 session note (enable-on-wake after view changes).

local Session = {}

local started = false

--- True the first time it is called in this KOReader process, false after.
---@return boolean
function Session.isColdStart()
    if started then
        return false
    end
    started = true
    return true
end

return Session
