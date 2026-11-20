-- Run from the repo root: luajit tests/kobo_reboot_test.lua
package.path = "bluetooth.koplugin/?.lua;tests/?.lua;" .. package.path
local helpers = require("helpers")
local logs = {}
package.preload["logger"] = function()
    local function log(...) table.insert(logs, table.concat({ ... }, " ")) end
    return { dbg = log, info = log, warn = log, err = log }
end
local KoboReboot = require("bluetooth/controller/kobo_reboot")

local failures = 0
local function check(cond, message)
    helpers.rejectDescription(cond)
    if not cond then
        failures = failures + 1
        print("FAIL " .. message)
    end
end

local quits, reboots = 0, 0
local UIManager = {
    quit = function() quits = quits + 1 return "quit" end,
    reboot_action = function() reboots = reboots + 1 return "reboot" end,
}
local used = false
KoboReboot.install(UIManager, function() return false end)
local wrapped = UIManager.quit
KoboReboot.install(UIManager, function() return used end) -- a view change re-inits the plugin
check(UIManager.quit == wrapped, "second install does not wrap again")

local function reset() quits, reboots, logs = 0, 0, {} end

reset()
UIManager:quit()
check(quits == 1 and reboots == 0, "not used: quits normally, wrapped once")

used = true
reset()
check(UIManager:quit() == "reboot", "used: returns the reboot")
check(quits == 0 and reboots == 1, "used: reboots instead of quitting")
local logged = false
for _, line in ipairs(logs) do
    if line:find("rebooting after Kobo MTK Bluetooth use", 1, true) then logged = true end
end
check(logged, "used: reboot is logged")

reset()
UIManager:quit(1)
check(quits == 1 and reboots == 0, "non-zero exit code: quits")

reset()
UIManager:quit(false)
check(quits == 1 and reboots == 0, "exit code false: quits")

reset()
UIManager._entered_poweroff_stage = true
UIManager:quit()
check(quits == 1 and reboots == 0, "powering off: quits")
UIManager._entered_poweroff_stage = nil

reset()
UIManager._exit_code = 85 -- KOReader's restart code
UIManager:quit()
check(quits == 1 and reboots == 0, "restart exit code: quits")
UIManager._exit_code = nil

if failures > 0 then
    os.exit(1)
end
print("kobo_reboot_test: ok")
