-- Run from the repo root: luajit tests/keys_capture_test.lua
package.path = "bluetooth.koplugin/?.lua;tests/?.lua;" .. package.path
local rejectDescription = require("helpers").rejectDescription
package.preload["logger"] = function()
    local noop = function() end
    return { dbg = noop, info = noop, err = noop, warn = noop }
end
local scheduled = {}
package.preload["ui/uimanager"] = function()
    return {
        scheduleIn = function(_, _, fn) scheduled[#scheduled + 1] = fn end,
        unschedule = function(_, fn)
            for i = #scheduled, 1, -1 do
                if scheduled[i] == fn then table.remove(scheduled, i) end
            end
        end,
    }
end

local Capture = require("bluetooth/keys/capture")

local failures = 0
local function check(cond, message)
    rejectDescription(cond)
    if not cond then failures = failures + 1; print("FAIL " .. message) end
end

local hooks = {}
local input = { registerEventAdjustHook = function(self, fn) hooks[#hooks + 1] = fn end }
local function fire(ev) hooks[1](input, ev); return ev end

Capture.ensureHook(input)
Capture.ensureHook(input)
check(#hooks == 1, "two ensureHook calls register once")

check(fire({ type = 1, code = 108, value = 1 }).code == 108, "press passes when not listening")

local got, calls = nil, 0
local function cb(code) calls = calls + 1; got = code end
Capture.listen(cb)
local ev = fire({ type = 1, code = 108, value = 1 })
check(calls == 1 and got == 108, "press calls back once with the code")
check(ev.code == 0, "captured press is neutralised")
check(fire({ type = 1, code = 108, value = 2 }).code == 0, "repeat is neutralised")
check(fire({ type = 1, code = 108, value = 0 }).code == 0, "release is neutralised")
check(fire({ type = 1, code = 108, value = 1 }).code == 108, "next press passes (single-shot)")
check(calls == 1, "no second callback")
check(fire({ type = 1, code = 108, value = 0 }).code == 108, "later release passes")

-- Other event types and other codes.
calls = 0
Capture.listen(cb)
check(fire({ type = 3, code = 108, value = 1 }).code == 108 and calls == 0, "EV_ABS untouched, no callback")
check(fire({ type = 1, code = 108, value = 0 }).code == 108 and calls == 0, "release while listening untouched")
fire({ type = 1, code = 103, value = 1 })
check(fire({ type = 1, code = 108, value = 1 }).code == 108, "other code passes during swallow")
check(fire({ type = 1, code = 103, value = 0 }).code == 0, "release of captured code neutralised")
check(#scheduled == 0, "timeout cancelled after capture")

-- Timeout.
calls, got = 0, "unset"
Capture.listen(cb, 5)
check(#scheduled == 1, "timeout scheduled")
table.remove(scheduled, 1)()
check(calls == 1 and got == nil, "timeout calls back with nil")
check(fire({ type = 1, code = 108, value = 1 }).code == 108 and calls == 1, "press after timeout passes")

-- stop().
calls = 0
Capture.listen(cb)
Capture.stop()
check(#scheduled == 0, "stop cancels the timeout")
check(fire({ type = 1, code = 108, value = 1 }).code == 108 and calls == 0, "no callback after stop")

-- A failing callback must not escape into the input loop.
Capture.listen(function() error("boom") end)
check(pcall(fire, { type = 1, code = 108, value = 1 }), "callback error contained")

if failures > 0 then os.exit(1) end
print("keys_capture_test: ok")
