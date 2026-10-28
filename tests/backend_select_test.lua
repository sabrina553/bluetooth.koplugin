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

-- Families (decision 2026-10-28): detected and logged, no backend yet.
local MTK_SERVICE = "/usr/share/dbus-1/system-services/com.kobo.mtk.bluedroid.service"
local function family(description, fields, files, expected)
    local Device = { model = fields.model }
    for name, value in pairs(fields) do
        if name ~= "model" then Device[name] = function() return value end end
    end
    for _, name in ipairs({ "isAndroid", "isPocketBook", "isKobo", "isKindle", "isEmulator", "isDesktop" }) do
        Device[name] = Device[name] or function() return false end
    end
    local actual = BackendSelect.family(Device, function(path) return files[path] == true end)
    if actual ~= expected then
        failures = failures + 1
        print(("FAIL family %s: got %s, expected %s"):format(description, tostring(actual), tostring(expected)))
    end
end

family("Kobo MTK", { isKobo = true, isMTK = true }, { [MTK_SERVICE] = true }, "kobo-mtk")
family("MTK without the service file", { isKobo = true, isMTK = true }, {}, "kobo")
family("Kobo without isMTK", { isKobo = true }, { [MTK_SERVICE] = true }, "kobo")
family("Libra 2", { isKobo = true, isMTK = false, model = "Kobo_io" }, {}, "kobo-legacy")
family("Clara 2E", { isKobo = true, model = "Kobo_goldfinch" }, {}, "kobo-legacy")
family("Sage", { isKobo = true, model = "Kobo_cadmus" }, {}, "kobo-legacy")
family("other Kobo", { isKobo = true, model = "Kobo_nova" }, {}, "kobo")
family("Kindle", { isKindle = true }, {}, "kindle")
family("PocketBook", { isPocketBook = true }, {}, "pocketbook")
family("Android", { isAndroid = true, isKobo = true }, {}, "android")
family("desktop", { isDesktop = true }, {}, "desktop")
family("emulator", { isEmulator = true }, {}, "desktop")
family("unknown", {}, {}, nil)
check("family does not enable Kobo MTK", { isKobo = true, isMTK = true }, nil)

if failures > 0 then
    print(failures .. " failure(s)")
    os.exit(1)
end
print("all backend_select tests passed")
