-- Run from the repo root: luajit tests/poll_test.lua
package.path = "bluetooth.koplugin/?.lua;" .. package.path
local Poll = require("bluetooth/controller/poll")

local failures = 0
local function check(cond, message)
    -- A string here means a check(description, actual, expected) call from
    -- the other test style, which would always pass (it did, 2026-10-26).
    assert(type(cond) ~= "string", "check(cond, message) called with a description first: " .. tostring(cond))
    if not cond then
        failures = failures + 1
        print("FAIL " .. message)
    end
end

check(Poll.delay(1) < 1, "first re-check comes quickly")
local total = 0
for attempt = 1, Poll.MAX_ATTEMPTS - 1 do
    check(Poll.delay(attempt) <= Poll.delay(attempt + 1), "delays never shrink")
    total = total + Poll.delay(attempt)
end
-- The old schedule gave up after nine 1 s waits; a slow radio still gets that long.
check(total >= 9, "total wait is at least the old 9 s, got " .. total)

if failures > 0 then os.exit(1) end
print("poll_test: ok")
