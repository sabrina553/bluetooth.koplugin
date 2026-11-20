--- Toasts the user can silence from Settings > Notifications. Failures and
--- progress messages bypass this and use InfoMessage directly.
local Notify = {}

---@param settings BluetoothSettings|nil nil shows the toast regardless
---@param kind string "radio" | "device"
---@param text string
---@param timeout number|nil
function Notify.show(settings, kind, text, timeout)
    if settings and not settings:shouldNotify(kind) then return end
    -- Required here, not at load, so pure modules stay loadable in tests.
    local UIManager = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    UIManager:show(InfoMessage:new{ text = text, timeout = timeout })
end

return Notify
