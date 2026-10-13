local PluginPath = require("bluetooth/plugin_path")

-- Not require("_meta"): KOReader caches modules by name across all plugins,
-- so whichever plugin required "_meta" first would hand its own file to every
-- other plugin that does the same. Loading by path keeps this plugin's own.
---@return table
local function loadOwnMeta()
    local dir = PluginPath.get()
    local chunk = dir and loadfile(dir .. "/_meta.lua")
    if not chunk then
        return {}
    end

    local ok, meta = pcall(chunk)
    return ok and type(meta) == "table" and meta or {}
end

local _meta = loadOwnMeta()

---@class BluetoothPluginMetadata
local PluginMetadata = {}


---@return boolean has_repository
function PluginMetadata.hasRepository()
    return type(_meta.repository) == "string"
end

---@return string version
function PluginMetadata.getVersion()
    if type(_meta.version) ~= "string" then
        return "0.0.0-snapshot"
    end

    return _meta.version
end

---@return string repository
function PluginMetadata.getRepository()
    if type(_meta.repository) ~= "string" then
        return "unknown repository"
    end

    return _meta.repository
end

return PluginMetadata
