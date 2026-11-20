--- Radio on/off/toggle as Dispatcher actions, so gestures, profiles and
--- other plugins' quick-action menus (such as SimpleUI) can switch the
--- radio. They go through controller:toggle like the menu tick, so the
--- choice is saved for a cold start and a tap mid-switch is ignored.
--- Only on a user's action: never enabled automatically (decision 2026-11-18).
local logger = require("logger")
local _ = require("gettext")
local Notify = require("bluetooth/ui/notify")

local RadioActions = {}

local DONE_TOAST_S = 1

--- Ids carry the plugin name: Dispatcher ids share one namespace with core
--- and every other plugin.
RadioActions.ACTIONS = {
    { id = "bluetooth_koplugin_toggle", event = "BluetoothToggle", title = _("Toggle Bluetooth") },
    { id = "bluetooth_koplugin_on", event = "BluetoothOn", title = _("Turn on Bluetooth") },
    { id = "bluetooth_koplugin_off", event = "BluetoothOff", title = _("Turn off Bluetooth") },
}

function RadioActions.register(Dispatcher)
    for _, a in ipairs(RadioActions.ACTIONS) do
        Dispatcher:registerAction(a.id, {
            category = "none",
            event = a.event,
            title = a.title,
            device = true,
        })
    end
end

local function toast(text, timeout)
    local UIManager = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    UIManager:show(InfoMessage:new{ text = text, timeout = timeout })
end

--- want: true for on, false for off, nil to flip.
---@param controller table
---@param want boolean|nil
function RadioActions.switch(controller, want)
    if controller:isUserSwitching() then
        logger.dbg("Bluetooth: radio is still switching, ignoring the action")
        return
    end
    controller:status()
    local on = controller:wantsEnabled()
    if want ~= nil and want == on then
        Notify.show(controller.settings, "radio", on and _("Bluetooth is already on") or _("Bluetooth is already off"), DONE_TOAST_S)
        return
    end
    local UIManager = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    local msg = InfoMessage:new{ text = on and _("Disabling Bluetooth") or _("Enabling Bluetooth") }
    UIManager:show(msg)
    controller:toggle(function(confirmed)
        UIManager:close(msg)
        if confirmed then
            Notify.show(controller.settings, "radio", controller.is_enabled and _("Bluetooth Enabled") or _("Bluetooth Disabled"), DONE_TOAST_S)
        else
            toast(_("Could not confirm Bluetooth controller status"), 2)
        end
    end, true)
end

return RadioActions
