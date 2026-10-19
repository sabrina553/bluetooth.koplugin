local UIManager = require("ui/uimanager")

--- Holds off KOReader's standby while we wait on a timer-driven poll.
--- Without it the reader idles into standby after `netagent bt on` and the
--- 1s poll doesn't run until the next touch (68s stall seen in crash.log on
--- 2026-10-13). KOReader's own network code does the same.
local Standby = {}

--- Returns a release function; calling it more than once is harmless, so
--- every exit path of a poll can call it without keeping count.
---@return fun()
function Standby.hold()
    if not UIManager.preventStandby then
        return function() end
    end
    UIManager:preventStandby()
    local released = false
    return function()
        if released then return end
        released = true
        UIManager:allowStandby()
    end
end

return Standby
