-- Captures the next button press through Input's event adjust hook.
-- The captured press is neutralised (code 0 maps to nothing in event_map, so
-- handleKeyBoardEv drops it), otherwise binding a page-turn key would turn
-- the page. decision 2026-10-28
local UIManager = require("ui/uimanager")
local logger = require("logger")

local Capture = { EV_KEY = 1 }

local DEFAULT_TIMEOUT_S = 10
local NEUTRAL_CODE = 0 -- KEY_RESERVED

local callback       -- set while listening
local timeout_fn     -- scheduled timeout, so it can be unscheduled
local swallow_code   -- captured code whose repeats and release are still dropped

local function cancelTimeout()
    if timeout_fn then
        UIManager:unschedule(timeout_fn)
        timeout_fn = nil
    end
end

local function hook(_, ev)
    if ev.type ~= Capture.EV_KEY then return end
    -- A fresh press means the release was lost; stop swallowing, or that
    -- key (often a page turn) stays dead (decision 2026-10-28).
    if swallow_code and ev.code == swallow_code and ev.value == 1 then
        swallow_code = nil
    end
    if swallow_code and ev.code == swallow_code then
        if ev.value == 0 then swallow_code = nil end
        ev.code = NEUTRAL_CODE
        return
    end
    if callback and ev.value == 1 then
        local cb, code = callback, ev.code
        callback = nil
        cancelTimeout()
        swallow_code = code
        ev.code = NEUTRAL_CODE
        local ok, err = pcall(cb, code)
        if not ok then logger.warn("bluetooth keys: capture callback failed:", err) end
    end
end

--- Registers the hook once per input object; the hook cannot be unregistered,
--- and the plugin is rebuilt on view changes. decision 2026-10-28
function Capture.ensureHook(input)
    if input._bt_keys_hook then return end
    input._bt_keys_hook = true
    input:registerEventAdjustHook(hook)
end

--- The next key press calls callback(code) once; on timeout, callback(nil).
function Capture.listen(listen_callback, timeout_s)
    cancelTimeout()
    callback = listen_callback
    timeout_fn = function()
        timeout_fn = nil
        local cb = callback
        callback = nil
        if cb then
            local ok, err = pcall(cb, nil)
            if not ok then logger.warn("bluetooth keys: capture timeout callback failed:", err) end
        end
    end
    UIManager:scheduleIn(timeout_s or DEFAULT_TIMEOUT_S, timeout_fn)
end

--- Cancels without calling back. A press already captured still has its
--- release dropped.
function Capture.stop()
    callback = nil
    cancelTimeout()
end

return Capture
