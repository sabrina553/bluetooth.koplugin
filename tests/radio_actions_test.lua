-- Run from the repo root: luajit tests/radio_actions_test.lua
package.path = "bluetooth.koplugin/?.lua;tests/?.lua;" .. package.path
local rejectDescription = require("helpers").rejectDescription

package.preload["logger"] = function()
    local noop = function() end
    return { dbg = noop, info = noop, warn = noop, err = noop }
end
package.preload["gettext"] = function() return function(s) return s end end
local shown = {}
package.preload["ui/uimanager"] = function()
    return { show = function(_, w) shown[#shown + 1] = w.text end, close = function() end }
end
package.preload["ui/widget/infomessage"] = function()
    return { new = function(_, o) return o end }
end

local RadioActions = require("bluetooth/ui/radio_actions")

local failures = 0
local function check(cond, message)
    rejectDescription(cond)
    if not cond then failures = failures + 1; print("FAIL " .. message) end
end

-- Registration: three device actions, each with its own event.
local actions = {}
RadioActions.register({ registerAction = function(_, id, v) actions[id] = v end })
check(actions.bluetooth_koplugin_toggle and actions.bluetooth_koplugin_toggle.event == "BluetoothToggle",
    "toggle action registered")
check(actions.bluetooth_koplugin_on.event == "BluetoothOn" and actions.bluetooth_koplugin_off.event == "BluetoothOff",
    "on and off actions registered")
check(actions.bluetooth_koplugin_on.device == true and actions.bluetooth_koplugin_on.category == "none",
    "actions sit in the device section and take no argument")

local function fakeController(on, switching)
    local c = { is_enabled = on, toggles = 0 }
    function c:isUserSwitching() return switching == true end
    function c:status() end
    function c:wantsEnabled() return self.is_enabled end
    function c:toggle(cb, fresh)
        self.toggles = self.toggles + 1
        self.fresh = fresh
        self.is_enabled = not self.is_enabled
        cb(true)
    end
    return c
end

local c = fakeController(false)
RadioActions.switch(c, nil)
check(c.toggles == 1 and c.is_enabled and c.fresh == true, "toggle flips through controller:toggle, reusing the read")

c = fakeController(false)
RadioActions.switch(c, true)
check(c.toggles == 1 and c.is_enabled, "on turns an off radio on")

c, shown = fakeController(true), {}
RadioActions.switch(c, true)
check(c.toggles == 0 and shown[1] == "Bluetooth is already on", "on leaves an on radio alone")

c = fakeController(true)
RadioActions.switch(c, false)
check(c.toggles == 1 and not c.is_enabled, "off turns an on radio off")

c = fakeController(false)
RadioActions.switch(c, false)
check(c.toggles == 0, "off leaves an off radio alone")

c = fakeController(false, true)
RadioActions.switch(c, nil)
check(c.toggles == 0, "ignored while a switch is under way")

if failures > 0 then
    print(failures .. " failure(s)")
    os.exit(1)
end
print("radio_actions_test: all passed")
