local util = {}

function util.nowMilliseconds()
  return os.epoch("utc")
end

function util.ensureDir(path)
  if not fs.exists(path) then
    fs.makeDir(path)
  end
end

function util.readAll(path)
  if not fs.exists(path) then
    return nil
  end

  local handle = fs.open(path, "r")
  if not handle then
    return nil, ("Could not open %s for reading"):format(path)
  end

  local contents = handle.readAll()
  handle.close()
  return contents
end

function util.writeAll(path, contents)
  local dir = fs.getDir(path)
  if dir and dir ~= "" then
    util.ensureDir(dir)
  end

  local handle = fs.open(path, "w")
  if not handle then
    return nil, ("Could not open %s for writing"):format(path)
  end

  handle.write(contents)
  handle.close()
  return true
end

function util.fetchJson(url, cachePath)
  if not http then
    return nil, "HTTP API is not available"
  end

  local response, err = http.get(url, nil, true)
  if response then
    local raw = response.readAll()
    response.close()

    local decoded = textutils.unserializeJSON(raw)
    if decoded == nil then
      return nil, ("Could not parse JSON from %s"):format(url)
    end

    if cachePath then
      util.writeAll(cachePath, raw)
    end

    return decoded, "remote"
  end

  if cachePath and fs.exists(cachePath) then
    local cached = util.readAll(cachePath)
    if cached then
      local decoded = textutils.unserializeJSON(cached)
      if decoded ~= nil then
        return decoded, "cache", err
      end
    end
  end

  return nil, nil, err or ("HTTP request failed for %s"):format(url)
end

function util.isNonEmptyString(value)
  return type(value) == "string" and value ~= ""
end

function util.isPositiveNumber(value)
  return type(value) == "number" and value > 0
end

function util.copyTable(source)
  local copy = {}
  for key, value in pairs(source or {}) do
    copy[key] = value
  end
  return copy
end

function util.mergeTables(base, overrides)
  local merged = util.copyTable(base or {})
  for key, value in pairs(overrides or {}) do
    merged[key] = value
  end
  return merged
end

function util.basename(path)
  return fs.getName(path)
end

function util.sanitizeId(value)
  return tostring(value):gsub("[^%w%-_]+", "_")
end

function util.trackElapsedMilliseconds(snapshot)
  if not snapshot or not snapshot.started_at_ms then
    return 0
  end

  local elapsed = util.nowMilliseconds() - snapshot.started_at_ms
  if elapsed < 0 then
    return 0
  end

  return elapsed
end

function util.formatAge(timestampMs)
  local delta = util.nowMilliseconds() - timestampMs
  if delta < 0 then
    delta = 0
  end
  return ("%ss ago"):format(math.floor(delta / 1000))
end

return util
