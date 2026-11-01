--- Locates this plugin's own directory.
---
--- Pure Lua with no KOReader dependencies, so it can be tested with plain luajit.

local PluginPath = {}

--- Walks up from this file's own location until it finds a directory
--- ending in `.koplugin`. This has to walk up (rather than just checking
--- the immediate parent) because this file lives inside the plugin (under
--- `bluetooth/`), not at its root.
---@return string|nil directory nil if no `.koplugin` ancestor exists
function PluginPath.get()
    local source = debug.getinfo(1, "S").source
    local path = source:match("@(.*)")
    local dir = path and path:match("(.*)/")

    while dir and dir ~= "" do
        if dir:match("%.koplugin$") then
            return dir
        end
        dir = dir:match("(.*)/")
    end

    return nil
end

return PluginPath
