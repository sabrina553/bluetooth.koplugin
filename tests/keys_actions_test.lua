-- Run from the repo root: luajit tests/keys_actions_test.lua
package.path = "bluetooth.koplugin/?.lua;tests/?.lua;" .. package.path
local rejectDescription = require("helpers").rejectDescription
package.preload["gettext"] = function() return function(s) return s end end
local dispatcherMode = "error"
package.preload["dispatcher"] = function()
    return {
        init = function() end,
        getNameFromItem = function(_, item)
            if dispatcherMode == "error" then error("no such action") end
            if item == "gone_action" then return "Unknown item" end
            return "Title for " .. item
        end,
    }
end

local Actions = require("bluetooth/keys/actions")
local failures = 0
local function check(cond, message)
    rejectDescription(cond)
    if not cond then failures = failures + 1; print("FAIL " .. message) end
end

local keys = Actions.keys()
check(keys[1].name == "LPgFwd", "first key is page forward")
check(#keys == 9 and keys[9].name == "Menu", "nine key actions ending in Menu")

local function has(list, id)
    for _, e in ipairs(list) do if e.actions[id] ~= nil then return true end end
    return false
end
check(not has(Actions.common("filemanager"), "page_jmp"), "filemanager has no page_jmp")
check(has(Actions.common("reader"), "page_jmp"), "reader has page_jmp")
check(#Actions.common("reader") == 10 and #Actions.common("filemanager") == 8, "list sizes")

local both = Actions.forBoth()
check(#both == 4 and has(both, "toggle_frontlight"), "forBoth has four entries incl. frontlight")
for _, e in ipairs(both) do
    local id = next(e.actions)
    check(has(Actions.common("reader"), id) and has(Actions.common("filemanager"), id),
        "forBoth entry " .. id .. " is in both lists")
end

check(Actions.label({ kind = "key", name = "LPgBack" }) == "Page back", "key label")
check(Actions.label({ kind = "dispatcher", actions = { next_chapter = true } }) == "Next chapter",
    "common label")
check(Actions.label({ kind = "dispatcher", actions = { gone_action = true } }) == "Unknown action",
    "erroring Dispatcher gives Unknown action")
check(Actions.label(nil) == "Unknown action", "nil action")
check(Actions.label({ kind = "key" }) == "Unknown action", "key action without a name")
dispatcherMode = "ok"
check(Actions.label({ kind = "dispatcher", actions = { gone_action = true } }) == "Unknown action",
    "Unknown item from Dispatcher gives Unknown action")
check(Actions.label({ kind = "dispatcher", actions = { other = true } }) == "Title for other",
    "Dispatcher title fallback")

local ex = Actions.excludedCategories("filemanager")
check(ex.reader and ex.paging and ex.rolling and ex.document, "filemanager hides reader categories")
check(next(Actions.excludedCategories("reader")) == nil, "reader hides nothing")

if failures > 0 then os.exit(1) end
print("keys_actions_test: ok")
