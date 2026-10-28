--- On Kobo MTK, Nickel can panic on restart after Bluetooth was used, even
--- with the radio off (KOReader #12739). Quitting to Nickel then reboots
--- instead. Adapted from ZenOS kobo_bluetooth_fix.lua (GPL-3.0), see
--- CREDITS.md; kept as is until testers report (decision 2026-10-28).

local logger = require("logger")

local KoboReboot = {}

--- Wraps UIManager.quit once per process: the plugin re-inits on every view
--- change, and a second wrapper would stack. Later calls only swap `used_fn`.
---@param UIManager table
---@param used_fn fun(): boolean whether the Bluetooth service ran this session
function KoboReboot.install(UIManager, used_fn)
    KoboReboot.used_fn = used_fn
    if KoboReboot.installed then return end
    KoboReboot.installed = true
    local orig_quit = UIManager.quit
    UIManager.quit = function(self, exit_code, ...)
        -- Only a plain exit to Nickel: not a restart, not a power-off.
        if exit_code ~= false and (exit_code or self._exit_code or 0) == 0
                and not self._entered_poweroff_stage
                and KoboReboot.used_fn and KoboReboot.used_fn() then
            logger.info("Bluetooth: rebooting after Kobo MTK Bluetooth use instead of quitting to Nickel")
            return self.reboot_action()
        end
        return orig_quit(self, exit_code, ...)
    end
end

return KoboReboot
