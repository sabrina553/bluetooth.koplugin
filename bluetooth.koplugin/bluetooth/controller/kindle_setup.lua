--- One-time Kindle setup so remotes and keyboards can pair: a udev rule and
--- helper that mark a Bluetooth HID device as input, plus marker files that
--- stop disconnects filling the disk with core dumps. Steps and file contents
--- from finlater/kindlebtcontroller.koplugin (MIT), see CREDITS.md.
---
--- Opt-in from the menu only (decision 2026-11-20, replacing "never automate"
--- from 2026-10-28). Every file is backed up before it changes, the root
--- partition always goes back to read-only, and a failed install rolls back.
--- The dmcc.sh edit from the guide is left out: patching a firmware script by
--- pattern breaks silently across firmware versions.

local logger = require("logger")

local HELPER = "/usr/local/bin/dev_is_keyboard.sh"
local RULE = "/etc/udev/rules.d/99-bt-keyboard.rules"
local MARKERS = { "/mnt/us/DISABLE_CORE_DUMP", "/mnt/us/DISABLE_CORE_DUMP_ALERT" }

local HELPER_TEXT = [[#!/bin/sh
DEVICE=$1
if evtest info $DEVICE | grep -q 'Event type 1 (Key)'; then
  if evtest info $DEVICE | grep -q 'Event code 16 (Q)'; then
    # Key support alone would match the touchscreen and break the UI.
    echo ID_INPUT=1
    echo ID_INPUT_KEY=1
    echo ID_INPUT_KEYBOARD=1
  fi
fi
]]
local RULE_TEXT = [[KERNEL=="uhid", MODE="0660", GROUP="bluetooth"
ACTION=="add", SUBSYSTEM=="input", IMPORT+="/usr/local/bin/dev_is_keyboard.sh %N"
]]

--- KOReader's Device.model names. Verified: setup run by testers. Risky:
--- the guide reports white screens needing recovery on these.
local VERIFIED = { KindlePaperWhite5 = true, KindlePaperWhite6 = true }
local RISKY = { KindleOasis = true, KindlePaperWhite3 = true, KindlePaperWhite2 = true,
    KindlePaperWhite = true, KindleVoyage = true, KindleBasic = true, KindleTouch = true }

local KindleSetup = {
    HELPER = HELPER,
    RULE = RULE,
    MARKERS = MARKERS,
}

--- System access in one table so tests can replace it.
KindleSetup.sys = {
    run = function(cmd)
        local ok, _, code = os.execute(cmd)
        return ok == true or ok == 0 or code == 0
    end,
    read = function(path)
        local f = io.open(path, "rb")
        if not f then return nil end
        local data = f:read("*a")
        f:close()
        return data
    end,
    write = function(path, data)
        local f, err = io.open(path, "wb")
        if not f then return false, err end
        local ok, werr = f:write(data)
        f:close()
        return ok ~= nil, werr
    end,
    remove = function(path) return os.remove(path) ~= nil end,
    exists = function(path)
        local f = io.open(path, "rb")
        if f then f:close() return true end
        return false
    end,
    now = function() return os.date("%Y%m%d-%H%M%S") end,
}

---@param model string|nil KOReader's Device.model
---@return string "verified" | "risky" | "untested"
function KindleSetup.modelRisk(model)
    if VERIFIED[model] then return "verified" end
    if RISKY[model] then return "risky" end
    return "untested"
end

---@return string "done" | "partial" | "none"
function KindleSetup.state()
    local sys = KindleSetup.sys
    local helper, rule = sys.exists(HELPER), sys.exists(RULE)
    if helper and rule then return "done" end
    if helper or rule then return "partial" end
    return "none"
end

--- Firmware version for the report text, e.g. "5.17.1".
function KindleSetup.firmware()
    local text = KindleSetup.sys.read("/etc/prettyversion.txt") or ""
    return text:match("Kindle%s+([%d%.]+)") or "unknown"
end

local function serialise(manifest)
    local lines = { "return {" }
    for _, e in ipairs(manifest) do
        lines[#lines + 1] = ("  { path = %q, existed = %s, backup = %s },"):format(
            e.path, tostring(e.existed), e.backup and ("%q"):format(e.backup) or "nil")
    end
    lines[#lines + 1] = "}"
    return table.concat(lines, "\n") .. "\n"
end

local function loadManifest(dir)
    local text = KindleSetup.sys.read(dir .. "/manifest.lua")
    if not text then return nil end
    local chunk = loadstring(text)
    if not chunk then return nil end
    setfenv(chunk, {})
    local ok, manifest = pcall(chunk)
    return ok and type(manifest) == "table" and manifest or nil
end

--- Copies every file the install touches into a new timestamped folder,
--- with a manifest saying which existed, so undo can put each back exactly.
local function backUp(backup_root)
    local sys = KindleSetup.sys
    local dir = backup_root .. "/" .. sys.now()
    if not sys.run(("mkdir -p %q"):format(dir)) then return nil, "could not create the backup folder" end
    local manifest = {}
    for _, path in ipairs({ HELPER, RULE, MARKERS[1], MARKERS[2] }) do
        local data = sys.read(path)
        local entry = { path = path, existed = data ~= nil }
        if data then
            entry.backup = dir .. "/" .. path:gsub("/", "_")
            if not sys.write(entry.backup, data) then return nil, "could not back up " .. path end
        end
        manifest[#manifest + 1] = entry
    end
    if not sys.write(dir .. "/manifest.lua", serialise(manifest)) then
        return nil, "could not write the backup manifest"
    end
    logger.info("KindleSetup: backed up to", dir)
    return dir, manifest
end

--- Puts every file in the manifest back as it was. Needs the root partition
--- writable; the caller handles mntroot.
local function restore(manifest)
    local sys, ok = KindleSetup.sys, true
    for _, e in ipairs(manifest) do
        if e.existed then
            local data = e.backup and sys.read(e.backup)
            if not (data and sys.write(e.path, data)) then
                logger.warn("KindleSetup: could not restore", e.path)
                ok = false
            elseif e.path == HELPER then
                sys.run(("chmod 755 %q"):format(HELPER))
            end
        elseif sys.exists(e.path) and not sys.remove(e.path) then
            logger.warn("KindleSetup: could not remove", e.path)
            ok = false
        end
    end
    return ok
end

local function reloadUdev()
    return KindleSetup.sys.run("udevadm control --reload-rules && udevadm trigger")
end

--- Runs `fn` with the root partition writable and always makes it read-only
--- again, even when `fn` fails or throws.
local function withRootWritable(fn)
    local sys = KindleSetup.sys
    if not sys.run("mntroot rw >/dev/null 2>&1") then
        return false, "could not make the system partition writable"
    end
    local ok, result, err = pcall(fn)
    if not sys.run("mntroot ro >/dev/null 2>&1") then
        logger.warn("KindleSetup: mntroot ro failed; the system partition may still be writable")
    end
    if not ok then return false, tostring(result) end
    return result, err
end

--- The install. Callers are expected to have warned the user first.
---@param backup_root string folder on the user partition for backups
---@return boolean ok, string|nil message, string|nil backup_dir
function KindleSetup.install(backup_root)
    local sys = KindleSetup.sys
    if not sys.run('[ "$(id -u)" = 0 ]') then
        return false, "KOReader isn't running as root, so it can't change system files."
    end
    local dir, manifest = backUp(backup_root)
    if not dir then return false, manifest end

    local ok, err = withRootWritable(function()
        local steps = {
            function() return sys.run("mkdir -p /usr/local/bin"), "could not create /usr/local/bin" end,
            function() return sys.write(HELPER, HELPER_TEXT), "could not write " .. HELPER end,
            function() return sys.run(("chmod 755 %q"):format(HELPER)), "could not make the helper executable" end,
            function() return sys.write(RULE, RULE_TEXT), "could not write " .. RULE end,
            function() return reloadUdev(), "could not reload udev rules" end,
        }
        for i, step in ipairs(steps) do
            local step_ok, message = step()
            if not step_ok then
                logger.warn("KindleSetup: step", i, "failed:", message, "- rolling back")
                restore(manifest)
                reloadUdev()
                return false, message
            end
        end
        return true
    end)
    if not ok then return false, err, dir end

    -- User partition, no remount needed; a failure here only means more logs.
    for _, marker in ipairs(MARKERS) do
        if not sys.exists(marker) and not sys.write(marker, "") then
            logger.warn("KindleSetup: could not create", marker)
        end
    end
    logger.info("KindleSetup: install finished")
    return true, nil, dir
end

--- Newest backup folder under backup_root, or nil.
function KindleSetup.latestBackup(backup_root)
    local list = io.popen(("ls -1 %q 2>/dev/null"):format(backup_root))
    if not list then return nil end
    local newest
    for name in list:lines() do
        if name:match("^%d+%-%d+$") and (not newest or name > newest) then newest = name end
    end
    list:close()
    return newest and (backup_root .. "/" .. newest) or nil
end

--- Undo: puts back what the newest backup recorded.
---@return boolean ok, string|nil message
function KindleSetup.uninstall(backup_root, dir)
    dir = dir or KindleSetup.latestBackup(backup_root)
    local manifest = dir and loadManifest(dir)
    if not manifest then return false, "no backup found to restore from" end
    if not KindleSetup.sys.run('[ "$(id -u)" = 0 ]') then
        return false, "KOReader isn't running as root, so it can't change system files."
    end
    local ok, err = withRootWritable(function()
        local restored = restore(manifest)
        reloadUdev()
        return restored, not restored and "some files could not be restored; see crash.log" or nil
    end)
    logger.info("KindleSetup: uninstall from", dir, "ok:", tostring(ok))
    return ok, err
end

return KindleSetup
