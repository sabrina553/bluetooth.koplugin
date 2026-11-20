-- Run from the repo root: luajit tests/kindle_setup_test.lua
package.path = "bluetooth.koplugin/?.lua;tests/?.lua;" .. package.path
local rejectDescription = require("helpers").rejectDescription
package.preload["logger"] = function()
    local noop = function() end
    return { dbg = noop, info = noop, warn = noop, err = noop }
end

local Setup = require("bluetooth/controller/kindle_setup")

local failures = 0
local function check(cond, message)
    rejectDescription(cond)
    if not cond then
        failures = failures + 1
        print("FAIL " .. message)
    end
end

-- An in-memory filesystem and command log. `fail` names a path whose write
-- fails or a command that fails; `root` is the id -u answer.
local function fake(opts)
    opts = opts or {}
    local files, cmds = {}, {}
    for path, data in pairs(opts.files or {}) do files[path] = data end
    Setup.sys = {
        run = function(cmd)
            table.insert(cmds, cmd)
            if cmd:find("id -u", 1, true) then return opts.root ~= false end
            if opts.fail_cmd and cmd:find(opts.fail_cmd, 1, true) then return false end
            return true
        end,
        read = function(path) return files[path] end,
        write = function(path, data)
            if opts.fail_write == path then return false end
            if opts.throw_write == path then error("boom") end
            files[path] = data
            return true
        end,
        remove = function(path) files[path] = nil; return true end,
        exists = function(path) return files[path] ~= nil end,
        now = function() return "20261120-120000" end,
    }
    local function ran(fragment)
        for _, c in ipairs(cmds) do if c:find(fragment, 1, true) then return true end end
        return false
    end
    local function lastIs(fragment) return cmds[#cmds] and cmds[#cmds]:find(fragment, 1, true) ~= nil end
    return files, ran, lastIs, cmds
end

local ROOT = "/backup"
local DIR = ROOT .. "/20261120-120000"

do -- Not root: refuses before backing up or remounting.
    local files, ran = fake({ root = false })
    local ok, err = Setup.install(ROOT)
    check(ok == false and err:find("root", 1, true), "not root: refused with a reason")
    check(not ran("mntroot"), "not root: never remounts")
    check(files[DIR .. "/manifest.lua"] == nil, "not root: no backup written")
end

do -- Fresh install: files written, read-only again, markers, manifest.
    local files, ran = fake()
    local ok, err, dir = Setup.install(ROOT)
    check(ok == true, "install: ok, got " .. tostring(err))
    check(dir == DIR, "install: returns the backup folder")
    check(files[Setup.HELPER] ~= nil and files[Setup.RULE] ~= nil, "install: helper and rule written")
    check(ran("chmod 755") and ran("udevadm"), "install: helper executable, udev reloaded")
    check(ran("mntroot rw") and ran("mntroot ro"), "install: remounted and locked again")
    check(files[Setup.MARKERS[1]] ~= nil and files[Setup.MARKERS[2]] ~= nil, "install: marker files created")
    check(Setup.state() == "done", "install: state done")

    -- Undo with no originals: everything the install added goes away.
    local undo_ok = Setup.uninstall(ROOT, dir)
    check(undo_ok == true, "undo: ok")
    check(not files[Setup.HELPER] and not files[Setup.RULE], "undo: added files removed")
    check(not files[Setup.MARKERS[1]], "undo: added markers removed")
    check(Setup.state() == "none", "undo: state none")
end

do -- An existing rule is backed up and comes back unchanged on undo.
    local files = fake({ files = { [Setup.RULE] = "original rule\n", [Setup.MARKERS[1]] = "" } })
    local ok, _, dir = Setup.install(ROOT)
    check(ok == true and files[Setup.RULE] ~= "original rule\n", "existing: rule replaced")
    Setup.uninstall(ROOT, dir)
    check(files[Setup.RULE] == "original rule\n", "existing: original rule restored")
    check(files[Setup.MARKERS[1]] == "", "existing: a marker that was there stays")
end

do -- A failed step rolls back and still locks the partition.
    local files, ran, lastIs = fake({ fail_write = Setup.RULE })
    local ok, err = Setup.install(ROOT)
    check(ok == false and err:find(Setup.RULE, 1, true), "fail: reports the failed step")
    check(files[Setup.HELPER] == nil, "fail: helper written earlier is rolled back")
    check(ran("mntroot ro") and lastIs("mntroot ro"), "fail: read-only again last")
    check(files[Setup.MARKERS[1]] == nil, "fail: no markers after a failed install")
end

do -- An error thrown mid-install still locks the partition.
    local _, _, lastIs = fake({ throw_write = Setup.HELPER })
    local ok = Setup.install(ROOT)
    check(ok == false and lastIs("mntroot ro"), "throw: read-only again")
end

do -- No remount, no changes.
    local files, ran = fake({ fail_cmd = "mntroot rw" })
    local ok = Setup.install(ROOT)
    check(ok == false and files[Setup.HELPER] == nil, "no rw: nothing written")
    check(not ran("mntroot ro"), "no rw: nothing to lock")
end

do -- Undo without a backup refuses.
    fake()
    local ok, err = Setup.uninstall(ROOT, "/nowhere")
    check(ok == false and err:find("backup", 1, true), "undo: refuses without a backup")
end

check(Setup.modelRisk("KindlePaperWhite5") == "verified", "risk: PW5 verified")
check(Setup.modelRisk("KindleOasis") == "risky", "risk: Oasis 1 risky")
check(Setup.modelRisk("KindleScribe") == "untested", "risk: unknown untested")

if failures > 0 then os.exit(1) end
print("kindle_setup_test: ok")
