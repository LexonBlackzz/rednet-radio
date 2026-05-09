local util = require("rednet_radio.util")
local version = require("rednet_radio.version")

local settings = {}

local SETTINGS_PATH = "/rednet_radio/settings.json"
local DEFAULT_REMIND_LATER_MINUTES = 60
local MIN_REMIND_LATER_MINUTES = 5
local MAX_REMIND_LATER_MINUTES = 180
local REMIND_LATER_STEP_MINUTES = 5

-- CC:Tweaked color number constants for default palette
local DEFAULT_PALETTE = {
  bg     = 2048,  -- colors.blue
  panel  = 8,     -- colors.lightBlue
  header = 2,     -- colors.orange
  accent = 16384, -- colors.red
  text   = 1,     -- colors.white
  dim    = 256,   -- colors.lightGray
  good   = 32,    -- colors.lime
  warn   = 16,    -- colors.yellow
}

local defaults = {
  show_never_option = false,
  enable_visualizer = true,
  auto_update = false,
  last_station_id = nil,
  remind_at_ms = 0,
  ignored_version = nil,
  remind_later_minutes = DEFAULT_REMIND_LATER_MINUTES,
  settings_version = version.version,
  allow_remote_skip = true,
  allow_remote_shuffle = true,
  enable_redstone_announcement = false,
  announcement_redstone_side = "back",
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

function settings.getEnableVisualizer()
  local s = settings.get()
  if s.enable_visualizer == nil then return true end
  return s.enable_visualizer
end

function settings.setEnableVisualizer(enable)
  settings.get().enable_visualizer = enable
  return persist()
end

function settings.toggleEnableVisualizer()
  local current = settings.getEnableVisualizer()
  settings.setEnableVisualizer(not current)
  return not current
end

function settings.getAutoUpdate()
  return settings.get().auto_update == true
end

function settings.setAutoUpdate(enable)
  settings.get().auto_update = enable
  return persist()
end

function settings.toggleAutoUpdate()
  local current = settings.getAutoUpdate()
  settings.setAutoUpdate(not current)
  return not current
end

function settings.getLastStationId()
  return settings.get().last_station_id
end

function settings.setLastStationId(id)
  settings.get().last_station_id = id
  return persist()
end

function settings.clearLastStationId()
  settings.get().last_station_id = nil
  return persist()
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

function settings.getAllowRemoteSkip()
  return settings.get().allow_remote_skip == true
end

function settings.setAllowRemoteSkip(enable)
  settings.get().allow_remote_skip = enable == true
  return persist()
end

function settings.toggleAllowRemoteSkip()
  local current = settings.getAllowRemoteSkip()
  settings.setAllowRemoteSkip(not current)
  return not current
end

function settings.getAllowRemoteShuffle()
  return settings.get().allow_remote_shuffle == true
end

function settings.setAllowRemoteShuffle(enable)
  settings.get().allow_remote_shuffle = enable == true
  return persist()
end

function settings.toggleAllowRemoteShuffle()
  local current = settings.getAllowRemoteShuffle()
  settings.setAllowRemoteShuffle(not current)
  return not current
end

function settings.getEnableRedstoneAnnouncement()
  return settings.get().enable_redstone_announcement == true
end

function settings.setEnableRedstoneAnnouncement(enable)
  settings.get().enable_redstone_announcement = enable == true
  return persist()
end

function settings.toggleEnableRedstoneAnnouncement()
  local current = settings.getEnableRedstoneAnnouncement()
  settings.setEnableRedstoneAnnouncement(not current)
  return not current
end

function settings.getAnnouncementRedstoneSide()
  local side = settings.get().announcement_redstone_side
  local valid = { bottom = true, top = true, back = true, front = true, left = true, right = true }
  if not valid[side] then return "back" end
  return side
end

function settings.setAnnouncementRedstoneSide(side)
  settings.get().announcement_redstone_side = side
  return persist()
end

function settings.cycleAnnouncementRedstoneSide()
  local sides = { "bottom", "top", "back", "front", "left", "right" }
  local current = settings.getAnnouncementRedstoneSide()
  local idx = 1
  for i, s in ipairs(sides) do
    if s == current then idx = i; break end
  end
  idx = idx + 1; if idx > #sides then idx = 1 end
  settings.setAnnouncementRedstoneSide(sides[idx])
  return sides[idx]
end

-- ── Palette ──────────────────────────────────────────────────────────────

function settings.getPalette()
  local s = settings.get()
  if type(s.palette) ~= "table" then
    s.palette = util.copyTable(DEFAULT_PALETTE)
  end
  -- Fill any missing roles with defaults
  for k, v in pairs(DEFAULT_PALETTE) do
    if s.palette[k] == nil then
      s.palette[k] = v
    end
  end
  return s.palette
end

function settings.setPaletteColor(role, colorValue)
  local s = settings.get()
  if type(s.palette) ~= "table" then
    s.palette = util.copyTable(DEFAULT_PALETTE)
  end
  s.palette[role] = colorValue
  return persist()
end

function settings.resetPalette()
  local s = settings.get()
  s.palette = util.copyTable(DEFAULT_PALETTE)
  return persist()
end

-- Named colour presets
local PALETTE_PRESETS = {
  default = {
    bg=2048, panel=8, header=2, accent=16384, text=1, dim=256, good=32, warn=16
  },
  light = {
    bg=1,  panel=256, header=8, accent=2, text=32768, dim=128, good=8192, warn=16
  },
  dark = {
    bg=32768, panel=128, header=1024, accent=512, text=1, dim=256, good=32, warn=16
  },
}

function settings.applyPreset(name)
  local preset = PALETTE_PRESETS[name]
  if not preset then return nil, "Unknown preset: " .. tostring(name) end
  local s = settings.get()
  s.palette = util.copyTable(preset)
  return persist()
end

function settings.getPresetNames()
  return { "default", "light", "dark" }
end

return settings
