-- Run from the repo root: luajit tests/safe_path_test.lua
package.path = "bluetooth.koplugin/?.lua;" .. package.path
local SafePath = require("bluetooth/ota/safe_path")

local failures = 0
local function check(path, expected)
    local actual = SafePath.isSafeRelative(path)
    if actual ~= expected then
        failures = failures + 1
        print(("FAIL isSafeRelative(%s): got %s, expected %s"):format(tostring(path), tostring(actual), tostring(expected)))
    end
end

check("main.lua", true)
check("bluetooth/ui/menu.lua", true)
check("a/b..c/d.lua", true)
check("..", false)
check("../main.lua", false)
check("bluetooth/../../x", false)
check("/etc/passwd", false)
check("bluetooth\\..\\x", false)
check("", false)
check(nil, false)

if failures > 0 then
    print(failures .. " failure(s)")
    os.exit(1)
end
print("all safe_path tests passed")
