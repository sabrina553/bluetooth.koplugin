-- Run from the repo root: luajit tests/menu_find_test.lua
package.path = "bluetooth.koplugin/?.lua;" .. package.path
local MenuFind = require("bluetooth/ui/menu_find")

local failures = 0
local function check(cond, message)
    if not cond then
        failures = failures + 1
        print("FAIL " .. message)
    end
end

local function touchMenu(item_table, stack)
    return { updateItems = function() end, item_table = item_table, item_table_stack = stack }
end
local ours = { is_bluetooth_menu = true }

-- Stock layout: the TouchMenu is the first child of the window's container.
do
    local tm = touchMenu(ours)
    local found, index = MenuFind.find({ { widget = { tm } } })
    check(found == tm and index == nil, "stock: found on screen")
end

-- Wrapped: another plugin's panel comes first and the menu sits deeper.
do
    local tm = touchMenu(ours)
    local container = { { { "panel" } }, { { tm } } }
    local found = MenuFind.find({ { widget = container } })
    check(found == tm, "wrapped: found below a panel")
end

-- In Settings: our table waits in the stack.
do
    local tm = touchMenu({}, { {}, ours })
    local found, index = MenuFind.find({ { widget = { tm } } })
    check(found == tm and index == 2, "sub-level: stack index returned")
end

-- Another menu open, or nothing open: not found.
do
    check(MenuFind.find({ { widget = { touchMenu({}) } } }) == nil, "other menu: not found")
    check(MenuFind.find({}) == nil, "empty stack: not found")
end

-- Too deep or cyclic trees end the search.
do
    local deep = touchMenu(ours)
    for _ = 1, 6 do deep = { deep } end
    check(MenuFind.find({ { widget = deep } }) == nil, "depth limit holds")
    local loop = {}
    loop[1] = loop
    check(MenuFind.find({ { widget = loop } }) == nil, "cycle ends")
end

if failures > 0 then os.exit(1) end
print("menu_find_test: ok")
