--- Version parsing, ordering and channel rules for OTA updates.
---
--- Pure Lua with no KOReader dependencies, so it can be tested with plain
--- luajit. Tags look like "0.0.4", "0.0.4-beta.1" or "0.0.4-dev.3"; the older
--- "0.0.3.dev.3" form (dot instead of hyphen) is still accepted.

local Version = {}

-- Pre-release labels follow the release pipeline (dev -> beta -> rc ->
-- stable) instead of semver's alphabetical order, where "beta" < "dev".
-- Unknown labels sort lowest.
local LABEL_RANK = {
    dev = 1,
    beta = 2,
    rc = 3,
}

-- Which pre-release labels each update channel accepts. Stable releases
-- (no label) are accepted by every channel.
local CHANNEL_LABELS = {
    stable = {},
    beta = { beta = true, rc = true },
    development = { dev = true, beta = true, rc = true },
}

Version.CHANNELS = { "stable", "beta", "development" }

---@class ParsedVersion
---@field major integer
---@field minor integer
---@field patch integer
---@field label string|nil pre-release label, e.g. "dev", nil for stable
---@field label_number integer pre-release number, e.g. 3 for "dev.3"

---@param version string
---@return ParsedVersion|nil
function Version.parse(version)
    local major, minor, patch, rest = tostring(version):match("^v?(%d+)%.(%d+)%.(%d+)(.*)$")
    if not major then
        return nil
    end

    -- Build metadata ("+...") never affects ordering (semver 2.0.0, item 10).
    rest = rest:gsub("%+.*$", "")

    local label, label_number = nil, 0
    if rest ~= "" then
        local name, number = rest:match("^[%-%.]?(%a+)[%.%-]?(%d*)$")
        label = name and name:lower() or rest
        label_number = tonumber(number) or 0
    end

    return {
        major = tonumber(major),
        minor = tonumber(minor),
        patch = tonumber(patch),
        label = label,
        label_number = label_number,
    }
end

local function sign(a, b)
    if a < b then return -1 end
    if a > b then return 1 end
    return 0
end

--- Returns -1, 0 or 1 as a is older than, the same as, or newer than b.
--- Unparseable versions sort below everything else.
---@param a string
---@param b string
---@return integer
function Version.compare(a, b)
    local pa, pb = Version.parse(a), Version.parse(b)
    if not pa or not pb then
        return sign(pa and 1 or 0, pb and 1 or 0)
    end

    local result = sign(pa.major, pb.major)
    if result == 0 then result = sign(pa.minor, pb.minor) end
    if result == 0 then result = sign(pa.patch, pb.patch) end
    if result ~= 0 then return result end

    -- Same x.y.z: a stable release is newer than any of its pre-releases.
    if pa.label == nil or pb.label == nil then
        return sign(pa.label == nil and 1 or 0, pb.label == nil and 1 or 0)
    end

    result = sign(LABEL_RANK[pa.label] or 0, LABEL_RANK[pb.label] or 0)
    if result == 0 then result = sign(pa.label_number, pb.label_number) end
    return result
end

---@param current string
---@param candidate string
---@return boolean
function Version.isNewer(current, candidate)
    return Version.compare(candidate, current) > 0
end

---@param channel string
---@return boolean
function Version.isChannel(channel)
    return CHANNEL_LABELS[channel] ~= nil
end

--- Whether a release with this version belongs on the given channel.
---@param channel string
---@param version string
---@return boolean
function Version.channelAccepts(channel, version)
    local labels = CHANNEL_LABELS[channel]
    local parsed = Version.parse(version)
    if not labels or not parsed then
        return false
    end
    return parsed.label == nil or labels[parsed.label] == true
end

--- Highest release version the channel accepts. Chosen by version, not by
--- GitHub's list order, so publishing an older hotfix after a newer
--- pre-release can't make it look like the latest.
---
--- Releases without an asset matching `asset_pattern` are skipped: CI attaches
--- the zip after the release is published, so there is a window where a
--- release exists but can't be installed.
---@param releases table[] GitHub release objects
---@param channel string
---@param asset_pattern string Lua pattern the zip's name must match
---@return string|nil
function Version.pickLatest(releases, channel, asset_pattern)
    local latest = nil
    for _, release in ipairs(releases) do
        local version = release.tag_name
        -- A release marked pre-release on GitHub never reaches stable,
        -- whatever its tag says.
        local allowed = Version.channelAccepts(channel, version)
            and not (channel == "stable" and release.prerelease)

        local has_asset = false
        for _, asset in ipairs(type(release.assets) == "table" and release.assets or {}) do
            if type(asset.name) == "string" and asset.name:match(asset_pattern) then
                has_asset = true
                break
            end
        end

        if allowed and has_asset and (latest == nil or Version.isNewer(latest, version)) then
            latest = version
        end
    end
    return latest
end

return Version
