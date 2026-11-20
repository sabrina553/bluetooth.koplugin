--- Menu flow for the Kindle remote setup: why it warns, what to back up,
--- running it, and asking for a report either way (decision 2026-11-20).
local _ = require("gettext")
local T = require("ffi/util").template
local logger = require("logger")
local KindleSetup = require("bluetooth/controller/kindle_setup")

local ISSUES_URL = "https://github.com/sabrina553/bluetooth.koplugin/issues"

local KindleSetupMenu = {}

local function backupRoot()
    return require("datastorage"):getSettingsDir() .. "/bluetooth_kindle_setup"
end

local function model()
    return require("device").model or "unknown"
end

local function show(widget)
    require("ui/uimanager"):show(widget)
end

local function confirm(text, ok_text, on_ok)
    local ConfirmBox = require("ui/widget/confirmbox")
    show(ConfirmBox:new{ text = text, ok_text = ok_text, ok_callback = on_ok })
end

-- No timeout: these are meant to be read, and the report details copied.
local function message(text)
    local InfoMessage = require("ui/widget/infomessage")
    show(InfoMessage:new{ text = text })
end

local function reportLine()
    return T(_("Model: %1, firmware: %2"), model(), KindleSetup.firmware())
end

local function forgetPrepared()
    require("bluetooth/controller/kindle").forgetPrepared()
end

local function run()
    local UIManager = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    local busy = InfoMessage:new{ text = _("Setting up remotes…") }
    UIManager:show(busy)
    -- Next tick, so the busy message is drawn before the blocking shell calls.
    UIManager:nextTick(function()
        local ok, err, dir = KindleSetup.install(backupRoot())
        UIManager:close(busy)
        forgetPrepared()
        logger.info("KindleSetup: result", tostring(ok), tostring(err), "model", model())
        if ok then
            message(T(_([[Set up. Pair your remote from Scan, or with Pair by address….

Copies of the original files are in:
%1
Undo any time from Settings → Undo remote setup….

Please tell us it worked, so other owners of this model know it's safe:
%2
%3]]), dir, ISSUES_URL, reportLine()))
        else
            message(T(_([[Setup failed: %1

Nothing was left half-done: the changed files were put back from the backup%2, and the system partition was made read-only again.

Please report this, it helps us warn others:
%3
%4]]), err or _("unknown error"), dir and (" (" .. dir .. ")") or "", ISSUES_URL, reportLine()))
        end
    end)
end

local function riskText()
    local risk = KindleSetup.modelRisk(model())
    if risk == "verified" then
        return T(_("Your model (%1) has been set up successfully by other users."), model())
    elseif risk == "risky" then
        return T(_("WARNING: your model (%1) is one of the older Kindles where this setup has caused a white screen that needed manual recovery. Only continue if you know how to recover your Kindle."), model())
    end
    return T(_("Your model (%1) hasn't been tried yet. It will probably work like the Paperwhite 5 and 6, but you'd be the first: please report how it goes."), model())
end

local function backupStep()
    confirm(T(_([[Before you start:

1. Charge to at least 50%. A shutdown mid-setup is the main way this goes wrong.
2. Plug into a computer and copy the whole koreader folder somewhere safe.
3. Make sure you can still reach your Kindle over USB or SSH if KOReader won't start, and keep your jailbreak's recovery steps to hand.

The plugin saves a copy of every file it changes to:
%1
and "Undo remote setup…" puts them back. Re-run setup any time, for example after a firmware update removes it.]]), backupRoot()),
        _("Set up now"), function()
            if KindleSetup.modelRisk(model()) == "risky" then
                confirm(riskText() .. "\n\n" .. _("Continue anyway?"), _("Continue"), run)
            else
                run()
            end
        end)
end

function KindleSetupMenu.start()
    confirm(T(_([[Kindle only pairs headphones on its own. To pair remotes, keyboards and controllers, this adds two small system files: a udev rule and a helper that tells the Kindle a Bluetooth button device is an input. It also adds two marker files that stop disconnects filling the storage with crash logs.

Why the warnings: these files live on the Kindle's system partition, which normally can't be changed. The plugin unlocks it briefly and always locks it again. Amazon doesn't support this, and on some older Kindles the same setup has led to a white screen.

%1]]), riskText()), _("Continue"), backupStep)
end

function KindleSetupMenu.undo()
    confirm(_("Remove the remote setup and put the original files back from the newest backup? Remotes will stop pairing until you set up again."),
        _("Undo"), function()
            local ok, err = KindleSetup.uninstall(backupRoot())
            forgetPrepared()
            if ok then
                message(_("Remote setup removed and the original files restored."))
            else
                message(T(_("Couldn't undo: %1\n\nPlease report this:\n%2\n%3"), err or "", ISSUES_URL, reportLine()))
            end
        end)
end

--- Settings entry: set up, or undo once set up.
function KindleSetupMenu.item()
    return {
        text_func = function()
            return KindleSetup.state() == "done" and _("Undo remote setup…") or _("Set up remotes…")
        end,
        help_text = _("Kindle only: lets remotes, keyboards and controllers pair. Changes system files, with backups and an undo."),
        callback = function()
            if KindleSetup.state() == "done" then KindleSetupMenu.undo() else KindleSetupMenu.start() end
        end,
        separator = true,
    }
end

return KindleSetupMenu
