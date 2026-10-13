-- Run from the repo root: luajit tests/session_test.lua
package.path = "bluetooth.koplugin/?.lua;" .. package.path

local Session = require("bluetooth/session")

local failures = 0
local function check(cond, message)
    if not cond then
        failures = failures + 1
        print("FAIL " .. message)
    end
end

check(Session.isColdStart() == true, "first call is a cold start")
check(Session.isColdStart() == false, "second call (view change) is not")
check(Session.isColdStart() == false, "later calls are not either")

if failures > 0 then os.exit(1) end
print("session_test: ok")
