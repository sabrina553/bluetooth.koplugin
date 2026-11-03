-- Run from the repo root: luajit tests/keys_wiring_test.lua
package.path = "bluetooth.koplugin/?.lua;tests/?.lua;" .. package.path
local rejectDescription = require("helpers").rejectDescription

local warns = {}
package.preload["logger"] = function()
    local noop = function() end
    return { dbg = noop, info = noop, err = noop,
        warn = function(...) warns[#warns + 1] = table.concat({ ... }, " ") end }
end
package.preload["gettext"] = function() return function(s) return s end end
package.preload["ui/uimanager"] = function()
    return { scheduleIn = function() end, unschedule = function() end, nextTick = function() end }
end

local function class()
    local C = {}
    function C:extend(o)
        o = o or {}
        setmetatable(o, self)
        self.__index = self
        return o
    end
    function C:new(o)
        o = o or {}
        setmetatable(o, self)
        self.__index = self
        if o.init then o:init() end
        return o
    end
    return C
end
package.preload["ui/widget/container/widgetcontainer"] = function() return class() end
local input_onkeypress_calls = 0
package.preload["ui/widget/container/inputcontainer"] = function()
    return { onKeyPress = function(self)
        assert(type(self.key_events) == "table", "key_events must be a table")
        input_onkeypress_calls = input_onkeypress_calls + 1
    end }
end

local hooks = 0
local event_map = { [108] = "LPgFwd" }
package.preload["device"] = function()
    return { input = {
        event_map = event_map,
        registerEventAdjustHook = function() hooks = hooks + 1 end,
    } }
end
package.preload["bluetooth/controller/backend_select"] = function()
    return { select = function() return true end }
end

local remote = { name = "Kobo Remote", connected = true }
local read_waiter
local shared_controller = { known_devices = { remote },
    knownDevices = function(_, cb) read_waiter = cb end }
package.preload["bluetooth/controller/controller"] = function()
    return { new = function() return shared_controller end }
end
local last_menu
package.preload["bluetooth/ui/menu"] = function()
    return { new = function(_, o) last_menu = o; o.stopLiveMonitor = function() end; return o end }
end
local last_keys_menu
package.preload["bluetooth/ui/keys_menu"] = function()
    return { new = function(_, o) last_keys_menu = o; return o end }
end
local simple = function() return { new = function(_, o) return o or {} end } end
package.preload["bluetooth/settings"] = simple
package.preload["bluetooth/devicestore"] = simple
package.preload["bluetooth/ota/github_api"] = simple
package.preload["bluetooth/ota/self_updater"] = simple
package.preload["bluetooth/session"] = function() return { isColdStart = function() return false end } end

local bindings = {}
package.preload["bluetooth/keys/store"] = function()
    return { new = function() return {
        list = function(_, r) return bindings[r] or {} end,
        remotes = function() return { "Kobo Remote" } end,
    } end }
end

local Keymap = require("bluetooth/keys/keymap")
local Bluetooth = require("main")

local failures = 0
local function check(cond, message)
    rejectDescription(cond)
    if not cond then failures = failures + 1; print("FAIL " .. message) end
end

local function newPlugin(ui)
    return Bluetooth:new({ ui = ui or { menu = { registerToMainMenu = function() end } } })
end

bindings["Kobo Remote"] = { { code = 108, screens = { reader = true, filemanager = true },
    action = { kind = "key", name = "Down" } } }
local p = newPlugin()
check(event_map[108] == "Down", "init applies a key binding")
check(hooks == 1, "init registers the capture hook")
check(last_menu.keys_menu == last_keys_menu, "keys menu passed to the Bluetooth menu")

p = newPlugin()
check(hooks == 1, "second init (view change) does not register a second hook")
check(event_map[108] == "Down", "binding still applied after a view change")

remote.connected = false
p:applyKeys()
check(event_map[108] == "LPgFwd", "disconnecting restores the original name")
remote.connected = true

-- Dispatcher binding, reader only, while the plugin sits in a book.
bindings["Kobo Remote"] = { { code = 108, screens = { reader = true },
    action = { kind = "dispatcher", actions = { next_chapter = true } } } }
local ui = { document = {}, menu = { registerToMainMenu = function() end } }
p = newPlugin(ui)
check(event_map[108] == "BTKey108", "dispatcher binding maps to its slot")
check(type(p.key_events) == "table" and p.key_events.BTKey108 ~= nil, "slot key event registered")
local ran
local real_run = Keymap.run
Keymap.run = function(code) ran = code; return true end
check(type(p.onBTKey108) == "function" and p:onBTKey108() == true and ran == 108, "onBTKey108 calls Keymap.run")
Keymap.run = real_run
p:onKeyPress({})
check(input_onkeypress_calls == 1, "key presses go through InputContainer's matcher")

-- The same binding is inactive in the file browser, and its slot goes away.
local fm = newPlugin()
check(event_map[108] == "LPgFwd", "reader-only binding not applied in the file browser")
check(fm.key_events.BTKey108 == nil, "no slot handler for an inactive code")

-- on_change re-applies.
bindings["Kobo Remote"] = { { code = 103, screens = { filemanager = true },
    action = { kind = "key", name = "Up" } } }
last_keys_menu.on_change()
check(event_map[103] == "Up" and event_map[108] == "LPgFwd", "on_change re-applies the bindings")

-- Clash between two connected remotes: WARN names remotes only.
local other = { name = "Page Turner", connected = true, mac = "AA:BB:CC:DD:EE:FF" }
shared_controller.known_devices[2] = other
bindings["Page Turner"] = { { code = 103, screens = { filemanager = true },
    action = { kind = "key", name = "Down" } } }
warns = {}
fm:applyKeys()
check(event_map[103] == "Down", "later remote in the list wins a clash")
check(#warns == 1 and warns[1]:find("Page Turner", 1, true) and not warns[1]:find("AA:BB", 1, true),
    "clash WARN names the remotes, not MACs")

-- A closed instance (old view) must not apply its screen's map from a stale callback.
bindings["Kobo Remote"] = { { code = 108, screens = { reader = true },
    action = { kind = "key", name = "Down" } } }
shared_controller.known_devices[2] = nil
local old = newPlugin({ document = {}, menu = { registerToMainMenu = function() end } })
check(event_map[108] == "Down", "reader instance applies its map")
old:onCloseWidget()
local cur = newPlugin()
check(event_map[108] == "LPgFwd", "file browser instance restores the name")
old:applyKeys()
check(event_map[108] == "LPgFwd", "closed instance's stale callback does not apply its map")
check(cur.key_events.BTKey108 == nil and old.closed == true, "closed instance marked")

-- A view change starts with no devices; the binding lands when the first read does.
bindings["Kobo Remote"] = { { code = 108, screens = { reader = true, filemanager = true },
    action = { kind = "key", name = "Down" } } }
local saved_devices = shared_controller.known_devices
shared_controller.known_devices = {}
read_waiter = nil
newPlugin()
check(event_map[108] == "LPgFwd", "no binding before the first read")
shared_controller.known_devices = saved_devices
check(read_waiter ~= nil, "init waits for the first device read")
if read_waiter then read_waiter(true) end
check(event_map[108] == "Down", "first device read applies the binding")

-- onKeyPress before any applyKeys must hand the matcher a table.
local bare = setmetatable({}, { __index = Bluetooth })
check(pcall(bare.onKeyPress, bare, {}), "onKeyPress defaults key_events to a table")

if failures > 0 then
    print(failures .. " failure(s)")
    os.exit(1)
end
print("keys_wiring_test: all passed")
