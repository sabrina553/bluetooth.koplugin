-- Run from the repo root: luajit tests/kobo_input_test.lua
package.path = "bluetooth.koplugin/?.lua;tests/?.lua;" .. package.path
local helpers = require("helpers")
local logs = {}
package.preload["logger"] = function()
    local function log(...) table.insert(logs, table.concat({ ... }, " ")) end
    return { dbg = log, info = log, warn = log, err = log }
end
local KoboInput = require("bluetooth/keys/kobo_input")

local failures = 0
local function check(cond, message)
    helpers.rejectDescription(cond)
    if not cond then
        failures = failures + 1
        print("FAIL " .. message)
    end
end

-- Shaped like `readlink` on an MTK Kobo (onatbas): built-ins sit under
-- platform, Bluetooth HID devices under uhid.
local LISTING = table.concat({
    "/sys/class/input/event0 ../../devices/platform/10019000.keypad/input/input0/event0",
    "/sys/class/input/event1 ../../devices/platform/touch/input/input1/event1",
    "/sys/class/input/event4 ../../devices/virtual/misc/uhid/0005:2DC8:5101.0001/input/input4/event4",
    "/sys/class/input/event5",
    "",
}, "\n")

local found = KoboInput.parse(LISTING)
check(#found == 1, "parse: only the uhid device, got " .. #found)
check(found[1] and found[1].path == "/dev/input/event4", "parse: path from the event number")
check(#KoboInput.parse("") == 0, "parse: empty listing")
check(#KoboInput.parse(nil) == 0, "parse: nil listing")

-- Opening: once per path per session; a failing open is logged, not raised.
KoboInput._reset()
local opened = {}
local input = { open = function(_, path) table.insert(opened, path) end }
KoboInput.openNew(input, found)
KoboInput.openNew(input, found)
check(#opened == 1 and opened[1] == "/dev/input/event4", "open: once per path")

KoboInput._reset()
logs = {}
local broken = { open = function() error("no such device") end }
local ok = pcall(KoboInput.openNew, broken, found)
check(ok, "open: an error does not escape")
local logged = false
for _, line in ipairs(logs) do
    if line:find("could not open", 1, true) then logged = true end
end
check(logged, "open: failure is logged")

KoboInput._reset()
check(pcall(KoboInput.openNew, {}, found), "open: input without open() is skipped")

-- A node that vanished (disconnect) and came back is opened again: the
-- kernel often reuses the same eventN (review 2026-10-28).
KoboInput._reset()
opened = {}
KoboInput.openNew(input, found)
KoboInput.openNew(input, {})
KoboInput.openNew(input, found)
check(#opened == 2, "reopen: a returning node is opened again, got " .. #opened)

if failures > 0 then
    os.exit(1)
end
print("kobo_input_test: ok")
