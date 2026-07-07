local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local logger = require("logger")

---@class BluetoothDeviceStoreEntry
---@field mac string
---@field name string
---@field paired boolean
---@field bonded boolean
---@field trusted boolean
---@field blocked boolean
---@field connected boolean
---@field starred boolean

---@class BluetoothDeviceStore
---@field store any
---@field data table<string, BluetoothDeviceStoreEntry>
local BluetoothDeviceStore = {}

local SETTING_KEY = "bluetooth_devices"

local function openStoreHandle()
    local path = DataStorage:getSettingsDir() .. "/" .. SETTING_KEY .. ".lua"
    return LuaSettings:open(path)
end

function BluetoothDeviceStore:new()
    local o = {}
    setmetatable(o, self)
    self.__index = self
    o:init()
    return o
end

function BluetoothDeviceStore:init()
    self.store = openStoreHandle()
    local success, result = pcall(function()
        return self.store:readSetting(SETTING_KEY, {}) or {}
    end)

    if success then
        self.data = result
    else
        logger:err("Bluetooth DeviceStore: Error reading store, using empty table", result)
        self.data = {}
        self:write()
    end
end

function BluetoothDeviceStore:write()
    local success, error_msg = pcall(function()
        if not self.store then
            logger:err("Bluetooth DeviceStore: No store object available for write")
            return false
        end
        self.store:saveSetting(SETTING_KEY, self.data)
        self.store:flush()
        return true
    end)

    if not success then
        logger:err("Bluetooth DeviceStore: error writing store:", error_msg)
        return false
    end

    return true
end

--- Snapshot the persistent fields of a single Devices instance into the
--- in-memory table. Does NOT write to disk on its own — call :write()
--- (or use :saveAll, which does both) once you're done batching changes.
---@param dev Devices
function BluetoothDeviceStore:save(dev)
    if not dev or not dev.mac or dev.mac == "" then
        return
    end
    self.data[dev.mac] = {
        mac = dev.mac,
        name = dev.name,
        paired = dev.paired,
        bonded = dev.bonded,
        trusted = dev.trusted,
        blocked = dev.blocked,
        connected = dev.connected,
        starred = dev.starred,
    }
end

--- Snapshot a whole list of Devices instances and flush once.
---@param devices Devices[]
function BluetoothDeviceStore:saveAll(devices)
    for _, dev in ipairs(devices or {}) do
        self:save(dev)
    end
    self:write()
end

---@param mac string
---@return BluetoothDeviceStoreEntry|nil
function BluetoothDeviceStore:get(mac)
    return self.data[mac]
end

--- Returns every starred entry. More than one device may be starred at once.
---@return BluetoothDeviceStoreEntry[]
function BluetoothDeviceStore:getStarred()
    local starred = {}
    for _, entry in pairs(self.data) do
        if entry.starred then
            table.insert(starred, entry)
        end
    end
    return starred
end

--- Returns every entry that was connected as of the last snapshot.
---@return BluetoothDeviceStoreEntry[]
function BluetoothDeviceStore:getConnected()
    local connected = {}
    for _, entry in pairs(self.data) do
        if entry.connected then
            table.insert(connected, entry)
        end
    end
    return connected
end

return BluetoothDeviceStore