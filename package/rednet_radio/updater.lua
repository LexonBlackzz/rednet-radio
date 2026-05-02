local config = require("rednet_radio.config")
local version = require("rednet_radio.version")
local util = require("rednet_radio.util")

local updater = {}
local INSTALL_MANIFEST_PATH = "/rednet_radio/install_manifest.json"
local ROLE_FILES = {
  host = {
    "radio_host.lua",
    "rednet_radio/config.lua",
    "rednet_radio/util.lua",
    "rednet_radio/directory.lua",
    "rednet_radio/playlist.lua",
    "rednet_radio/station.lua",
    "rednet_radio/rednet_api.lua",
    "rednet_radio/audio.lua",
    "rednet_radio/monitor.lua",
    "rednet_radio/updater.lua",
    "rednet_radio/version.lua",
    "rednet_radio/settings.lua",
  },
  client = {
    "radio_client.lua",
    "rednet_radio/config.lua",
    "rednet_radio/util.lua",
    "rednet_radio/directory.lua",
    "rednet_radio/rednet_api.lua",
    "rednet_radio/audio.lua",
    "rednet_radio/monitor.lua",
    "rednet_radio/updater.lua",
    "rednet_radio/version.lua",
    "rednet_radio/settings.lua",
  },
  all = {
    "radio_host.lua",
    "radio_client.lua",
    "rednet_radio/config.lua",
    "rednet_radio/util.lua",
    "rednet_radio/directory.lua",
    "rednet_radio/playlist.lua",
    "rednet_radio/station.lua",
    "rednet_radio/rednet_api.lua",
    "rednet_radio/audio.lua",
    "rednet_radio/monitor.lua",
    "rednet_radio/updater.lua",
    "rednet_radio/version.lua",
    "rednet_radio/settings.lua",
  },
}

local function normalizePackageUrl(packageUrl)
  packageUrl = packageUrl or config.package_url or ""
  if packageUrl:sub(-1) == "/" then
    packageUrl = packageUrl:sub(1, -2)
  end
  return packageUrl
end

local function parseVersionParts(value)
  local parts = {}
  for part in tostring(value or ""):gmatch("%d+") do
    parts[#parts + 1] = tonumber(part) or 0
  end
  return parts
end

local function compareVersions(left, right)
  local leftParts = parseVersionParts(left)
  local rightParts = parseVersionParts(right)
  local width = math.max(#leftParts, #rightParts)

  for index = 1, width do
    local leftPart = leftParts[index] or 0
    local rightPart = rightParts[index] or 0
    if leftPart < rightPart then
      return -1
    elseif leftPart > rightPart then
      return 1
    end
  end

  if tostring(left or "") == tostring(right or "") then
    return 0
  end

  return 0
end

local function fetch(url)
  if not http then
    return nil, "HTTP API is not available"
  end

  local response, err = http.get(url, nil, true)
  if not response then
    return nil, err or ("Request failed for %s"):format(url)
  end

  local body = response.readAll()
  response.close()
  return body
end

local function patchConfig(contents, websiteUrl, packageUrl)
  if websiteUrl and websiteUrl ~= "" then
    contents = contents:gsub(
      'local baseUrl = "https://raw%.githubusercontent%.com/LexonBlackzz/rednet%-radio/main"',
      ('local baseUrl = "%s"'):format(websiteUrl)
    )
  end

  if packageUrl and packageUrl ~= "" then
    contents = contents:gsub(
      'package_url = "[^"]*",',
      ('package_url = "%s",'):format(packageUrl)
    )
  end

  return contents
end

local function writeFile(path, contents)
  return util.writeAll(path, contents)
end

local function parseRemoteVersion(contents)
  if type(contents) ~= "string" then
    return nil, "Remote version payload was empty"
  end

  local remoteVersion = contents:match('version%s*=%s*"([^"]+)"')
    or contents:match("version%s*=%s*'([^']+)'")

  if not remoteVersion or remoteVersion == "" then
    return nil, "Could not parse remote version"
  end

  return remoteVersion
end

function updater.getCurrentVersion()
  return version.version
end

function updater.loadInstallManifest()
  local raw = util.readAll(INSTALL_MANIFEST_PATH)
  if not raw then
    return nil, ("Install manifest is missing at %s"):format(INSTALL_MANIFEST_PATH)
  end

  local decoded = textutils.unserializeJSON(raw)
  if type(decoded) ~= "table" then
    return nil, "Install manifest could not be parsed"
  end

  return decoded
end

function updater.saveInstallManifest(manifest)
  local encoded = textutils.serializeJSON(manifest)
  if not encoded then
    return nil, "Could not serialize install manifest"
  end

  return util.writeAll(INSTALL_MANIFEST_PATH, encoded)
end

function updater.check(packageUrl)
  local normalizedPackageUrl = normalizePackageUrl(packageUrl)
  if normalizedPackageUrl == "" then
    return nil, "Package URL is not configured"
  end

  local versionUrl = normalizedPackageUrl .. "/rednet_radio/version.lua"
  local contents, err = fetch(versionUrl)
  if not contents then
    return nil, err
  end

  local latestVersion, parseErr = parseRemoteVersion(contents)
  if not latestVersion then
    return nil, parseErr
  end

  local currentVersion = updater.getCurrentVersion()
  local comparison = compareVersions(currentVersion, latestVersion)

  return {
    current_version = currentVersion,
    latest_version = latestVersion,
    update_available = comparison < 0,
    version_url = versionUrl,
    package_url = normalizedPackageUrl,
  }
end

function updater.getStatusSummary(packageUrl)
  local result, err = updater.check(packageUrl)
  if not result then
    return ("update check failed (%s)"):format(err or "unknown error")
  end

  if result.update_available then
    return ("update available: %s -> %s"):format(
      result.current_version,
      result.latest_version
    )
  end

  return ("up to date (%s)"):format(result.current_version)
end

function updater.applyLocalUpdate()
  local manifest, manifestErr = updater.loadInstallManifest()
  if not manifest then
    return nil, manifestErr
  end

  local role = manifest.role
  local packageUrl = normalizePackageUrl(manifest.package_url or config.package_url)
  local websiteUrl = manifest.website_url or config.base_url
  local selectedFiles = ROLE_FILES[role]
  if not selectedFiles then
    return nil, ("Unknown installed role: %s"):format(tostring(role))
  end

  local checkResult, checkErr = updater.check(packageUrl)
  if not checkResult then
    return nil, checkErr
  end

  if not checkResult.update_available then
    return {
      updated = false,
      current_version = checkResult.current_version,
      latest_version = checkResult.latest_version,
      message = ("Already up to date (%s)"):format(checkResult.current_version),
    }
  end

  for _, path in ipairs(selectedFiles) do
    local url = packageUrl .. "/" .. path
    local contents, err = fetch(url)
    if not contents then
      return nil, ("Failed to download %s: %s"):format(path, err or "unknown error")
    end

    if path == "rednet_radio/config.lua" then
      contents = patchConfig(contents, websiteUrl, packageUrl)
    end

    local ok, writeErr = writeFile(path, contents)
    if not ok then
      return nil, writeErr
    end
  end

  manifest.package_url = packageUrl
  manifest.website_url = websiteUrl
  manifest.installed_version = checkResult.latest_version
  manifest.updated_at_ms = util.nowMilliseconds()
  local saved, saveErr = updater.saveInstallManifest(manifest)
  if not saved then
    return nil, saveErr
  end

  return {
    updated = true,
    current_version = checkResult.current_version,
    latest_version = checkResult.latest_version,
    message = ("Updated from %s to %s. Restart to load the new files."):format(
      checkResult.current_version,
      checkResult.latest_version
    ),
  }
end

return updater
