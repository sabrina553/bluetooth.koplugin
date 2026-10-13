-- Run from the repo root: luajit tests/pocketbook_test.lua
package.path = "bluetooth.koplugin/?.lua;" .. package.path
package.preload["gettext"] = function() return function(s) return s end end
package.preload["logger"] = function()
    local noop = function() end
    return { dbg = noop, info = noop, warn = noop, err = noop }
end
package.preload["ui/uimanager"] = function() return {} end

local Bluez = require("bluetooth/controller/bluez")
local PocketBook = require("bluetooth/controller/pocketbook")

local failures = 0
local function fail(message)
    failures = failures + 1
    print("FAIL " .. message)
end

-- PocketBook drives the radio with netagent, so it replaces these; it hands
-- everything else to Bluez.
-- capture, lastTimedOut, pairedMacs and the snapshot helpers are helpers inside the Bluez backend, not part of the backend API.
local own = { new = true, status = true, enable = true, disable = true, capture = true, lastTimedOut = true, pairedMacs = true,
    snapshotScript = true, runAsync = true, devicesFromSnapshot = true, readStatus = true }

for name, value in pairs(Bluez) do
    if type(value) == "function" and not own[name] and type(PocketBook[name]) ~= "function" then
        fail("PocketBook does not delegate Bluez:" .. name)
    end
end

for name, value in pairs(PocketBook) do
    if type(value) == "function" and not own[name] and type(Bluez[name]) ~= "function" then
        fail("PocketBook:" .. name .. " forwards to a Bluez method that does not exist")
    end
end

local searched_for
Bluez.search = function(_, duration) searched_for = duration end
PocketBook:search(42)
if searched_for ~= 42 then
    fail("search duration not passed through: got " .. tostring(searched_for))
end

if failures > 0 then
    print(failures .. " failure(s)")
    os.exit(1)
end
print("all pocketbook tests passed")
