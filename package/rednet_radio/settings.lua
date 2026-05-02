local util = require("rednet_radio.util")
local version = require("rednet_radio.version")

local settings = {}

local SETTINGS_PATH = "/rednet_radio/settings.json"
local REMIND_LATER_MS = 60 * 60 * 1000

local defaults = {
  show_never_option = false,
  remind_at_ms = 0,
  ignored_version = nil,
  settings_version = version.version,
}

local state = nil

local function copyDefaults()
  return util.mergeTables({}, defaults)
end

local function persist()
  local encoded = textutils.serializeJSON(state)
  if not encoded then
    return nil, "Could not serialize settings"
  end

  return util.writeAll(SETTINGS_PATH, encoded)
end

function settings.load()
  if state then
    return state
  end

  state = copyDefaults()
  local raw = util.readAll(SETTINGS_PATH)
  if raw then
    local decoded = textutils.unserializeJSON(raw)
    if type(decoded) == "table" then
      state = util.mergeTables(state, decoded)
    end
  end

  return state
end

function settings.get()
  return settings.load()
end

function settings.save()
  settings.load()
  return persist()
end

function settings.shouldShowNeverOption()
  return settings.get().show_never_option == true
end

function settings.setShowNeverOption(enabled)
  settings.get().show_never_option = enabled == true
  return persist()
end

function settings.toggleShowNeverOption()
  local current = settings.shouldShowNeverOption()
  settings.setShowNeverOption(not current)
  return not current
end

function settings.remindLater()
  settings.get().remind_at_ms = util.nowMilliseconds() + REMIND_LATER_MS
  return persist()
end

function settings.clearReminder()
  settings.get().remind_at_ms = 0
  return persist()
end

function settings.ignoreVersion(versionToIgnore)
  settings.get().ignored_version = versionToIgnore
  settings.get().remind_at_ms = 0
  return persist()
end

function settings.clearIgnoredVersion()
  settings.get().ignored_version = nil
  return persist()
end

function settings.shouldPromptForVersion(latestVersion)
  local current = settings.get()
  if not latestVersion or latestVersion == "" then
    return false
  end

  if current.ignored_version == latestVersion then
    return false
  end

  if (current.remind_at_ms or 0) > util.nowMilliseconds() then
    return false
  end

  return true
end

return settings
