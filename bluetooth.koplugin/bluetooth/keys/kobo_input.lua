--- Opens a connected remote's input device on Kobo MTK, so its key presses
--- reach KOReader. Whether KOReader picks it up by itself is unknown without
--- a device, so this opens it and logs what it found (decision 2026-10-28).
--- Detection adapted from onatbas/bluetooth.koplugin (MIT), see CREDITS.md:
--- Bluetooth HID devices sit under uhid in sysfs, built-ins under platform.

local logger = require("logger")

local KoboInput = {}

local opened = {}

--- Test-only: forgets what this session opened.
function KoboInput._reset()
    opened = {}
    KoboInput.connected_key = nil
end

--- `path target` lines from LISTING_SCRIPT -> the uhid devices.
---@param text string|nil
---@return table[] devices `{ path = "/dev/input/eventN" }`
function KoboInput.parse(text)
    local devices = {}
    for line in (text or ""):gmatch("[^\n]+") do
        local num, target = line:match("^/sys/class/input/event(%d+)%s+(%S+)")
        if num and target:find("uhid", 1, true) then
            table.insert(devices, { path = "/dev/input/event" .. num })
        end
    end
    return devices
end

KoboInput.LISTING_SCRIPT = 'for e in /sys/class/input/event*; do echo "$e $(readlink "$e")"; done 2>/dev/null'

---@param capture fun(cmd: string): string
---@return table[]
function KoboInput.scan(capture)
    local text = capture(KoboInput.LISTING_SCRIPT)
    local devices = KoboInput.parse(text)
    logger.info("KoboInput: Bluetooth input devices:", #devices)
    return devices
end

--- Opens each device once per session. Device.input:open on a path already
--- open is expected to be harmless (onatbas relies on it), but once is enough.
---@param input table KOReader's Device.input
---@param devices table[]
function KoboInput.openNew(input, devices)
    if type(input.open) ~= "function" then
        logger.warn("KoboInput: Device.input has no open(), not opening")
        return
    end
    -- A node that is gone was closed by its disconnect; forgetting it lets
    -- the same eventN be opened again on reconnect (review 2026-10-28).
    local present = {}
    for _, dev in ipairs(devices) do present[dev.path] = true end
    for path in pairs(opened) do
        if not present[path] then opened[path] = nil end
    end
    for _, dev in ipairs(devices) do
        if not opened[dev.path] then
            opened[dev.path] = true
            -- KOReader keeps the dead fd of a remote that went away under
            -- this path and would skip the open; closing clears it.
            if type(input.close) == "function" and (input.opened_devices or {})[dev.path] then
                pcall(input.close, input, dev.path)
            end
            local ok, err = pcall(input.open, input, dev.path)
            if ok then
                logger.info("KoboInput: opened", dev.path)
            else
                logger.warn("KoboInput: could not open", dev.path, tostring(err))
            end
        end
    end
end

-- Time for the HID link to come up and its uhid device to appear; a guess
-- until a tester log shows the real delay.
KoboInput.SETTLE_S = 3

--- Looks for new input devices once the link has had time to come up.
---@param capture fun(cmd: string): string
function KoboInput.openLater(capture)
    local UIManager = require("ui/uimanager")
    UIManager:scheduleIn(KoboInput.SETTLE_S, function()
        KoboInput.openNew(require("device").input, KoboInput.scan(capture))
    end)
end

--- Called with each device read: when the set of connected devices changes
--- and isn't empty, looks for input devices, since a connect can outlast the
--- wait and a remote can reconnect by itself (review 2026-10-28).
---@param devices table[]|nil
---@param capture fun(cmd: string): string
function KoboInput.onDevices(devices, capture)
    local connected = {}
    for _, dev in ipairs(devices or {}) do
        if dev.connected then table.insert(connected, dev.mac) end
    end
    table.sort(connected)
    local key = table.concat(connected, ",")
    if key ~= (KoboInput.connected_key or "") then
        KoboInput.connected_key = key
        if key ~= "" then
            KoboInput.openLater(capture)
        else
            -- Nothing scans while nothing is connected, so openNew never
            -- sees the node gone: forget here, or the same eventN is
            -- skipped when the remote comes back (PW 5.17.1, 2026-11-11).
            opened = {}
        end
    end
end

return KoboInput
