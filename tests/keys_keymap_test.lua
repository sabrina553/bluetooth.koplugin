-- Run from the repo root: luajit tests/keys_keymap_test.lua
package.path = "bluetooth.koplugin/?.lua;tests/?.lua;" .. package.path
local rejectDescription = require("helpers").rejectDescription
local warnings = 0
package.preload["logger"] = function()
    local noop = function() end
    return { dbg = noop, info = noop, err = noop, warn = function() warnings = warnings + 1 end }
end
local executed, throw = {}, false
package.preload["dispatcher"] = function()
    return {
        init = function() end,
        execute = function(_, actions)
            if throw then error("boom") end
            executed[#executed + 1] = actions
        end,
    }
end

local Keymap = require("bluetooth/keys/keymap")

local failures = 0
local function check(cond, message)
    rejectDescription(cond)
    if not cond then failures = failures + 1; print("FAIL " .. message) end
end

local function key(code, name, screens)
    return { code = code, screens = screens or { reader = true, filemanager = true },
             action = { kind = "key", name = name } }
end

-- Key binding over an existing name, then restore.
local em = { [108] = "LPgFwd", [1] = "Back" }
Keymap.apply(em, Keymap.resolve({ R = { key(108, "Down") } }, { "R" }, "reader"))
check(em[108] == "Down", "key binding writes the native name")
check(Keymap.outsideName(em, 108) == "LPgFwd", "outsideName keeps the original while applied")
check(em[1] == "Back", "untouched code unchanged while applied")
Keymap.restoreAll(em)
check(em[108] == "LPgFwd", "restoreAll brings the original back")
check(em[1] == "Back", "untouched code unchanged after restore")

-- Originally nil.
em = { [1] = "Back" }
Keymap.apply(em, Keymap.resolve({ R = { key(109, "Up") } }, { "R" }, "reader"))
check(em[109] == "Up", "nil code gets named")
check(Keymap.outsideName(em, 109) == nil, "outsideName nil for unnamed code")
Keymap.restoreAll(em)
check(em[109] == nil, "nil original restored as nil")
check(em[1] == "Back", "untouched code still unchanged")

-- Re-apply with an empty map removes stale entries.
em = { [108] = "LPgFwd" }
Keymap.apply(em, Keymap.resolve({ R = { key(108, "Down") } }, { "R" }, "reader"))
Keymap.apply(em, {})
check(em[108] == "LPgFwd", "re-apply with empty map restores")
-- A later apply must not record the plugin's own name as the original.
Keymap.apply(em, Keymap.resolve({ R = { key(108, "Down") } }, { "R" }, "reader"))
Keymap.apply(em, Keymap.resolve({ R = { key(108, "Up") } }, { "R" }, "reader"))
Keymap.restoreAll(em)
check(em[108] == "LPgFwd", "re-applying a code keeps the first original")

-- Per-screen fallback.
em = { [108] = "LPgFwd" }
local map = Keymap.resolve({ R = { key(108, "Down", { reader = true }) } }, { "R" }, "filemanager")
check(map[108] == nil, "reader-only binding absent on filemanager")
Keymap.apply(em, map)
check(Keymap.outsideName(em, 108) == "LPgFwd" and em[108] == "LPgFwd", "outside name stays")

-- Clash: later remote wins.
local clashes
map, clashes = Keymap.resolve({ A = { key(108, "Down") }, B = { key(108, "Up") } }, { "A", "B" }, "reader")
check(map[108].action.name == "Up", "later remote wins a clash")
check(#clashes == 1 and clashes[1].code == 108 and #clashes[1].remotes == 2, "one clash reported")
map, clashes = Keymap.resolve({ A = { key(108, "Down") } }, { "A", "B" }, "reader")
check(#clashes == 0 and map[108].action.name == "Down", "inactive remote without bindings is fine")
map = Keymap.resolve({ A = { key(108, "Down") } }, {}, "reader")
check(next(map) == nil, "unconnected remote is inactive")

-- Dispatcher binding and run.
em = { [108] = "LPgFwd" }
local d = { code = 108, screens = { reader = true }, action = { kind = "dispatcher", actions = { page_jmp = 1 } } }
Keymap.apply(em, Keymap.resolve({ R = { d } }, { "R" }, "reader"))
check(em[108] == "BTKey108", "dispatcher binding writes the slot name")
check(Keymap.run(108) == true, "run returns true")
check(#executed == 1 and executed[1].page_jmp == 1, "run executes the stored actions")
throw = true
local before = warnings
check(Keymap.run(108) == true, "run returns true when dispatcher throws")
check(warnings == before + 1, "failed run logs a warning")
check(Keymap.run(999) == true, "run on unknown code is harmless")
Keymap.restoreAll(em)
check(em[108] == "LPgFwd", "dispatcher binding restored")

if failures > 0 then os.exit(1) end
print("keys_keymap_test: ok")
