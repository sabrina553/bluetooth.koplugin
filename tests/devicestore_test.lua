-- Run from the repo root: luajit tests/devicestore_test.lua
package.path = "bluetooth.koplugin/?.lua;" .. package.path
package.preload["logger"] = function()
    local noop = function() end
    return { dbg = noop, info = noop, warn = noop, err = noop }
end
package.preload["datastorage"] = function() return { getSettingsDir = function() return "/nonexistent" end } end
package.preload["luasettings"] = function()
    return { open = function()
        local kv = {}
        return {
            readSetting = function(_, k, d) return kv[k] or d end,
            saveSetting = function(_, k, v) kv[k] = v end,
            flush = function() end,
        }
    end }
end

local Store = require("bluetooth/devicestore")

local failures = 0
local function check(cond, message)
    -- A string here means a check(description, actual, expected) call from
    -- the other test style, which would always pass (it did, 2026-10-26).
    assert(type(cond) ~= "string", "check(cond, message) called with a description first: " .. tostring(cond))
    if not cond then failures = failures + 1; print("FAIL " .. message) end
end

local store = Store:new()
store.data = { ["OLD"] = { mac = "OLD", name = "Gone", paired = true } }

store:saveAll({
    { mac = "A", name = "Keyboard", paired = true, starred = true, held = true },
    { mac = "B", name = "Scan result", paired = false },
})

check(store:get("A") ~= nil and store:get("A").starred, "paired device kept with its star")
check(store:get("A").held == true, "held flag stored")
check(store:get("B") == nil, "unpaired scan result not stored")
check(store:get("OLD") == nil, "device missing from the list is dropped")

if failures > 0 then os.exit(1) end
print("devicestore_test: ok")
