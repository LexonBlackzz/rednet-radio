local util = require("rednet_radio.util")
local version = require("rednet_radio.version")

local settings = {}

local SETTINGS_PATH = "/rednet_radio/settings.json"
local DEFAULT_REMIND_LATER_MINUTES = 60
local MIN_REMIND_LATER_MINUTES = 5
local MAX_REMIND_LATER_MINUTES = 180
local REMIND_LATER_STEP_MINUTES = 5

local defaults = {
  show_never_option = false,
  remind_at_ms = 0,
  ignored_version = nil,
  remind_later_minutes = DEFAULT_REMIND_LATER_MINUTES,
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

function settings.getRemindLaterMinutes()
  local minutes = tonumber(settings.get().remind_later_minutes) or DEFAULT_REMIND_LATER_MINUTES
  minutes = math.floor(minutes + 0.5)
  if minutes < MIN_REMIND_LATER_MINUTES then
    minutes = MIN_REMIND_LATER_MINUTES
  elseif minutes > MAX_REMIND_LATER_MINUTES then
    minutes = MAX_REMIND_LATER_MINUTES
  end
  return minutes
end

function settings.getRemindLaterStepMinutes()
  return REMIND_LATER_STEP_MINUTES
end

function settings.setRemindLaterMinutes(minutes)
  settings.get().remind_later_minutes = minutes
  settings.get().remind_later_minutes = settings.getRemindLaterMinutes()
  return persist()
end

function settings.adjustRemindLaterMinutes(deltaMinutes)
  local current = settings.getRemindLaterMinutes()
  settings.setRemindLaterMinutes(current + (deltaMinutes or 0))
  return settings.getRemindLaterMinutes()
end

function settings.remindLater()
  settings.get().remind_at_ms = util.nowMilliseconds() + (settings.getRemindLaterMinutes() * 60 * 1000)
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
