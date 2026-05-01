local VERSION = "v1"
local DEFAULT_PACKAGE_URL = "https://raw.githubusercontent.com/LexonBlackzz/rednet-radio/main/package"
local FILES = {
  "radio_host.lua",
  "radio_client.lua",
  "rednet_radio/config.lua",
  "rednet_radio/util.lua",
  "rednet_radio/directory.lua",
  "rednet_radio/playlist.lua",
  "rednet_radio/station.lua",
  "rednet_radio/rednet_api.lua",
  "rednet_radio/audio.lua",
}

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
  },
  client = {
    "radio_client.lua",
    "rednet_radio/config.lua",
    "rednet_radio/util.lua",
    "rednet_radio/directory.lua",
    "rednet_radio/rednet_api.lua",
    "rednet_radio/audio.lua",
  },
  all = FILES,
}

local function clear()
  term.clear()
  term.setCursorPos(1, 1)
end

local function printHeader()
  clear()
  print("Rednet Radio Installer " .. VERSION)
  print("")
end

local function prompt(label, default)
  if default and default ~= "" then
    write(label .. " [" .. default .. "]: ")
  else
    write(label .. ": ")
  end

  local value = read()
  if value == "" then
    return default
  end

  return value
end

local function ensureDirFor(path)
  local dir = fs.getDir(path)
  if dir and dir ~= "" and not fs.exists(dir) then
    fs.makeDir(dir)
  end
end

local function fetch(url)
  local response, err = http.get(url, nil, true)
  if not response then
    return nil, err or ("Request failed for " .. url)
  end

  local body = response.readAll()
  response.close()
  return body
end

local function writeFile(path, contents)
  ensureDirFor(path)

  local handle = fs.open(path, "w")
  if not handle then
    return nil, "Could not open " .. path .. " for writing"
  end

  handle.write(contents)
  handle.close()
  return true
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

local function installFiles(role, packageUrl, websiteUrl)
  local selectedFiles = ROLE_FILES[role]
  if not selectedFiles then
    return nil, "Unknown role: " .. tostring(role)
  end

  for index, path in ipairs(selectedFiles) do
    local url = packageUrl .. "/" .. path
    print(("[%d/%d] Downloading %s"):format(index, #selectedFiles, path))

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

  return true
end

local function main()
  if not http then
    print("HTTP is not enabled.")
    print("Enable the HTTP API in CC:Tweaked first.")
    return
  end

  printHeader()
  print("This will install Rednet Radio files onto this computer.")
  print("")
  print("Roles:")
  print("  host   - station host only")
  print("  client - listener client only")
  print("  all    - both host and client")
  print("")

  local role = prompt("Install role", "all")
  if not ROLE_FILES[role] then
    print("")
    print("Invalid role. Use host, client, or all.")
    return
  end

  local packageUrl = prompt("Package base URL", DEFAULT_PACKAGE_URL)
  if packageUrl:sub(-1) == "/" then
    packageUrl = packageUrl:sub(1, -2)
  end

  local websiteUrl = prompt("Website base URL for stations.json", "https://raw.githubusercontent.com/LexonBlackzz/rednet-radio/main")
  if websiteUrl:sub(-1) == "/" then
    websiteUrl = websiteUrl:sub(1, -2)
  end

  print("")
  local ok, err = installFiles(role, packageUrl, websiteUrl)
  if not ok then
    print("Install failed: " .. err)
    return
  end

  print("")
  print("Install complete.")
  print("")

  if role == "host" then
    print("Run: radio_host <station_id>")
  elseif role == "client" then
    print("Run: radio_client")
  else
    print("Run either:")
    print("  radio_host <station_id>")
    print("  radio_client")
  end
end

main()
