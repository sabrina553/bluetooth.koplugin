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

return MenuFind
