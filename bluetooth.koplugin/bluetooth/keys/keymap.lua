local logger = require("logger")

--- Turns bindings into entries in KOReader's live Device.input.event_map and
--- puts the originals back. State is module-level because main.lua builds a
--- new plugin on every view change (decision 2026-10-28).
--- Slot/dispatch approach adapted from titandrive/bluetoothconfigurator.koplugin
--- (MIT), see CREDITS.md.
---@class BluetoothKeymap
local Keymap = {}

Keymap.SLOT_PREFIX = "BTKey"

-- code -> { value = original event_map value (may be nil) }
Keymap._originals = {}
-- code -> binding currently applied
Keymap._applied = {}

--- Active bindings for `screen`. Later remotes in `active_remotes` win clashes.
function Keymap.resolve(by_remote, active_remotes, screen)
    local map, owners, clashes, clashed = {}, {}, {}, {}
    for _, remote in ipairs(active_remotes) do
        for _, b in ipairs(by_remote[remote] or {}) do
            if b.screens and b.screens[screen] then
                if map[b.code] then
                    local c = clashed[b.code]
                    if not c then
                        c = { code = b.code, remotes = { owners[b.code] } }
                        clashed[b.code] = c
                        clashes[#clashes + 1] = c
                    end
                    c.remotes[#c.remotes + 1] = remote
                end
                map[b.code] = b
                owners[b.code] = remote
            end
        end
    end
    return map, clashes
end

local function nameFor(binding)
    if binding.action.kind == "dispatcher" then
        return Keymap.SLOT_PREFIX .. binding.code
    end
    return binding.action.name
end

local function restoreCode(event_map, code)
    local o = Keymap._originals[code]
    if o then event_map[code] = o.value end
    Keymap._originals[code] = nil
    Keymap._applied[code] = nil
end

function Keymap.apply(event_map, map)
    for code in pairs(Keymap._applied) do
        if not map[code] then restoreCode(event_map, code) end
    end
    for code, b in pairs(map) do
        if not Keymap._originals[code] then
            Keymap._originals[code] = { value = event_map[code] }
        end
        event_map[code] = nameFor(b)
        Keymap._applied[code] = b
    end
end

function Keymap.restoreAll(event_map)
    local codes = {}
    for code in pairs(Keymap._applied) do codes[#codes + 1] = code end
    for _, code in ipairs(codes) do restoreCode(event_map, code) end
end

--- The name `code` had before the plugin touched it.
function Keymap.outsideName(event_map, code)
    local o = Keymap._originals[code]
    if o then return o.value end
    return event_map[code]
end

function Keymap.run(code)
    local b = Keymap._applied[code]
    if not b or b.action.kind ~= "dispatcher" then return true end
    local ok, err = pcall(function()
        -- Heavy, so loaded on first press only.
        local Dispatcher = require("dispatcher")
        Dispatcher:init()
        Dispatcher:execute(b.action.actions)
    end)
    if not ok then logger.warn("Bluetooth keymap: action failed for code", code, err) end
    return true
end

return Keymap
