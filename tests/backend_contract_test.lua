-- Run from the repo root: luajit tests/backend_contract_test.lua
package.path = "bluetooth.koplugin/?.lua;tests/?.lua;" .. package.path
local helpers = require("helpers")
local Contract = require("bluetooth/controller/backend_contract")

local failures = 0
local function check(cond, message)
    helpers.rejectDescription(cond)
    if not cond then
        failures = failures + 1
        print("FAIL " .. message)
    end
end

local function noop() end

--- A backend with every required method and every feature switched on.
local function full()
    local backend = { capabilities = { trust = true, block = true, transport = true, info = true } }
    for _, name in ipairs(Contract.REQUIRED) do backend[name] = noop end
    for _, methods in pairs(Contract.FEATURES) do
        for _, name in ipairs(methods) do backend[name] = noop end
    end
    return backend
end

local function mentions(problems, word)
    for _, p in ipairs(problems) do
        if p:find(word, 1, true) then return true end
    end
    return false
end

local ok, problems = Contract.check(full())
check(ok and #problems == 0, "a complete backend passes")

local b = full()
b.connect = nil
ok, problems = Contract.check(b)
check(not ok and mentions(problems, "connect"), "a missing required method is reported by name")

b = full()
b.untrust = nil
ok, problems = Contract.check(b)
check(not ok and mentions(problems, "untrust"), "a declared feature without its method is reported")

b = full()
b.capabilities.trust = false
b.trust, b.untrust = nil, nil
ok = Contract.check(b)
check(ok, "a feature switched off needs no methods")

b = full()
b.capabilities.foo = true
ok, problems = Contract.check(b)
check(not ok and mentions(problems, "foo"), "an unknown capability is reported")

b = full()
b.capabilities = nil
ok, problems = Contract.check(b)
check(not ok and mentions(problems, "capabilities"), "a backend without a capabilities table fails")

-- Methods inherited through a metatable count, as BluezDbus inherits Bluez.
local child = setmetatable({ capabilities = full().capabilities }, { __index = full() })
check((Contract.check(child)), "inherited methods count")

-- The real backends. BluezDbus is what the controller swaps in for Fast
-- mode, so it is checked on its own, not only through Bluez.
package.preload["gettext"] = function() return function(s) return s end end
package.preload["logger"] = function()
    local noop = function() end
    return { dbg = noop, info = noop, warn = noop, err = noop }
end
package.preload["ui/uimanager"] = function() return {} end
for _, name in ipairs({ "bluez", "bluez_dbus", "pocketbook", "kobo_mtk" }) do
    local backend = require("bluetooth/controller/" .. name)
    ok, problems = Contract.check(backend)
    check(ok, name .. " meets the contract: " .. table.concat(problems, "; "))
end

if failures > 0 then
    os.exit(1)
end
print("backend_contract_test: ok")
