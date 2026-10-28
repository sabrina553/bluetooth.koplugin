-- Run from the repo root: luajit tests/keys_store_test.lua
package.path = "bluetooth.koplugin/?.lua;tests/?.lua;" .. package.path
local rejectDescription = require("helpers").rejectDescription
local errs, warns = {}, {}
package.preload["logger"] = function()
    local noop = function() end
    return { dbg = noop, info = noop,
        warn = function(...) warns[#warns + 1] = table.concat({ ... }, " ") end,
        err = function(...) errs[#errs + 1] = table.concat({ ... }, " ") end }
end
package.preload["datastorage"] = function() return { getSettingsDir = function() return "/nonexistent" end } end
-- In-memory "files" keyed by path, so a second open sees what the first flushed.
local files = {}
package.preload["luasettings"] = function()
    return { open = function(_, path)
        if path == "/throws" then error("disk gone") end
        files[path] = files[path] or {}
        local kv = files[path]
        return {
            readSetting = function(_, k, d) if kv[k] ~= nil then return kv[k] end return d end,
            saveSetting = function(_, k, v) kv[k] = v end,
            flush = function() end,
        }
    end }
end

local Store = require("bluetooth/keys/store")

local failures = 0
local function check(cond, message)
    rejectDescription(cond)
    if not cond then failures = failures + 1; print("FAIL " .. message) end
end

local path = os.tmpname()
local R = "Kobo Remote"
local function key(name) return { kind = "key", name = name } end

local store = Store:new({ path = path })
check(#store:list(R) == 0, "fresh store is empty")
store:set(R, { code = 108, screens = { reader = true, filemanager = true }, action = key("LPgFwd") })
check(#store:list(R) == 1, "set appends a binding")
local again = Store:new({ path = path }):list(R)
check(#again == 1 and again[1].code == 108 and again[1].screens.reader
    and again[1].screens.filemanager and again[1].action.name == "LPgFwd", "binding persisted")

-- list returns a copy
local l = store:list(R); l[1].code = 1; l[1].screens.reader = nil
check(store:list(R)[1].code == 108 and store:list(R)[1].screens.reader, "list returns a copy")

-- Overlapping screen replaces; disjoint screen appends
store:set(R, { code = 108, screens = { reader = true }, action = key("LPgBack") })
check(#store:list(R) == 1 and store:list(R)[1].action.name == "LPgBack", "overlapping set replaces")

store:set(R, { code = 108, screens = { reader = true, filemanager = true }, action = key("LPgFwd") })
check(#store:list(R) == 1, "both-screen set replaces the single")

-- Same code on a disjoint screen appends
store:set(R, { code = 55, screens = { reader = true }, action = key("A") })
store:set(R, { code = 55, screens = { filemanager = true }, action = key("B") })
check(#store:list(R) == 3, "disjoint screens append")
store:remove(R, 55, "reader"); store:remove(R, 55, "filemanager")

-- remove
store:remove(R, 108, "reader")
check(#store:list(R) == 1 and store:list(R)[1].screens.reader == nil
    and store:list(R)[1].screens.filemanager == true, "remove drops one screen")
store:remove(R, 108, "filemanager")
check(#store:list(R) == 0, "removing the last screen deletes the binding")
store:remove(R, 999, "reader") -- no error

-- split
store:set(R, { code = 103, screens = { reader = true, filemanager = true }, action = key("LPgBack") })
store:split(R, 103, "filemanager", key("Up"))
local s = store:list(R)
check(#s == 2, "split gives two bindings")
local byScreen = {}
for _, b in ipairs(s) do
    local n = 0
    for _ in pairs(b.screens) do n = n + 1 end
    check(n == 1, "each split binding has one screen")
    for sc in pairs(b.screens) do byScreen[sc] = b.action.name end
end
check(byScreen.reader == "LPgBack" and byScreen.filemanager == "Up", "split actions differ per screen")
check(Store:new({ path = path }):list(R)[2] ~= nil, "split persisted")

-- remotes sorted, unknown remote
store:set("Alpha", { code = 1, screens = { reader = true }, action = key("X") })
local rs = store:remotes()
check(rs[1] == "Alpha" and rs[2] == R and #rs == 2, "remotes sorted")
check(next(store:list("Unknown")) == nil, "unknown remote is empty")

-- garbage
files[path] = { bindings = "junk" }
local g = Store:new({ path = path })
check(next(g:list(R)) == nil and #g:remotes() == 0, "garbage bindings give an empty store")
files[path] = { bindings = { [R] = "junk", Ok = { { code = 1, screens = { reader = true }, action = key("A") } } } }
local g2 = Store:new({ path = path })
check(next(g2:list(R)) == nil and #g2:list("Ok") == 1, "garbage remote entry skipped")

-- open failure: logged at open and again at each write.
errs = {}
local broken = Store:new({ path = "/throws" })
check(#errs == 1 and errs[1]:find("cannot open", 1, true), "open failure logs an error")
broken:set(R, { code = 5, screens = { reader = true }, action = key("A") })
check(#errs == 2 and errs[2]:find("not saved", 1, true), "write without a handle logs an error")

os.remove(path)
if failures > 0 then os.exit(1) end
print("keys_store_test: ok")
