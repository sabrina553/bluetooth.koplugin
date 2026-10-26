--- Live updates (experimental, off by default): a `dbus-monitor` for BlueZ
--- signals, run only while the Bluetooth menu is open in Fast mode, so the
--- menu redraws as soon as something changes instead of on the next 3 s poll.
--- The poll stays as it is; if the monitor is missing, refused or dies,
--- nothing changes from today. Decision: 2026-10-26 session note (stage 4,
--- opt-in for the stable release).
---
--- The monitor writes to a file that a timer reads from the last offset, so
--- no process starts per check. Its lifetime is capped with `timeout` and its
--- PID kept at a fixed path, so a KOReader crash cannot leave it running.

local logger = require("logger")
local UIManager = require("ui/uimanager")
local Bluez = require("bluetooth/controller/bluez")
local DbusEvents = require("bluetooth/controller/dbus_events")

local DbusMonitor = {
    CHECK_S = 0.5,
    -- Longer than any menu visit; the menu restarts it when it is reopened.
    LIFETIME_S = 600,
    -- About 80 KB per 90 s during a scan on the reader; far more means
    -- something is wrong, so stop rather than fill /tmp.
    MAX_BYTES = 2 * 1024 * 1024,
    PID_FILE = "/tmp/bluetooth.koplugin-monitor.pid",
    RULE = "type=signal,sender=org.bluez",
}

--- Kills a monitor left by an earlier session, if its PID still belongs to
--- dbus-monitor (a reused PID must not be killed). Under `timeout` the PID is
--- timeout's, whose command line names dbus-monitor too.
function DbusMonitor.cleanupStale()
    local f = io.open(DbusMonitor.PID_FILE, "r")
    if not f then return end
    local pid = tonumber(f:read("*l") or "")
    f:close()
    os.remove(DbusMonitor.PID_FILE)
    if not pid then return end
    local cmd = io.open("/proc/" .. pid .. "/cmdline", "r")
    local line = cmd and cmd:read("*a") or ""
    if cmd then cmd:close() end
    if line:find("dbus-monitor", 1, true) then
        logger.info("DbusMonitor: stopping a monitor left from an earlier session")
        os.execute("kill " .. pid .. " >/dev/null 2>&1")
    end
end

--- Starts the monitor. `on_change` runs (on the UI loop) when a signal
--- changes something the menu draws.
---@param on_change fun()
---@return table|nil # nil when dbus-monitor could not start
function DbusMonitor.start(on_change)
    DbusMonitor.cleanupStale()
    local base = os.tmpname()
    os.remove(base)
    local out = base .. ".mon"
    local cmd = ("%sdbus-monitor --system '%s' >%s 2>&1 & echo $! >%s")
        :format(Bluez.timeoutPrefix(DbusMonitor.LIFETIME_S), DbusMonitor.RULE, out, DbusMonitor.PID_FILE)
    os.execute(cmd)
    local f = io.open(DbusMonitor.PID_FILE, "r")
    local pid = f and tonumber(f:read("*l") or "")
    if f then f:close() end
    if not pid then
        logger.warn("DbusMonitor: could not start dbus-monitor, keeping the 3 s poll only")
        os.remove(out)
        return nil
    end
    local self = setmetatable({ pid = pid, out = out, offset = 0, state = DbusEvents.newState() },
        { __index = DbusMonitor })
    self.check = function() self:read(on_change) end
    logger.dbg("DbusMonitor: started")
    UIManager:scheduleIn(DbusMonitor.CHECK_S, self.check)
    return self
end

--- Reads what the monitor wrote since the last check.
---@param on_change fun()
function DbusMonitor:read(on_change)
    if self.stopped then return end
    local f = io.open(self.out, "r")
    if not f then
        logger.warn("DbusMonitor: output went missing, stopping live updates")
        return self:stop()
    end
    f:seek("set", self.offset)
    local chunk = f:read("*a") or ""
    f:close()
    self.offset = self.offset + #chunk
    if self.offset > DbusMonitor.MAX_BYTES then
        logger.warn("DbusMonitor: output passed " .. DbusMonitor.MAX_BYTES .. " bytes, stopping live updates")
        return self:stop()
    end
    if DbusEvents.feed(self.state, chunk) then
        on_change()
    end
    UIManager:scheduleIn(DbusMonitor.CHECK_S, self.check)
end

function DbusMonitor:stop()
    if self.stopped then return end
    self.stopped = true
    UIManager:unschedule(self.check)
    os.execute("kill " .. self.pid .. " >/dev/null 2>&1")
    os.remove(self.out)
    os.remove(DbusMonitor.PID_FILE)
    logger.dbg("DbusMonitor: stopped")
end

return DbusMonitor
