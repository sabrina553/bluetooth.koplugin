local _ = require("gettext")
local T = require("ffi/util").template

local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local ButtonDialog = require("ui/widget/buttondialog")

local Actions = require("bluetooth/keys/actions")
local Capture = require("bluetooth/keys/capture")
local Keymap = require("bluetooth/keys/keymap")

--- The Buttons menu: bind, list, change and remove remote button bindings
--- (decision 2026-10-28). Remotes are named by Bluetooth name, never by MAC.
---@class BluetoothKeysMenu
local KeysMenu = {}

local BOTH = { reader = true, filemanager = true }

local function isLinked(b) return b.screens.reader and b.screens.filemanager end

local function copy(v)
    if type(v) ~= "table" then return v end
    local c = {}
    for k, x in pairs(v) do c[k] = copy(x) end
    return c
end

local function message(text)
    UIManager:show(InfoMessage:new{ text = text, timeout = 2 })
end

--- A dialog of one-button rows; each choice closes it and calls `fn(value)`.
local function choose(title, choices, fn)
    local dialog
    local rows = {}
    for _i, c in ipairs(choices) do
        rows[#rows + 1] = { {
            text = c.text,
            callback = function()
                UIManager:close(dialog)
                fn(c.value)
            end,
        } }
    end
    rows[#rows + 1] = { { text = _("Cancel"), callback = function() UIManager:close(dialog) end } }
    dialog = ButtonDialog:new{ title = title, buttons = rows }
    UIManager:show(dialog)
end

function KeysMenu:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    o.on_change = o.on_change or function() end
    return o
end

function KeysMenu:connectedRemotes()
    local names, seen = {}, {}
    for _i, dev in ipairs(self.controller.known_devices or {}) do
        if dev.connected and dev.name and dev.name ~= "" and not seen[dev.name] then
            seen[dev.name] = true
            names[#names + 1] = dev.name
        end
    end
    return names, seen
end

function KeysMenu:eventMap()
    local ok, Device = pcall(require, "device")
    return ok and Device.input and Device.input.event_map or {}
end

--- Full Dispatcher picker, built by Dispatcher's own menu builder.
--- Adapted from titandrive/bluetoothconfigurator.koplugin showActionPicker
--- (MIT, Copyright (c) titandrive), see CREDITS.md. Only the TouchMenu-style
--- select handling is kept: plain Menu calls callback() without a TouchMenu
--- and ignores sub_item_table_func.
function KeysMenu:pickDispatcher(screen, done)
    local Menu = require("ui/widget/menu")
    local Device = require("device")
    local Dispatcher = require("dispatcher")
    Dispatcher:init()
    local location = { actions = {} }
    local built = {}
    Dispatcher:addSubMenu({}, built, location, "actions")
    local excluded = Actions.excludedCategories(screen)
    local items = {}
    -- Only categories: the rows Dispatcher appends after them manage sets of
    -- actions, which a single button press doesn't use.
    for _i, entry in ipairs(built) do
        if entry.sub_item_table and not excluded[tostring(entry.text):lower()] then
            items[#items + 1] = entry
        end
    end
    local finished = false
    local picker
    local function finish()
        if finished then return end
        finished = true
        UIManager:close(picker)
        if next(location.actions) then
            done({ kind = "dispatcher", actions = copy(location.actions) })
        end
    end
    picker = Menu:new{
        title = _("Choose an action"),
        item_table = items,
        width = Device.screen:getWidth(),
        height = Device.screen:getHeight(),
        is_popout = false,
        is_borderless = true,
        covers_fullscreen = true,
    }
    picker.onMenuSelect = function(menu, item)
        local sub = item.sub_item_table_func and item.sub_item_table_func() or item.sub_item_table
        if sub then
            menu.item_table.title = menu.title
            table.insert(menu.item_table_stack, menu.item_table)
            menu:switchItemTable(item.text, sub)
            return true
        end
        if not item.callback then return true end
        local depth = #(UIManager._window_stack or {})
        item.callback(menu)
        -- A value picker (e.g. "Turn pages") opened on top: wait for close.
        if item.keep_menu_open or #(UIManager._window_stack or {}) > depth then
            if menu.updateItems then menu:updateItems() end
        else
            finish()
        end
        return true
    end
    picker.onClose = function() finish(); return true end
    UIManager:show(picker)
end

--- Action choice for `scope` ("reader", "filemanager" or "both").
function KeysMenu:pickAction(scope, done)
    local function keys()
        local list = {}
        for _i, k in ipairs(Actions.keys()) do
            list[#list + 1] = { text = k.text, value = { kind = "key", name = k.name } }
        end
        choose(_("Keys"), list, done)
    end
    local function common()
        local entries = scope == "both" and Actions.forBoth() or Actions.common(scope)
        local list = {}
        for _i, e in ipairs(entries) do
            list[#list + 1] = { text = e.text, value = { kind = "dispatcher", actions = copy(e.actions) } }
        end
        choose(_("Common"), list, done)
    end
    local choices = { { text = _("Keys"), value = keys }, { text = _("Common"), value = common } }
    -- Both screens: only actions valid on both, so no dead binding.
    if scope ~= "both" then
        choices[#choices + 1] = { text = _("All actions…"), value = function() self:pickDispatcher(scope, done) end }
    end
    choose(_("Choose an action"), choices, function(fn) fn() end)
end

function KeysMenu:findBinding(remote, code, screen)
    for _i, b in ipairs(self.store:list(remote)) do
        if b.code == code and b.screens[screen] then return b end
    end
end

--- Saves without wiping another screen's binding: Store:set replaces any
--- overlapping binding, so a one-screen bind over a linked one is a split.
function KeysMenu:save(remote, code, scope, action)
    if scope ~= "both" then
        local b = self:findBinding(remote, code, scope)
        if b and isLinked(b) then
            self.store:split(remote, code, scope, action)
        else
            self.store:set(remote, { code = code, screens = { [scope] = true }, action = action })
        end
    else
        -- Two one-screen bindings for this code would both overlap; clear
        -- them so the linked one is the only one left.
        for screen in pairs(BOTH) do
            local b = self:findBinding(remote, code, screen)
            if b and not isLinked(b) then self.store:remove(remote, code, screen) end
        end
        self.store:set(remote, { code = code, screens = copy(BOTH), action = action })
    end
    self.on_change()
end

function KeysMenu:startBind()
    local remotes = self:connectedRemotes()
    if #remotes == 0 then
        message(_("Connect a remote first"))
        return
    end
    local listening = InfoMessage:new{ text = _("Press a button on the remote…") }
    UIManager:show(listening)
    Capture.listen(function(code)
        UIManager:close(listening)
        if not code then
            message(_("No button pressed"))
            return
        end
        self:afterPress(remotes, code)
    end)
end

function KeysMenu:afterPress(remotes, code)
    local function pickScope(remote)
        choose(_("Use it on which screen?"), {
            { text = _("Reader"), value = "reader" },
            { text = _("File browser"), value = "filemanager" },
            { text = _("Both"), value = "both" },
        }, function(scope)
            self:pickAction(scope, function(action) self:save(remote, code, scope, action) end)
        end)
    end
    local function pickRemote()
        if #remotes == 1 then return pickScope(remotes[1]) end
        local list = {}
        for _i, name in ipairs(remotes) do list[#list + 1] = { text = name, value = name } end
        choose(_("Which remote?"), list, pickScope)
    end
    local outside = Keymap.outsideName(self:eventMap(), code)
    if outside then
        choose(T(_("This button already works as %1 (set outside this plugin). Bind it here anyway?"), outside),
            { { text = _("Yes"), value = true }, { text = _("No"), value = false } },
            function(yes) if yes then pickRemote() end end)
    else
        pickRemote()
    end
end

function KeysMenu:changeBinding(remote, b, screen)
    local function pick(scope)
        self:pickAction(scope, function(action)
            if scope == "both" then
                self.store:set(remote, { code = b.code, screens = copy(BOTH), action = action })
            elseif isLinked(b) then
                self.store:split(remote, b.code, screen, action)
            else
                self.store:set(remote, { code = b.code, screens = { [screen] = true }, action = action })
            end
            self.on_change()
        end)
    end
    if isLinked(b) then
        choose(_("Change on both screens, or only here?"), {
            { text = _("Both screens"), value = "both" },
            { text = _("Only here"), value = screen },
        }, pick)
    else
        pick(screen)
    end
end

function KeysMenu:editBinding(remote, b, screen)
    choose(T(_("%1: button %2"), remote, b.code), {
        { text = _("Change action"), value = function() self:changeBinding(remote, b, screen) end },
        { text = _("Remove"), value = function()
            self.store:remove(remote, b.code, screen)
            self.on_change()
        end },
    }, function(fn) fn() end)
end

function KeysMenu:bindingRows(screen)
    local _names, connected = self:connectedRemotes()
    local rows = {}
    for _i, remote in ipairs(self.store:remotes()) do
        for _j, b in ipairs(self.store:list(remote)) do
            if b.screens[screen] then
                local text = T("%1: %2 → %3", remote, b.code, Actions.label(b.action))
                if isLinked(b) then text = text .. " " .. _("(both)") end
                -- Kept and listed while the remote is away (decision 2026-10-28).
                local active = connected[remote] == true
                if not active then text = text .. " " .. _("(not connected)") end
                rows[#rows + 1] = {
                    text = text,
                    enabled = active,
                    callback = function() self:editBinding(remote, b, screen) end,
                }
            end
        end
    end
    if #rows == 0 then rows[1] = { text = _("No buttons bound"), enabled = false } end
    return rows
end

function KeysMenu:menuTable()
    return {
        {
            text = _("Bind a button…"),
            callback = function() self:startBind() end,
            separator = true,
        },
        {
            text = _("Reader buttons"),
            sub_item_table_func = function() return self:bindingRows("reader") end,
        },
        {
            text = _("File browser buttons"),
            sub_item_table_func = function() return self:bindingRows("filemanager") end,
        },
    }
end

return KeysMenu
