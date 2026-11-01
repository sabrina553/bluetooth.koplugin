local UIManager = require("ui/uimanager")

local Standby = {}

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
