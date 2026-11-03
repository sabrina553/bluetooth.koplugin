-- Run from the repo root: luajit tests/keys_menu_test.lua
-- Widgets are stubbed; shown dialogs are recorded and their buttons pressed
-- by text. Capture and the store are fakes.
package.path = "bluetooth.koplugin/?.lua;tests/?.lua;" .. package.path
local rejectDescription = require("helpers").rejectDescription
package.preload["gettext"] = function() return function(s) return s end end
package.preload["logger"] = function()
    local noop = function() end
    return { dbg = noop, info = noop, warn = noop, err = noop }
end
package.preload["ffi/util"] = function()
    return { template = function(s, ...) local a = { ... }; return (s:gsub("%%(%d)", function(i) return tostring(a[tonumber(i)]) end)) end }
end
local shown = {}
package.preload["ui/uimanager"] = function()
    return {
        _window_stack = {},
        show = function(_, w) table.insert(shown, w) end,
        close = function() end,
        nextTick = function(_, fn) fn() end,
        scheduleIn = function() end,
        unschedule = function() end,
    }
end
for _, name in ipairs({ "ui/widget/infomessage", "ui/widget/buttondialog", "ui/widget/menu" }) do
    package.preload[name] = function() return { new = function(_, o) return o or {} end } end
end
local event_map = {}
package.preload["device"] = function()
    return { input = { event_map = event_map },
        screen = { getWidth = function() return 600 end, getHeight = function() return 800 end } }
end
-- Dispatcher builds one category with one action.
package.preload["dispatcher"] = function()
    return {
        init = function() end,
        getNameFromItem = function(_, id) return id end,
        addSubMenu = function(_, _, menu, location, settings)
            table.insert(menu, { text = "General", sub_item_table = {
                { text = "Go home", callback = function() location[settings].home = true end },
            } })
            table.insert(menu, { text = "Reader", sub_item_table = {} })
        end,
    }
end
local listening
package.preload["bluetooth/keys/capture"] = function()
    return { listen = function(cb) listening = cb end, stop = function() end }
end

local KeysMenu = require("bluetooth/ui/keys_menu")

local failures = 0
local function check(cond, message)
    rejectDescription(cond)
    if not cond then failures = failures + 1; print("FAIL " .. message) end
end

local function fakeStore(data)
    local s = { data = data or {}, calls = {} }
    function s:remotes() local r = {}; for k in pairs(self.data) do r[#r + 1] = k end; table.sort(r); return r end
    function s:list(remote) return self.data[remote] or {} end
    for _, m in ipairs({ "set", "remove", "split" }) do
        s[m] = function(self, ...) table.insert(self.calls, { m, ... }) end
    end
    function s:count(m) local n = 0; for _, c in ipairs(self.calls) do if c[1] == m then n = n + 1 end end; return n end
    function s:find(m) for _, c in ipairs(self.calls) do if c[1] == m then return c end end end
    return s
end

local function last() return shown[#shown] or {} end
local function lastText() local w = last(); return w.text or w.title or "" end
local function press(text)
    for _, row in ipairs(last().buttons or {}) do
        for _, b in ipairs(row) do
            if b.text == text then b.callback(); return true end
        end
    end
    print("no button " .. text .. " in: " .. lastText())
    return false
end

local function setup(devices, data)
    shown, listening = {}, nil
    for k in pairs(event_map) do event_map[k] = nil end
    local changes = 0
    local store = fakeStore(data)
    local m = KeysMenu:new({ store = store, controller = { known_devices = devices },
        on_change = function() changes = changes + 1 end })
    return m, store, function() return changes end
end

-- No connected remote: a message, no listen.
do
    local m, store = setup({ { name = "Remote", connected = false } })
    m:startBind()
    check(lastText():find("Connect a remote first", 1, true) ~= nil, "none: message")
    check(listening == nil, "none: did not listen")
end

-- One remote, press 108, Both + Page forward.
do
    local m, store, changes = setup({ { name = "Remote", connected = true } })
    m:startBind()
    check(listening ~= nil, "one: listening")
    listening(108)
    press("Both")
    press("Keys")
    press("Page forward")
    local c = store:find("set")
    check(c and c[2] == "Remote", "one: set for the remote")
    check(c and c[3].code == 108 and c[3].screens.reader and c[3].screens.filemanager, "one: both screens")
    check(c and c[3].action.kind == "key" and c[3].action.name == "LPgFwd", "one: key action")
    check(changes() == 1, "one: on_change once")
end

-- Outside name: warned, "no" stores nothing.
do
    local m, store = setup({ { name = "Remote", connected = true } })
    event_map[108] = "LPgFwd"
    m:startBind()
    listening(108)
    check(lastText():find("LPgFwd", 1, true) ~= nil, "outside: warning names it")
    press("No")
    check(#store.calls == 0, "outside: nothing stored")
end

-- Two connected remotes: the remote choice comes before the screen and action.
do
    local m, store = setup({ { name = "A", connected = true }, { name = "B", connected = true } })
    m:startBind()
    listening(108)
    check(press("B"), "two: remote choice shown")
    press("Reader")
    press("Keys")
    press("Page back")
    local c = store:find("set")
    check(c and c[2] == "B" and c[3].screens.reader and not c[3].screens.filemanager, "two: chosen remote, reader only")
end

-- Timeout: message, nothing stored.
do
    local m, store = setup({ { name = "Remote", connected = true } })
    m:startBind()
    listening(nil)
    check(lastText():find("No button pressed", 1, true) ~= nil, "timeout: message")
    check(#store.calls == 0, "timeout: nothing stored")
end

-- A choice from the full Dispatcher picker reaches store:set.
do
    local m, store = setup({ { name = "Remote", connected = true } })
    m:startBind()
    listening(30)
    press("Reader")
    press("All actions…")
    local picker = last()
    check(picker.item_table and #picker.item_table == 2, "dispatcher: categories shown")
    picker.item_table_stack = {}
    picker.switchItemTable = function(self, _, t) self.item_table = t end
    picker.onClose = picker.onClose or function() end
    picker:onMenuSelect(picker.item_table[1])
    picker:onMenuSelect(picker.item_table[1])
    local c = store:find("set")
    check(c and c[3].action.kind == "dispatcher" and c[3].action.actions.home == true, "dispatcher: stored")
end

-- File browser: Reader-only categories are filtered out.
do
    local m = setup({ { name = "Remote", connected = true } })
    m:startBind()
    listening(30)
    press("File browser")
    press("All actions…")
    check(#last().item_table == 1, "dispatcher: reader category hidden in file browser")
end

-- Binding one screen over a linked binding keeps the other screen.
do
    local data = { Remote = { { code = 108, screens = { reader = true, filemanager = true }, action = { kind = "key", name = "LPgFwd" } } } }
    local m, store = setup({ { name = "Remote", connected = true } }, data)
    m:startBind()
    listening(108)
    press("Reader")
    press("Keys")
    press("Up")
    local c = store:find("split")
    check(c and c[4] == "reader" and c[5].name == "Up", "one screen over linked: split")
    check(store:count("set") == 0, "one screen over linked: no set")
end

-- The list shows a disconnected remote's binding.
do
    local data = { Old = { { code = 108, screens = { reader = true }, action = { kind = "key", name = "LPgFwd" } } } }
    local m = setup({}, data)
    local reader = m:menuTable()[2].sub_item_table_func()
    check(reader[1] and reader[1].text:find("(not connected)", 1, true) ~= nil, "list: not connected shown")
    check(reader[1] and reader[1].text:find("Old: 108", 1, true) ~= nil, "list: remote and code")
    local fm = m:menuTable()[3].sub_item_table_func()
    check(fm[1] and fm[1].enabled == false, "list: file browser has no binding row")
end

-- Changing a linked binding, "only here": split.
do
    local data = { Remote = { { code = 108, screens = { reader = true, filemanager = true }, action = { kind = "key", name = "LPgFwd" } } } }
    local m, store, changes = setup({ { name = "Remote", connected = true } }, data)
    local row = m:menuTable()[3].sub_item_table_func()[1]
    check(row.text:find("(both)", 1, true) ~= nil, "linked: marked both")
    row.callback()
    press("Change action")
    press("Only here")
    press("Keys")
    press("Down")
    local c = store:find("split")
    check(c and c[2] == "Remote" and c[3] == 108 and c[4] == "filemanager" and c[5].name == "Down", "linked: split only here")
    check(changes() == 1, "linked: on_change")
end

-- Remove from one screen.
do
    local data = { Remote = { { code = 108, screens = { reader = true }, action = { kind = "key", name = "LPgFwd" } } } }
    local m, store = setup({ { name = "Remote", connected = true } }, data)
    m:menuTable()[2].sub_item_table_func()[1].callback()
    press("Remove")
    local c = store:find("remove")
    check(c and c[3] == 108 and c[4] == "reader", "remove: this screen")
end

-- A "(not connected)" row is still tappable and can be removed.
do
    local data = { Old = { { code = 108, screens = { reader = true }, action = { kind = "key", name = "LPgFwd" } } } }
    local m, store = setup({}, data)
    local row = m:menuTable()[2].sub_item_table_func()[1]
    check(row.enabled ~= false, "stale: row tappable")
    row.callback()
    press("Remove")
    local c = store:find("remove")
    check(c and c[2] == "Old" and c[3] == 108 and c[4] == "reader", "stale: removed")
end

-- Remove on a linked binding asks; "Both screens" removes both.
do
    local data = { Remote = { { code = 108, screens = { reader = true, filemanager = true }, action = { kind = "key", name = "LPgFwd" } } } }
    local m, store = setup({ { name = "Remote", connected = true } }, data)
    m:menuTable()[2].sub_item_table_func()[1].callback()
    press("Remove")
    check(lastText():find("Remove from both screens", 1, true) ~= nil, "linked remove: asks")
    press("Both screens")
    check(store:count("remove") == 2, "linked remove: both screens")
end

-- Changing a linked binding on both screens: set with both.
do
    local data = { Remote = { { code = 108, screens = { reader = true, filemanager = true }, action = { kind = "key", name = "LPgFwd" } } } }
    local m, store = setup({ { name = "Remote", connected = true } }, data)
    m:menuTable()[2].sub_item_table_func()[1].callback()
    press("Change action")
    press("Both screens")
    press("Keys")
    press("Up")
    local c = store:find("set")
    check(c and c[3].screens.reader and c[3].screens.filemanager and c[3].action.name == "Up", "linked change: both")
    check(store:count("split") == 0, "linked change: no split")
end

-- "Both" over two one-screen bindings clears them, then sets one linked.
do
    local data = { Remote = {
        { code = 108, screens = { reader = true }, action = { kind = "key", name = "Up" } },
        { code = 108, screens = { filemanager = true }, action = { kind = "key", name = "Down" } } } }
    local m, store = setup({ { name = "Remote", connected = true } }, data)
    m:startBind()
    listening(108)
    press("Both")
    press("Keys")
    press("Left")
    check(store:count("remove") == 2, "both over singles: cleared")
    local c = store:find("set")
    check(c and c[3].screens.reader and c[3].screens.filemanager, "both over singles: linked set")
end

-- Back in a Dispatcher category goes up; at the top it closes.
do
    local m, store = setup({ { name = "Remote", connected = true } })
    m:startBind()
    listening(30)
    press("Reader")
    press("All actions…")
    local picker = last()
    local top = picker.item_table
    picker.item_table_stack = {}
    picker.switchItemTable = function(self, _, t) self.item_table = t end
    picker:onMenuSelect(top[1])
    picker:onClose()
    check(picker.item_table == top, "back: up one level")
    picker:onClose()
    check(store:count("set") == 0, "back: closed with nothing chosen")
end

-- Back at every step returns to the step before (decision 2026-11-03).
do
    local m, store = setup({ { name = "A", connected = true }, { name = "B", connected = true } })
    local entry = m:menuTable()[1]
    check(entry.keep_menu_open == true, "back: Bind keeps the Buttons menu open")
    m:startBind()
    listening(108)
    check(press("Cancel"), "back: first step offers Cancel")
    m:startBind()
    listening(108)
    press("B")
    check(press("« Back") and lastText() == "Which remote?", "back: screen -> remote")
    press("B")
    press("Reader")
    check(press("« Back") and lastText() == "Use it on which screen?", "back: action type -> screen")
    press("Reader")
    press("Keys")
    check(press("« Back") and lastText() == "Choose an action", "back: keys -> action type")
    press("All actions…")
    local picker = last()
    picker.item_table_stack = {}
    picker:onClose()
    check(lastText() == "Choose an action", "back: empty Dispatcher picker -> action type")
    press("Keys")
    press("Page back")
    local c = store:find("set")
    check(c and c[2] == "B" and c[3].screens.reader and not c[3].screens.filemanager, "back: still saves after going back")
end

-- One remote: the screen step comes first, so it offers Cancel.
do
    local m = setup({ { name = "Remote", connected = true } })
    m:startBind()
    listening(108)
    check(press("Cancel"), "back: one remote, screen step offers Cancel")
end

-- An outside binding: Back from the screen step reopens the warning.
do
    local m = setup({ { name = "Remote", connected = true } })
    event_map[108] = "LPgFwd"
    m:startBind()
    listening(108)
    press("Yes")
    check(press("« Back") and lastText():find("already works as", 1, true) ~= nil, "back: screen -> outside warning")
end

-- Editing: Back reaches the edit dialog, and a removal redraws the open list.
do
    local data = { Remote = { { code = 108, screens = { reader = true, filemanager = true }, action = { kind = "key", name = "LPgFwd" } } } }
    local m, store = setup({ { name = "Remote", connected = true } }, data)
    local row = m:menuTable()[2].sub_item_table_func()[1]
    check(row.keep_menu_open == true, "edit: list stays open")
    local redrawn = 0
    local touchmenu = { updateItems = function() redrawn = redrawn + 1 end }
    row.callback(touchmenu)
    press("Change action")
    press("Only here")
    check(press("« Back") and lastText() == "Change on both screens, or only here?", "edit: action type -> scope")
    check(press("« Back") and lastText():find("button 108", 1, true) ~= nil, "edit: scope -> edit dialog")
    press("Remove")
    check(press("« Back") and lastText():find("button 108", 1, true) ~= nil, "edit: remove scope -> edit dialog")
    press("Remove")
    press("Both screens")
    check(redrawn == 1 and touchmenu.item_table ~= nil, "edit: list redrawn after removing")
end

if failures > 0 then
    print(failures .. " failure(s)")
    os.exit(1)
end
print("all keys menu tests passed")
