local g = require("gettext")
local T = require("ffi/util").template

local Archiver = require("ffi/archiver")
local DataStorage = require("datastorage")
local NetworkManager = require("ui/network/manager")
local util = require("util")
local sha2 = require("ffi/sha2")

local PluginMetadata = require("bluetooth/plugin_metadata")
local logger = require("logger")

local function verifyDigest(path, digest)
    if type(digest) ~= "string" then
        logger:err("No digest provided for asset, cannot verify")
        return false
    end

    local digest_type, expected_digest_hex = digest:match("(%w+):(%x+)")

    if digest_type ~= "sha256" then
        logger:err("Unknown digest type", digest_type)
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
        logger:err("Digest mismatch:", expected_digest_hex, "!=", actual_digest_hex)
        return false
    end

    return true
end

--- Walks up from this file's own location until it finds a directory
--- ending in `.koplugin`. This has to walk up (rather than just checking
--- the immediate parent) because self_updater.lua may be nested arbitrarily
--- deep inside the plugin (e.g. under `ota/`), and checking only one level
--- silently falls through to the hardcoded fallback path below, which can
--- point at the wrong install location entirely.
local function getPluginPath()
    local source = debug.getinfo(1, "S").source
    local path = source:match("@(.*)")
    local dir = path and path:match("(.*)/")

    while dir and dir ~= "" do
        if dir:match("%.koplugin$") then
            return dir
        end
        dir = dir:match("(.*)/")
    end

    return DataStorage:getDataDir() .. "/plugins/bluetooth.koplugin"
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
                if ok and content and content:match(expected_repository) then
                    return entry_directory
                end
            end
        end
    end

    return ""
end

---@param version string
---@return number major
---@return number minor
---@return number patch
---@return string | nil prerelease
---@return string | nil build
local function parseVersion(version)
    local major, minor, patch, labels = tostring(version):match("v?(%d+)%.(%d+)%.(%d+)(.*)")

    local prerelease = nil
    local build = nil

    if labels and labels ~= "" then
        local build_indicator_index = labels:find("+") or (#labels + 1)
        local pre_part = labels:sub(1, build_indicator_index - 1)

        -- Accept both a strict-semver hyphen ("0.0.2-dev1") and a plain dot
        -- ("0.0.2.dev1", which is what this plugin's _meta.lua actually
        -- uses). Treating only "-" as a valid separator meant dot-separated
        -- dev versions parsed with prerelease == nil, making them
        -- indistinguishable from an actual stable release of the same
        -- major.minor.patch — which is exactly why "0.0.2.dev1" and "0.0.2"
        -- were comparing as equal and no update was ever detected.
        if pre_part:sub(1, 1) == "-" or pre_part:sub(1, 1) == "." then
            prerelease = pre_part:sub(2)
        elseif pre_part ~= "" then
            -- Some other leftover suffix with no recognized separator at
            -- all (e.g. "0.0.2dev1") - still treat it as a prerelease label
            -- rather than silently dropping it, since a non-empty suffix
            -- after patch always means "not the plain release".
            prerelease = pre_part
        end

        if labels:sub(build_indicator_index, build_indicator_index) == "+" then
            build = labels:sub(build_indicator_index + 1)
        end
    end

    return tonumber(major) or 0, tonumber(minor) or 0, tonumber(patch) or 0, prerelease, build
end

---@param version_a string
---@param version_b string
local function isVersionLater(version_a, version_b)
    local major_a, minor_a, patch_a, prerelease_a = parseVersion(version_a)
    local major_b, minor_b, patch_b, prerelease_b = parseVersion(version_b)

    if major_b > major_a then
        return true
    end

    if minor_b > minor_a then
        return true
    end

    if patch_b > patch_a then
        return true
    end

    if prerelease_b ~= prerelease_a then
        return true
    end

    return false
end

---@class BluetoothSelfUpdater
---@field settings BluetoothSettings
---@field github_api GithubAPI
---@field repository string
---@field latest_known_version string | nil
---@field is_pending_restart boolean
local BluetoothSelfUpdater = {
    plugin_path = getPluginPath(),
    release_asset_name = "%a+.koplugin.zip",
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

    return isVersionLater(current_version, latest_version)
end

function BluetoothSelfUpdater:getLatestReleaseVersion()
    -- Get the latest release version from github
    local current_version = "v" .. PluginMetadata.getVersion()
    return self.latest_known_version or current_version
end

--- Returns "stable" or "development". Falls back to "stable" if this
--- updater was constructed without a settings object (shouldn't normally
--- happen, but fetchLatestVersion/downloadLatestRelease shouldn't crash
--- over it).
function BluetoothSelfUpdater:getUpdateChannel()
    if not self.settings then
        return "stable"
    end
    return self.settings:getUpdateChannel()
end

function BluetoothSelfUpdater:fetchLatestVersion()
    if not PluginMetadata.hasRepository() then
        logger:warn("Unknown repository - cannot fetch latest version")
        return
    end

    local channel = self:getUpdateChannel()
    local include_prereleases = (channel == "development")

    local ok, version = self.github_api:getLatestReleaseVersion(
        PluginMetadata.getRepository(),
        include_prereleases
    )

    if not ok or not version then
        return
    end

    self.latest_known_version = version
    -- Tracked so a caller (e.g. the menu) can tell whether the cached
    -- latest_known_version was actually fetched for the channel currently
    -- selected in settings, in case those ever drift apart.
    self.latest_known_channel = channel
end

function BluetoothSelfUpdater:downloadLatestRelease(progress_callback)
    if not self.latest_known_version then
        logger:err("Latest release is not defined")
        return false, g("No latest release")
    end

    if not PluginMetadata.hasRepository() then
        logger:warn("Unknown repository - cannot fetch latest version")
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

    local ok, result, asset = self.github_api:downloadReleaseArchive(
        PluginMetadata.getRepository(),
        self.latest_known_version,
        self.release_asset_name,
        download_path,
        function(bytes_downloaded, bytes_total)
            if progress_callback then
                progress_callback(
                    "download",
                    math.floor(100 * bytes_downloaded / bytes_total)
                )
            end
        end
    )

    if not ok then
        logger:err("Failed to download release", result)
        return false, result
    end

    if not verifyDigest(download_path, asset.digest) then
        util.removeFile(download_path)
        return false, g("Failed digest verification")
    end

    return true, download_path
end

--- Extracts the plugin's files from the downloaded archive into target_path.
---
--- Uses two separate passes over the archive: one to locate the plugin root
--- (findPluginInArchive) and one to actually extract entries. Since the
--- underlying Reader may be stream-based, the reader is closed and reopened
--- between passes rather than assuming a second :iterate() call picks up
--- where the first left off (or works at all).
function BluetoothSelfUpdater:extractPlugin(source_path, target_path)
    local reader = Archiver.Reader:new()
    if not reader:open(source_path) then
        return false, g("Failed to open downloaded archive.")
    end

    local directory_exists, directory_error_message = util.makePath(target_path)
    if not directory_exists then
        reader:close()

        return false, directory_error_message
    end

    local plugin_root = findPluginInArchive(reader, PluginMetadata.getRepository())

    reader:close()

    if plugin_root == "" then
        return false, g("Could not locate plugin root (_meta.lua) in archive.")
    end

    reader = Archiver.Reader:new()
    if not reader:open(source_path) then
        return false, g("Failed to re-open downloaded archive.")
    end

    -- Include the trailing slash so this is a path-segment match, not a bare
    -- string prefix match. Without it, a sibling directory that happens to
    -- share the same prefix (e.g. "bluetooth.koplugin-legacy/") would also
    -- match and get extracted into our target path.
    local prefix = plugin_root .. "/"

    for entry in reader:iterate() do
        if entry.mode == "file" and entry.path:sub(1, #prefix) == prefix then
            local entry_path = entry.path:sub(#prefix + 1)

            local extract_path = target_path .. "/" .. entry_path

            local parent, _ = util.splitFilePathName(extract_path)
            if parent and parent ~= "" then
                util.makePath(parent)
            end

            local ok = reader:extractToPath(entry.path, extract_path)

            if not ok then
                reader:close()
                return false, T(g("Failed to extract file: %1"), entry.path)
            end
        end
    end

    reader:close()

    return true, nil
end

function BluetoothSelfUpdater:update(progress_callback)
    NetworkManager:goOnlineToRun(function()
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
            logger:err("Extraction failed:", extract_message)
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
end

return BluetoothSelfUpdater