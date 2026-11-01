--- Path checks for archive extraction.
---
--- Pure Lua with no KOReader dependencies, so it can be tested with plain luajit.

local SafePath = {}

--- Whether an archive entry's path, relative to the plugin root, stays inside
--- the directory it is extracted into. Rejects absolute paths, ".." segments
--- and backslashes (some zip tools write them as separators).
---@param path string
---@return boolean
function SafePath.isSafeRelative(path)
    if type(path) ~= "string" or path == "" then
        return false
    end
    if path:sub(1, 1) == "/" or path:find("\\", 1, true) or path:find("%z") then
        return false
    end
    for segment in path:gmatch("[^/]+") do
        if segment == ".." then
            return false
        end
    end
    return true
end

return SafePath
