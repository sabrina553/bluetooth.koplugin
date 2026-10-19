-- Finds the open TouchMenu holding our submenu in KOReader's window stack.
-- Kept free of KOReader modules so it can be tested with plain luajit.
local MenuFind = {}

-- Stock ReaderMenu puts the TouchMenu first in its container, but plugins
-- that patch the menu (ZenOS adds quick-settings panels) can wrap or precede
-- it, so the children are searched a few levels down instead.
-- "menu not found on the first poll" seen on the reader with ZenOS, 2026-10-19.
local MAX_DEPTH = 4

local function isTouchMenu(widget)
    return type(widget) == "table" and type(widget.updateItems) == "function"
        and type(widget.item_table) == "table"
end

--- Returns the TouchMenu and nil when our table is on screen, the TouchMenu
--- and the index of our table in its stack when the user has gone into a
--- sub-level (Settings, About), or nil when the menu is closed.
---@param window_stack table UIManager._window_stack
---@return table|nil, integer|nil
function MenuFind.find(window_stack)
    local visited = {}
    local function search(widget, depth)
        if type(widget) ~= "table" or visited[widget] or depth > MAX_DEPTH then
            return nil
        end
        visited[widget] = true
        if isTouchMenu(widget) then
            if widget.item_table.is_bluetooth_menu == true then
                return widget, nil
            end
            for index, level in ipairs(widget.item_table_stack or {}) do
                if type(level) == "table" and level.is_bluetooth_menu == true then
                    return widget, index
                end
            end
            return nil
        end
        for _, child in ipairs(widget) do
            local found, index = search(child, depth + 1)
            if found then return found, index end
        end
        return nil
    end

    for i = #(window_stack or {}), 1, -1 do
        local found, index = search(window_stack[i].widget, 1)
        if found then return found, index end
    end
    return nil
end

--- True when any TouchMenu is open, ours or not. KOReader builds our table
--- (and so starts the poll) when it builds the menu tree, not only when our
--- submenu is opened, so "not ours" is normal; no TouchMenu at all after we
--- were opened is what points to a changed layout (2026-10-19 reader log).
---@param window_stack table UIManager._window_stack
---@return boolean
function MenuFind.anyOpen(window_stack)
    local visited = {}
    local function search(widget, depth)
        if type(widget) ~= "table" or visited[widget] or depth > MAX_DEPTH then
            return false
        end
        visited[widget] = true
        if isTouchMenu(widget) then return true end
        for _, child in ipairs(widget) do
            if search(child, depth + 1) then return true end
        end
        return false
    end
    for _, window in ipairs(window_stack or {}) do
        if search(window.widget, 1) then return true end
    end
    return false
end

--- A short outline of the top of each window, for the log when the menu
--- is not found: which widgets are there and where TouchMenu-like ones sit.
---@param window_stack table UIManager._window_stack
---@return string
function MenuFind.describe(window_stack)
    local function label(widget)
        if type(widget) ~= "table" then return type(widget) end
        local text = tostring(widget.name or widget.id or "?")
        if isTouchMenu(widget) then text = text .. "[touchmenu]" end
        return text .. "(" .. #widget .. ")"
    end
    local windows = {}
    for i, window in ipairs(window_stack or {}) do
        local widget = window.widget
        local children = {}
        if type(widget) == "table" then
            for j, child in ipairs(widget) do
                if j > 4 then break end
                children[#children + 1] = label(child)
            end
        end
        windows[#windows + 1] = i .. ":" .. label(widget) .. " > " .. table.concat(children, ",")
    end
    return table.concat(windows, " | ")
end

return MenuFind
