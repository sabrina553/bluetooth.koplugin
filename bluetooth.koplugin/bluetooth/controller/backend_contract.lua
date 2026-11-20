--- What every Bluetooth backend must provide, and what it may provide.
---
--- Kobo and Kindle backends will not all manage trust or block (decision
--- 2026-10-28, vault Docs/Multi-device phase 0 design), so those are
--- features a backend declares in its `capabilities` table and the menu
--- hides when they are off. Checked in tests only, not at load.
---
--- `readStatus`, `readSnapshot`'s background read and `readInfo` stay
--- optional fast paths: callers already test for them.

local Contract = {}

Contract.REQUIRED = {
    "enable", "disable", "status", "knownDevices", "readSnapshot", "search",
    "pair", "unpair", "connect", "disconnect",
}

--- Feature name -> methods a backend needs when it declares the feature.
--- `transport` (Fast/Compatible) has none: the controller swaps BluezDbus in
--- for Bluez, and PocketBook takes it through `setTransport`.
Contract.FEATURES = {
    trust = { "trust", "untrust" },
    block = { "block", "unblock" },
    transport = {},
    info = { "info" },
    -- Pairing a device typed in by address, for remotes Kindle's audio-only
    -- scan never lists (decision 2026-10-28).
    address_pair = {},
}

---@param backend table
---@return boolean ok
---@return string[] problems
function Contract.check(backend)
    local problems = {}
    for _, name in ipairs(Contract.REQUIRED) do
        if type(backend[name]) ~= "function" then
            table.insert(problems, "missing required method " .. name)
        end
    end
    local caps = backend.capabilities
    if type(caps) ~= "table" then
        table.insert(problems, "no capabilities table")
        return false, problems
    end
    -- Sorted: pairs() order varies, and test output should not.
    local features = {}
    for feature in pairs(caps) do table.insert(features, feature) end
    table.sort(features, function(a, b) return tostring(a) < tostring(b) end)
    for _, feature in ipairs(features) do
        local on = caps[feature]
        local methods = Contract.FEATURES[feature]
        if not methods then
            table.insert(problems, "unknown capability " .. tostring(feature))
        elseif on then
            for _, name in ipairs(methods) do
                if type(backend[name]) ~= "function" then
                    table.insert(problems, feature .. " declared but " .. name .. " is missing")
                end
            end
        end
    end
    return #problems == 0, problems
end

return Contract
