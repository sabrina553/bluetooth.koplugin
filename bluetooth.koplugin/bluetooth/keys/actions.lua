local _ = require("gettext")

--- Action lists for the binding picker (decision 2026-10-28).
--- The common lists are adapted from titandrive/bluetoothconfigurator.koplugin
--- (MIT, Copyright (c) titandrive), see CREDITS.md. Dispatcher ids are kept as
--- they are; texts are translated and in British English.
---@class BluetoothActions
local Actions = {}

local function entry(text, actions) return { text = text, actions = actions } end

local function readerCommon()
    return {
        entry(_("Next page"), { page_jmp = 1 }),
        entry(_("Previous page"), { page_jmp = -1 }),
        entry(_("Next chapter"), { next_chapter = true }),
        entry(_("Previous chapter"), { prev_chapter = true }),
        entry(_("Toggle bookmark"), { toggle_bookmark = true }),
        entry(_("Night mode"), { night_mode = true }),
        entry(_("Toggle frontlight"), { toggle_frontlight = true }),
        entry(_("Table of contents"), { toc = true }),
        entry(_("Back"), { back = true }),
        entry(_("Show menu"), { show_menu = true }),
    }
end

local function fileManagerCommon()
    return {
        entry(_("Back"), { back = true }),
        entry(_("Show menu"), { show_menu = true }),
        entry(_("History"), { history = true }),
        entry(_("Favourites"), { favorites = true }),
        entry(_("Collections"), { collections = true }),
        entry(_("Open previous book"), { open_previous_document = true }),
        entry(_("Night mode"), { night_mode = true }),
        -- Dispatcher marks it valid on both screens (decision 2026-10-28).
        entry(_("Toggle frontlight"), { toggle_frontlight = true }),
    }
end

--- Native key names that work on both screens.
function Actions.keys()
    return {
        { text = _("Page forward"), name = "LPgFwd" },
        { text = _("Page back"), name = "LPgBack" },
        { text = _("Up"), name = "Up" },
        { text = _("Down"), name = "Down" },
        { text = _("Left"), name = "Left" },
        { text = _("Right"), name = "Right" },
        { text = _("Press"), name = "Press" },
        { text = _("Back"), name = "Back" },
        { text = _("Menu"), name = "Menu" },
    }
end

function Actions.common(screen)
    if screen == "filemanager" then return fileManagerCommon() end
    return readerCommon()
end

--- Entries present in both lists, so "all screens" never gets a dead binding.
function Actions.forBoth()
    local fm = {}
    for _i, e in ipairs(fileManagerCommon()) do fm[next(e.actions)] = true end
    local out = {}
    for _i, e in ipairs(readerCommon()) do
        if fm[next(e.actions)] then out[#out + 1] = e end
    end
    return out
end

local function sameActions(a, b)
    for k, v in pairs(a) do if b[k] ~= v then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end

function Actions.label(action)
    if type(action) ~= "table" then return _("Unknown action") end
    if action.kind == "key" and not action.name then return _("Unknown action") end
    if action.kind == "key" then
        for _i, k in ipairs(Actions.keys()) do
            if k.name == action.name then return k.text end
        end
        return action.name
    end
    for _i, list in ipairs({ readerCommon(), fileManagerCommon() }) do
        for _j, e in ipairs(list) do
            if sameActions(e.actions, action.actions or {}) then return e.text end
        end
    end
    -- Dispatcher:getNameFromItem takes an action id, and answers "Unknown item"
    -- for ids it no longer has (v2026.07.2, dispatcher.lua:710).
    local ok, title = pcall(function()
        local Dispatcher = require("dispatcher")
        Dispatcher:init()
        local ids = {}
        for id in pairs(action.actions or {}) do ids[#ids + 1] = id end
        table.sort(ids)
        local names = {}
        for _i, id in ipairs(ids) do
            local name = Dispatcher:getNameFromItem(id, action.actions, true)
            if type(name) ~= "string" or name == _("Unknown item") then return nil end
            names[#names + 1] = name
        end
        return table.concat(names, ", ")
    end)
    if ok and type(title) == "string" and title ~= "" then return title end
    return _("Unknown action")
end

--- Lower-case Dispatcher category names hidden from the full picker.
function Actions.excludedCategories(screen)
    if screen == "filemanager" then
        return { reader = true, paging = true, rolling = true, document = true }
    end
    return {}
end

return Actions
