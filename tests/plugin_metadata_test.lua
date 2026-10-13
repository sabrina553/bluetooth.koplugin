-- Run from the repo root: luajit tests/plugin_metadata_test.lua
package.path = "bluetooth.koplugin/?.lua;" .. package.path
package.preload["gettext"] = function() return function(s) return s end end

-- KOReader caches modules by name across plugins, so another plugin that
-- also does require("_meta") can get here first. Simulate that.
package.loaded["_meta"] = { version = "9.9.9", repository = "someone-else/other.koplugin" }

local PluginMetadata = require("bluetooth/plugin_metadata")
local own = loadfile("bluetooth.koplugin/_meta.lua")()

local failures = 0
local function check(description, actual, expected)
    if actual ~= expected then
        failures = failures + 1
        print(("FAIL %s: got %s, expected %s"):format(description, tostring(actual), tostring(expected)))
    end
end

check("repository comes from this plugin's _meta.lua", PluginMetadata.getRepository(), own.repository)
check("version comes from this plugin's _meta.lua", PluginMetadata.getVersion(), own.version)
check("has a repository", PluginMetadata.hasRepository(), true)

if failures > 0 then
    print(failures .. " failure(s)")
    os.exit(1)
end
print("all plugin_metadata tests passed")
