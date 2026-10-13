-- Run from the repo root: luajit tests/version_test.lua
package.path = "bluetooth.koplugin/?.lua;" .. package.path
local Version = require("bluetooth/ota/version")

local failures = 0
local function check(description, actual, expected)
    if actual ~= expected then
        failures = failures + 1
        print(("FAIL %s: got %s, expected %s"):format(description, tostring(actual), tostring(expected)))
    end
end

local function newer(current, candidate, expected)
    check(("isNewer(%s, %s)"):format(current, candidate), Version.isNewer(current, candidate), expected)
end

-- Numeric ordering, major before minor before patch
newer("0.0.3", "0.0.4", true)
newer("0.0.4", "0.0.3", false)
newer("1.5.0", "0.9.0", false)
newer("0.9.9", "1.0.0", true)
newer("0.0.4", "0.0.4", false)
newer("v0.0.4", "0.0.4", false)

-- Pre-releases: dev < beta < rc < stable, then by number
newer("0.0.4-dev.3", "0.0.4-dev.4", true)
newer("0.0.4-dev.10", "0.0.4-dev.9", false)
newer("0.0.4-dev.3", "0.0.4-beta.1", true)
newer("0.0.4-beta.1", "0.0.4-dev.9", false)
newer("0.0.4-beta.2", "0.0.4-rc.1", true)
newer("0.0.4-rc.1", "0.0.4", true)
newer("0.0.4", "0.0.4-dev.9", false)

-- Switching dev -> stable must not offer a downgrade
newer("0.0.4-dev.3", "0.0.3", false)

-- Legacy dot-separated tags and build metadata
newer("0.0.3.dev.3", "0.0.4-dev.1", true)
newer("0.0.3.dev.3", "0.0.3", true)
newer("0.0.4+abc", "0.0.4", false)

-- Garbage never counts as newer
newer("0.0.4", "latest", false)

-- Channel membership
check("stable takes 0.0.4", Version.channelAccepts("stable", "0.0.4"), true)
check("stable skips beta", Version.channelAccepts("stable", "0.0.4-beta.1"), false)
check("beta takes beta", Version.channelAccepts("beta", "0.0.4-beta.1"), true)
check("beta takes rc", Version.channelAccepts("beta", "0.0.4-rc.1"), true)
check("beta takes stable", Version.channelAccepts("beta", "0.0.4"), true)
check("beta skips dev", Version.channelAccepts("beta", "0.0.4-dev.3"), false)
check("development takes dev", Version.channelAccepts("development", "0.0.4-dev.3"), true)
check("development takes legacy dev", Version.channelAccepts("development", "0.0.3.dev.3"), true)
check("unknown channel", Version.channelAccepts("nightly", "0.0.4"), false)

-- Picking the release a channel should offer
local ZIP = "^bluetooth%.koplugin%.zip$"
local function release(tag, opts)
    opts = opts or {}
    local assets = { { name = "bluetooth.koplugin.zip" } }
    if opts.no_asset then assets = {} end
    if opts.checksum_only then assets = { { name = "bluetooth.koplugin.zip.sha256" } } end
    return { tag_name = tag, prerelease = opts.prerelease, assets = assets }
end
local function pick(description, releases, channel, expected)
    check(description, Version.pickLatest(releases, channel, ZIP), expected)
end

pick("highest wins regardless of list order",
    { release("0.0.3"), release("0.0.4"), release("0.0.2") }, "stable", "0.0.4")
pick("stable skips pre-release tags",
    { release("0.0.5-beta.1", { prerelease = true }), release("0.0.4") }, "stable", "0.0.4")
pick("stable skips GitHub pre-release flag",
    { release("0.0.5", { prerelease = true }), release("0.0.4") }, "stable", "0.0.4")
pick("beta takes newer beta", { release("0.0.5-beta.1"), release("0.0.4") }, "beta", "0.0.5-beta.1")
pick("release without the zip is skipped",
    { release("0.0.5", { no_asset = true }), release("0.0.4") }, "stable", "0.0.4")
pick("checksum file alone is not the zip",
    { release("0.0.5", { checksum_only = true }), release("0.0.4") }, "stable", "0.0.4")
pick("nothing suitable", { release("0.0.5-dev.1") }, "stable", nil)

if failures > 0 then
    print(failures .. " failure(s)")
    os.exit(1)
end
print("all version tests passed")
