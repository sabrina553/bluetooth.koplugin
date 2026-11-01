-- Run from the repo root: luajit tests/backend_select_test.lua
package.path = "bluetooth.koplugin/?.lua;" .. package.path
local BackendSelect = require("bluetooth/controller/backend_select")

local failures = 0
local function check(description, flags, expected)
    local Device = setmetatable({}, {
        __index = function(_, name)
            return function() return flags[name] == true end
        end,
    })
    local actual = BackendSelect.select(Device)
    if actual ~= expected then
        failures = failures + 1
        print(("FAIL %s: got %s, expected %s"):format(description, tostring(actual), tostring(expected)))
    end
end

check("PocketBook", { isPocketBook = true }, "PocketBook")
check("emulator", { isEmulator = true }, "Bluez")
check("desktop", { isDesktop = true }, "Bluez")
check("Kobo has no backend", { isKobo = true }, nil)
check("Kindle has no backend", { isKindle = true }, nil)
check("Android has no backend", { isAndroid = true }, nil)
check("Android wins over PocketBook", { isAndroid = true, isPocketBook = true }, nil)
check("unknown device", {}, nil)

local function mode(description, setting, has_dbus, expected)
    local actual = BackendSelect.mode(setting, has_dbus)
    if actual ~= expected then
        failures = failures + 1
        print(("FAIL mode %s: got %s, expected %s"):format(description, tostring(actual), tostring(expected)))
    end
end
mode("automatic with dbus-send", "auto", true, "fast")
mode("automatic without dbus-send", "auto", false, "compatible")
mode("fast with dbus-send", "fast", true, "fast")
mode("fast without dbus-send falls back", "fast", false, "compatible")
mode("compatible ignores dbus-send", "compatible", true, "compatible")
mode("unset setting is automatic", nil, true, "fast")

if failures > 0 then
    print(failures .. " failure(s)")
    os.exit(1)
end
print("all backend_select tests passed")
