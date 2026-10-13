local g = require("gettext")
local ffiUtil = require("ffi/util")
local T = ffiUtil.template

local Archiver = require("ffi/archiver")
local DataStorage = require("datastorage")
local NetworkManager = require("ui/network/manager")
local util = require("util")
local sha2 = require("ffi/sha2")

local PluginMetadata = require("bluetooth/plugin_metadata")
local PluginPath = require("bluetooth/plugin_path")
local SafePath = require("bluetooth/ota/safe_path")
local Version = require("bluetooth/ota/version")
local logger = require("logger")

local function verifyDigest(path, digest)
    if type(digest) ~= "string" then
        logger.err("No digest provided for asset, cannot verify")
        return false
    end

    local digest_type, expected_digest_hex = digest:match("(%w+):(%x+)")

    if digest_type ~= "sha256" then
        logger.err("Unknown digest type", digest_type)
        return false
    end

    -- The only way I know to do this is in-memory.
    -- Given the plugin is small this should be safe?
    local file = io.open(path, "rb")
    if not file then
        return false
    end
    local content = file:read("*a")
    file:close()
    if not content then
        return false
    end

    local actual_digest_hex = sha2.sha256(content)

    if expected_digest_hex:lower() ~= actual_digest_hex:lower() then
        logger.err("Digest mismatch:", expected_digest_hex, "!=", actual_digest_hex)
        return false
    end

    return true
end

--- Locates the plugin's root directory inside the downloaded archive by
--- finding `_meta.lua` and confirming it actually declares our repository
--- (not just any file that happens to be named `_meta.lua`, which could
--- belong to another plugin bundled alongside ours in the same archive).
---@param reader any
---@param expected_repository string
---@return string plugin_root directory prefix, or "" if not found
local function findPluginInArchive(reader, expected_repository)
    for entry in reader:iterate() do
        if entry.mode == "file" then
            local entry_directory, entry_filename = util.splitFilePathName(entry.path)
            if entry_filename == "_meta.lua" then
                local ok, content = pcall(function()
                    return reader:extractToMemory(entry.path)
                end)
                -- Plain find: "." and "-" in repository names are Lua pattern magic.
                if ok and content and content:find(expected_repository, 1, true) then
                    return entry_directory
                end
            end
        end
    end

    return ""
end

---@class BluetoothSelfUpdater
---@field settings BluetoothSettings
---@field github_api GithubAPI
---@field repository string
---@field latest_known_version string | nil
---@field is_pending_restart boolean
local BluetoothSelfUpdater = {
    plugin_path = PluginPath.get() or (DataStorage:getDataDir() .. "/plugins/bluetooth.koplugin"),
    release_asset_name = "^bluetooth%.koplugin%.zip$",
    release_cache_path = DataStorage:getDataDir() .. "/cache/bluetooth"
}

function BluetoothSelfUpdater:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

function BluetoothSelfUpdater:isPendingRestart()
    return self.is_pending_restart
end

function BluetoothSelfUpdater:isUpdateAvailable()
    local current_version = "v" .. PluginMetadata.getVersion()
    local latest_version = self.latest_known_version or current_version

    return Version.isNewer(current_version, latest_version)
end

function BluetoothSelfUpdater:getLatestReleaseVersion()
    -- Get the latest release version from github
    local current_version = "v" .. PluginMetadata.getVersion()
    return self.latest_known_version or current_version
end

--- Returns "stable", "beta" or "development". Falls back to "stable" if this
--- updater was constructed without a settings object (shouldn't normally
--- happen, but fetchLatestVersion/downloadLatestRelease shouldn't crash
--- over it).
function BluetoothSelfUpdater:getUpdateChannel()
    if not self.settings then
        return "stable"
    end
    return self.settings:getUpdateChannel()
end

---@return boolean ok false when the check itself failed (offline, rate-limited...)
---@return string|nil err
function BluetoothSelfUpdater:fetchLatestVersion()
    if not PluginMetadata.hasRepository() then
        logger.warn("Unknown repository - cannot fetch latest version")
        return false, g("No repository defined")
    end

    local channel = self:getUpdateChannel()

    local ok, releases = self.github_api:getReleases(PluginMetadata.getRepository())
    if not ok or not releases then
        return false, g("Could not reach GitHub")
    end

    -- nil when the channel has no release yet; don't keep a version cached
    -- from the previously selected channel.
    local version = Version.pickLatest(releases, channel, self.release_asset_name)

    self.latest_known_version = version
    -- Tracked so a caller (e.g. the menu) can tell whether the cached
    -- latest_known_version was actually fetched for the channel currently
    -- selected in settings, in case those ever drift apart.
    self.latest_known_channel = channel
    return true
end

function BluetoothSelfUpdater:downloadLatestRelease(progress_callback)
    if not self.latest_known_version then
        logger.err("Latest release is not defined")
        return false, g("No latest release")
    end

    if not PluginMetadata.hasRepository() then
        logger.warn("Unknown repository - cannot fetch latest version")
        return false, g("No repository defined")
    end

    local download_path = self.release_cache_path ..
        "/plugin-" .. self.latest_known_version ..
        "-" .. os.time() .. ".zip"

    local download_directory, _ = util.splitFilePathName(download_path)

    local directory_exists, directory_error_message = util.makePath(download_directory)
    if not directory_exists then
        return false, directory_error_message
    end

    local last_percent = -1
    local ok, result, asset = self.github_api:downloadReleaseArchive(
        PluginMetadata.getRepository(),
        self.latest_known_version,
        self.release_asset_name,
        download_path,
        function(bytes_downloaded, bytes_total)
            if progress_callback then
                -- Every report repaints the screen, which is slow on e-ink,
                -- so report in 10% steps.
                local percent = math.floor(100 * bytes_downloaded / bytes_total / 10) * 10
                if percent ~= last_percent then
                    last_percent = percent
                    progress_callback("download", percent)
                end
            end
        end
    )

    if not ok then
        logger.err("Failed to download release", result)
        return false, result
    end

    if not verifyDigest(download_path, asset.digest) then
        util.removeFile(download_path)
        return false, g("Failed digest verification")
    end

    return true, download_path
end

--- Extracts the plugin's files from the downloaded archive into a staging
--- directory beside target_path, then swaps it into place. A failure part way
--- through leaves the installed plugin untouched, and files the new version
--- no longer ships disappear with the old directory.
---
--- Uses two separate passes over the archive: one to locate the plugin root
--- (findPluginInArchive) and one to actually extract entries. Since the
--- underlying Reader may be stream-based, the reader is closed and reopened
--- between passes rather than assuming a second :iterate() call picks up
--- where the first left off (or works at all).
function BluetoothSelfUpdater:extractPlugin(source_path, target_path)
    -- Neither name ends in ".koplugin", so KOReader's plugin loader ignores them.
    local staging_path = target_path .. ".new"
    local backup_path = target_path .. ".bak"

    local reader = Archiver.Reader:new()
    if not reader:open(source_path) then
        return false, g("Failed to open downloaded archive.")
    end

    local plugin_root = findPluginInArchive(reader, PluginMetadata.getRepository())

    reader:close()

    if plugin_root == "" then
        return false, g("Could not locate plugin root (_meta.lua) in archive.")
    end

    ffiUtil.purgeDir(staging_path) -- leftovers from an earlier failed attempt
    local directory_exists, directory_error_message = util.makePath(staging_path)
    if not directory_exists then
        return false, directory_error_message
    end

    reader = Archiver.Reader:new()
    if not reader:open(source_path) then
        ffiUtil.purgeDir(staging_path)
        return false, g("Failed to re-open downloaded archive.")
    end

    -- plugin_root comes from util.splitFilePathName, which already ends in "/"
    -- (https://github.com/koreader/koreader/blob/master/frontend/util.lua).
    -- The trailing slash keeps this a path-segment match, so a sibling
    -- such as "bluetooth.koplugin-legacy/" isn't extracted too.
    local prefix = plugin_root
    local extracted_count = 0

    for entry in reader:iterate() do
        if entry.mode == "file" and entry.path:sub(1, #prefix) == prefix then
            local entry_path = entry.path:sub(#prefix + 1)

            if not SafePath.isSafeRelative(entry_path) then
                reader:close()
                ffiUtil.purgeDir(staging_path)
                return false, T(g("Unsafe path in archive: %1"), entry.path)
            end

            local extract_path = staging_path .. "/" .. entry_path

            local parent, _ = util.splitFilePathName(extract_path)
            if parent and parent ~= "" then
                util.makePath(parent)
            end

            local ok = reader:extractToPath(entry.path, extract_path)

            if not ok then
                reader:close()
                ffiUtil.purgeDir(staging_path)
                return false, T(g("Failed to extract file: %1"), entry.path)
            end
            extracted_count = extracted_count + 1
        end
    end

    reader:close()

    -- Never report success for an update that installed nothing.
    if extracted_count == 0 then
        ffiUtil.purgeDir(staging_path)
        return false, g("No plugin files found in archive.")
    end

    -- Swap. Renames within one directory are atomic, so the only window with
    -- no plugin in place is between the two renames.
    ffiUtil.purgeDir(backup_path)
    if not os.rename(target_path, backup_path) then
        ffiUtil.purgeDir(staging_path)
        return false, g("Could not move the installed plugin aside.")
    end
    if not os.rename(staging_path, target_path) then
        os.rename(backup_path, target_path) -- put the old version back
        ffiUtil.purgeDir(staging_path)
        return false, g("Could not move the new plugin into place.")
    end
    ffiUtil.purgeDir(backup_path)

    return true, nil
end

function BluetoothSelfUpdater:update(progress_callback)
    local ran = NetworkManager:goOnlineToRun(function()
        local download_ok, download_path = self:downloadLatestRelease(progress_callback)

        if not download_ok then
            if progress_callback then
                progress_callback("failed", 100, download_path)
            end
            return
        end

        local extract_ok, extract_message = self:extractPlugin(download_path, self.plugin_path)

        util.removeFile(download_path)

        if not extract_ok then
            logger.err("Extraction failed:", extract_message)
            if progress_callback then
                progress_callback("failed", 100, extract_message)
            end
            return
        end

        self.is_pending_restart = true

        if progress_callback then
            progress_callback("complete", 100, nil)
        end
    end)

    -- false means the callback never ran: offline, and Wi-Fi isn't set to
    -- turn on automatically (or the user cancelled).
    if ran == false and progress_callback then
        progress_callback("failed", 100, g("No network connection. Turn on Wi-Fi and try again."))
    end
end

return BluetoothSelfUpdater