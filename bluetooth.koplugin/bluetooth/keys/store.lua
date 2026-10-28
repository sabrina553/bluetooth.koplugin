local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local logger = require("logger")

--- Remote button bindings, saved per remote (keyed by Bluetooth name, never
--- by MAC) and per screen.
---@class BluetoothKeyBinding
---@field code number
---@field screens table<string, boolean> reader and/or filemanager
---@field action table { kind = "key", name } or { kind = "dispatcher", actions }

---@class BluetoothKeyStore
local Store = {}

local SETTING_KEY = "bindings"

local function deepCopy(v)
    if type(v) ~= "table" then return v end
    local c = {}
    for k, x in pairs(v) do c[k] = deepCopy(x) end
    return c
end

local function overlaps(a, b)
    for screen in pairs(a) do
        if b[screen] then return true end
    end
    return false
end

local function isBinding(b)
    return type(b) == "table" and type(b.code) == "number"
        and type(b.screens) == "table" and type(b.action) == "table"
end

function Store:new(opts)
    local o = setmetatable({}, self)
    self.__index = self
    o.path = opts and opts.path
        or (DataStorage:getSettingsDir() .. "/bluetooth_keys.lua")
    o:init()
    return o
end

function Store:init()
    self.data = {}
    local opened, handle = pcall(LuaSettings.open, LuaSettings, self.path)
    if not opened or not handle then
        -- Without a handle nothing is ever saved; say so (decision 2026-10-28).
        logger.err("Bluetooth key store: cannot open settings file, bindings will not be saved:", handle)
        return
    end
    self.handle = handle
    local ok, result = pcall(function()
        return handle:readSetting(SETTING_KEY, {})
    end)
    if not ok or type(result) ~= "table" then
        -- A corrupt file must not stop the plugin loading (decision 2026-10-28).
        logger.warn("Bluetooth key store: unreadable, starting empty", ok and type(result) or result)
        return
    end
    for remote, list in pairs(result) do
        if type(remote) == "string" and type(list) == "table" then
            local kept = {}
            for _, b in ipairs(list) do
                if isBinding(b) then kept[#kept + 1] = b
                else logger.warn("Bluetooth key store: skipping malformed binding") end
            end
            self.data[remote] = kept
        end
    end
end

function Store:write()
    if not self.handle then
        logger.err("Bluetooth key store: no settings file open, binding not saved")
        return false
    end
    local ok, err = pcall(function()
        self.handle:saveSetting(SETTING_KEY, self.data)
        self.handle:flush()
    end)
    if not ok then logger.err("Bluetooth key store: error writing:", err) end
    return ok
end

function Store:list(remote)
    return deepCopy(self.data[remote] or {})
end

function Store:remotes()
    local names = {}
    for remote in pairs(self.data) do names[#names + 1] = remote end
    table.sort(names)
    return names
end

--- Replace any binding for the same code on an overlapping screen, else append.
function Store:set(remote, binding)
    local list = self.data[remote] or {}
    self.data[remote] = list
    local new = deepCopy(binding)
    for i, b in ipairs(list) do
        if b.code == new.code and overlaps(b.screens, new.screens) then
            list[i] = new
            self:write()
            return
        end
    end
    list[#list + 1] = new
    self:write()
end

function Store:remove(remote, code, screen)
    local list = self.data[remote]
    if not list then return end
    for i, b in ipairs(list) do
        if b.code == code and b.screens[screen] then
            b.screens[screen] = nil
            if next(b.screens) == nil then table.remove(list, i) end
            break
        end
    end
    if #list == 0 then self.data[remote] = nil end
    self:write()
end

--- Unlink a "both screens" binding: `screen` gets its own binding with
--- `action`, the other screen keeps the old one (decision 2026-10-28).
function Store:split(remote, code, screen, action)
    local list = self.data[remote]
    if not list then return end
    for _, b in ipairs(list) do
        if b.code == code and b.screens[screen] and next(b.screens, next(b.screens)) ~= nil then
            b.screens[screen] = nil
            list[#list + 1] = { code = code, screens = { [screen] = true }, action = deepCopy(action) }
            self:write()
            return
        end
    end
end

return Store
