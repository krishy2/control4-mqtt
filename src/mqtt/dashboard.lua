--- Dashboard field model for the MQTT Web View driver.
---
--- Pure functions (no C4 calls) that turn raw MQTT payloads into an ordered list
--- of display fields: flattening JSON, applying labels/units, hiding/ordering,
--- formatting numbers and grading air-quality style readings.

local M = {}

--- Maximum number of fields kept from a single payload (protects the UI and the controller).
M.MAX_FIELDS = 100

--- Maximum JSON nesting depth that is flattened.
M.MAX_DEPTH = 6

--- Severity ordering for levels. Higher is worse.
M.LEVEL_RANK = { good = 1, fair = 2, poor = 3, bad = 4 }

--- Human readable names for levels (used for the navigator icon description).
M.LEVEL_TEXT = { good = "Good", fair = "Fair", poor = "Poor", bad = "Bad" }

--- Grade a value against ascending thresholds: <= good, <= fair, <= poor, else bad.
local function ascending(good, fair, poor)
  return function(v)
    if v <= good then
      return "good"
    elseif v <= fair then
      return "fair"
    elseif v <= poor then
      return "poor"
    end
    return "bad"
  end
end

--- Known measurement types, keyed by normalised key (lowercase, alphanumerics only).
--- Matching uses the last segment of a flattened key, so "sensors.pm25" matches "pm25".
--- Thresholds follow common indoor air-quality guidance (WHO / EPA / Sensirion VOC index).
--- Each entry: label, unit, decimals, rank (sort order) and an optional grade(v) function.
--- @type table<string, table>
M.KNOWN = {
  temperature = { label = "Temperature", unit = "°C", decimals = 1, rank = 10 },
  localtemperature = { label = "Temperature", unit = "°C", decimals = 1, rank = 10 },
  humidity = {
    label = "Humidity",
    unit = "%",
    decimals = 0,
    rank = 11,
    grade = function(v)
      if v >= 30 and v <= 60 then
        return "good"
      elseif v >= 20 and v <= 70 then
        return "fair"
      end
      return "poor"
    end,
  },
  pm25 = { label = "PM2.5", unit = "µg/m³", decimals = 0, rank = 1, grade = ascending(12, 35, 55) },
  pm10 = { label = "PM10", unit = "µg/m³", decimals = 0, rank = 2, grade = ascending(54, 154, 254) },
  pm1 = { label = "PM1", unit = "µg/m³", decimals = 0, rank = 3 },
  vocindex = { label = "VOC Index", unit = "", decimals = 0, rank = 4, grade = ascending(150, 250, 400) },
  voc = { label = "VOC", unit = "", decimals = 0, rank = 4 },
  tvoc = { label = "tVOC", unit = "ppb", decimals = 0, rank = 4, grade = ascending(220, 660, 2200) },
  noxindex = { label = "NOx Index", unit = "", decimals = 0, rank = 5, grade = ascending(20, 150, 300) },
  co2 = { label = "CO₂", unit = "ppm", decimals = 0, rank = 0, grade = ascending(800, 1200, 2000) },
  formaldehyd = { label = "Formaldehyde", unit = "mg/m³", decimals = 3, rank = 6 },
  formaldehyde = { label = "Formaldehyde", unit = "mg/m³", decimals = 3, rank = 6 },
  hcho = { label = "Formaldehyde", unit = "mg/m³", decimals = 3, rank = 6 },
  aqi = { label = "AQI", unit = "", decimals = 0, rank = 0, grade = ascending(50, 100, 150) },
  airquality = { label = "Air Quality", unit = "", decimals = 0, rank = 0 },
  pressure = { label = "Pressure", unit = "hPa", decimals = 0, rank = 12 },
  illuminance = { label = "Illuminance", unit = "lx", decimals = 0, rank = 13 },
  illuminancelux = { label = "Illuminance", unit = "lx", decimals = 0, rank = 13 },
  noise = { label = "Noise", unit = "dB", decimals = 0, rank = 14 },
  battery = {
    label = "Battery",
    unit = "%",
    decimals = 0,
    rank = 50,
    grade = function(v)
      if v > 50 then
        return "good"
      elseif v > 20 then
        return "fair"
      end
      return "poor"
    end,
  },
  voltage = { label = "Voltage", unit = "V", decimals = 1, rank = 40 },
  current = { label = "Current", unit = "A", decimals = 2, rank = 41 },
  power = { label = "Power", unit = "W", decimals = 0, rank = 42 },
  energy = { label = "Energy", unit = "kWh", decimals = 2, rank = 43 },
  linkquality = { label = "Link Quality", unit = "LQI", decimals = 0, rank = 60 },
  rssi = { label = "Signal", unit = "dBm", decimals = 0, rank = 60 },
}

--- Normalise a key for matching ("voc_index" -> "vocindex", "PM2.5" -> "pm25").
--- @param key string
--- @return string
function M.normalise(key)
  return (string.gsub(string.lower(tostring(key or "")), "[^%w]", ""))
end

--- Last segment of a flattened key ("a.b[2].c" -> "c", "a.b[2]" -> "b").
--- @param key string
--- @return string
function M.lastSegment(key)
  local k = string.gsub(key, "%[%d+%]$", "")
  return string.match(k, "([^%.]+)$") or k
end

--- Look up the known definition for a flattened key.
--- @param key string
--- @return table|nil
function M.known(key)
  return M.KNOWN[M.normalise(M.lastSegment(key))]
end

--- Trim whitespace.
local function trim(s)
  return (string.gsub(s or "", "^%s*(.-)%s*$", "%1"))
end

--- Turn "voc_index" / "vocIndex" into "Voc Index".
--- @param key string
--- @return string
function M.prettify(key)
  local s = M.lastSegment(key)
  s = string.gsub(s, "(%l)(%u)", "%1 %2")
  s = string.gsub(s, "[_%-]+", " ")
  s = string.gsub(s, "(%a)([%w]*)", function(first, rest)
    return string.upper(first) .. rest
  end)
  return trim(s)
end

--- Split a comma (or newline) separated list into trimmed, non-empty entries.
--- @param str string|nil
--- @return string[]
function M.parseList(str)
  local out = {}
  for part in string.gmatch(str or "", "[^,\n]+") do
    local p = trim(part)
    if p ~= "" then
      table.insert(out, p)
    end
  end
  return out
end

--- Convert a simple glob ("update*", "*.installed") into an anchored Lua pattern.
local function globToPattern(glob)
  local p = string.gsub(string.lower(glob), "[%^%$%(%)%%%.%[%]%+%-%?]", "%%%0")
  p = string.gsub(p, "%*", ".*")
  return "^" .. p .. "$"
end

--- Build a matcher for a list of key globs (case-insensitive).
--- @param list string[]
--- @return fun(key: string): boolean
function M.matcher(list)
  local patterns = {}
  for _, g in ipairs(list) do
    table.insert(patterns, globToPattern(g))
  end
  return function(key)
    local k = string.lower(key)
    for _, p in ipairs(patterns) do
      if string.match(k, p) then
        return true
      end
    end
    return false
  end
end

--- Parse label overrides: "pm25=PM2.5|µg/m³; voc_index=Air Quality|" (separated by ';' or newlines).
--- A missing "|unit" keeps the default unit; an empty unit after '|' removes it.
--- @param str string|nil
--- @return table<string, {label: string|nil, unit: string|nil}> keyed by lowercase key
function M.parseOverrides(str)
  local out = {}
  for entry in string.gmatch(str or "", "[^;\n]+") do
    local key, rest = string.match(entry, "^%s*([^=]-)%s*=(.*)$")
    if key and key ~= "" then
      local label, unit = string.match(rest, "^(.-)|(.*)$")
      if label == nil then
        label = rest
      end
      label = trim(label)
      out[string.lower(key)] = {
        label = label ~= "" and label or nil,
        unit = unit ~= nil and trim(unit) or nil,
      }
    end
  end
  return out
end

--- Flatten a decoded JSON value into a key -> scalar map.
--- Objects become dotted keys, arrays get [n] suffixes (1-based).
--- @param value any Decoded JSON value.
--- @param prefix string|nil Key prefix.
--- @param out table|nil Accumulator.
--- @param depth integer|nil Current depth.
--- @return table<string, string|number|boolean>
function M.flatten(value, prefix, out, depth)
  out = out or {}
  depth = depth or 0
  if type(value) ~= "table" then
    if prefix and value ~= nil then
      out[prefix] = value
    end
    return out
  end
  if depth >= M.MAX_DEPTH then
    return out
  end
  -- Sort keys so truncation at MAX_FIELDS is deterministic
  local keys = {}
  for k in pairs(value) do
    table.insert(keys, k)
  end
  table.sort(keys, function(a, b)
    return tostring(a) < tostring(b)
  end)
  local isArray = #value > 0
  for _, k in ipairs(keys) do
    local childKey
    if isArray and type(k) == "number" then
      childKey = (prefix or "") .. "[" .. k .. "]"
    else
      childKey = prefix and (prefix .. "." .. tostring(k)) or tostring(k)
    end
    M.flatten(value[k], childKey, out, depth + 1)
  end
  return out
end

--- Decode an MQTT payload into a flat key -> value map.
--- JSON objects/arrays are flattened. Anything else becomes a single value named after
--- the topic's last segment.
--- @param topic string
--- @param payload string
--- @param decode fun(s: string): any JSON decoder
--- @return table<string, string|number|boolean>
function M.decodePayload(topic, payload, decode)
  payload = payload or ""
  local trimmed = trim(payload)
  local first = string.sub(trimmed, 1, 1)
  if first == "{" or first == "[" then
    local ok, decoded = pcall(decode, trimmed)
    if ok and type(decoded) == "table" then
      return M.flatten(decoded)
    end
  end
  local name = string.match(topic or "", "([^/]+)/*$") or "value"
  local num = tonumber(trimmed)
  local out = {}
  out[name] = num ~= nil and num or trimmed
  return out
end

--- Round to a number of decimals and render without trailing zeros noise.
--- @param n number
--- @param decimals integer
--- @return string
function M.formatNumber(n, decimals)
  if n ~= n or n == math.huge or n == -math.huge then
    return "--"
  end
  decimals = decimals or 2
  local s = string.format("%." .. decimals .. "f", n)
  if decimals > 0 then
    s = string.gsub(s, "0+$", "")
    s = string.gsub(s, "%.$", "")
  end
  if s == "-0" then
    s = "0"
  end
  return s
end

--- Grade a numeric value for a known type.
--- @param def table|nil
--- @param n number|nil
--- @return string|nil
function M.grade(def, n)
  if def and def.grade and type(n) == "number" then
    return def.grade(n)
  end
  return nil
end

--- Return the worst level in a field list.
--- @param fields table[]
--- @return string|nil
function M.worstLevel(fields)
  local worst, rank = nil, 0
  for _, f in ipairs(fields) do
    local r = f.level and M.LEVEL_RANK[f.level] or 0
    if r > rank then
      worst, rank = f.level, r
    end
  end
  return worst
end

--- Shown for a Field Order entry that has not received a value yet.
M.NO_VALUE = "--"

--- Find the stored value for a Field Order entry: exact key first, then a key whose
--- last segment matches ("pm25" finds "sensors.pm25"), case-insensitive.
--- @param values table<string, any>
--- @param name string
--- @return string|nil key, any entry
function M.lookup(values, name)
  if values[name] ~= nil then
    return name, values[name]
  end
  local lname = string.lower(name)
  local found
  for key in pairs(values) do
    if string.lower(key) == lname then
      return key, values[key]
    end
    if found == nil and string.lower(M.lastSegment(key)) == lname then
      found = key
    end
  end
  if found then
    return found, values[found]
  end
  return nil, nil
end

--- One display field for a key and its stored entry (nil entry -> placeholder).
--- @param key string
--- @param entry table|any|nil
--- @param config table
--- @return table
local function makeField(key, entry, config)
  local overrides = config.overrides or {}
  local raw = type(entry) == "table" and entry.value or entry
  local def = M.known(key)
  local ov = overrides[string.lower(key)] or overrides[string.lower(M.lastSegment(key))] or {}
  local unit = def and def.unit or ""
  local decimals = def and def.decimals or 2
  local num = type(raw) == "number" and raw or nil
  local display

  -- Temperature conversion applies to anything recognised as a temperature
  if def and def.unit == "°C" then
    if config.tempConversion == "Celsius to Fahrenheit" then
      num = num and (num * 9 / 5 + 32)
      unit = "°F"
    elseif num and config.tempConversion == "Fahrenheit to Celsius" then
      num = (num - 32) * 5 / 9
    elseif config.tempConversion == "Source is Fahrenheit" then
      unit = "°F"
    end
  end

  if raw == nil then
    display = M.NO_VALUE
  elseif num then
    display = M.formatNumber(num, decimals)
  elseif type(raw) == "boolean" then
    display = raw and "Yes" or "No"
  else
    display = tostring(raw)
  end

  if ov.unit ~= nil then
    unit = ov.unit
  end

  return {
    key = key,
    label = ov.label or (def and def.label) or M.prettify(key),
    value = num ~= nil and num or raw,
    display = display,
    unit = unit,
    level = M.grade(def, num),
    numeric = num ~= nil,
    missing = raw == nil or nil,
    ts = type(entry) == "table" and entry.ts or nil,
    _rank = def and def.rank or 30,
  }
end

--- Sort fields in the default order: graded air readings first, then by rank and key.
--- @param list table[]
function M.sortDefault(list)
  table.sort(list, function(a, b)
    if a._rank ~= b._rank then
      return a._rank < b._rank
    end
    return a.key < b.key
  end)
end

--- Build the ordered display field list.
---
--- With a Field Order, exactly those fields are shown, in that order, whether or not a
--- value has arrived yet (devices often send one field per message): a field without a
--- value shows NO_VALUE. Field Order entries are shown even if Hidden Fields matches them.
--- Without a Field Order, every received field not matched by Hidden Fields is shown.
--- @param values table<string, {value: any, ts: number|nil}> Current values keyed by flattened key.
--- @param config table { hidden: string[], order: string[], overrides: table, tempConversion: string }
--- @return table[] fields
function M.build(values, config)
  config = config or {}
  values = values or {}
  local fields = {}

  if config.order and #config.order > 0 then
    local seen = {}
    for _, name in ipairs(config.order) do
      local key, entry = M.lookup(values, name)
      key = key or name
      if not seen[string.lower(key)] then
        seen[string.lower(key)] = true
        table.insert(fields, makeField(key, entry, config))
      end
    end
  else
    local isHidden = M.matcher(config.hidden or {})
    for key, entry in pairs(values) do
      local raw = type(entry) == "table" and entry.value or entry
      if raw ~= nil and not isHidden(key) then
        table.insert(fields, makeField(key, entry, config))
      end
    end
    M.sortDefault(fields)
  end

  -- Strip sort helpers and cap the list
  local out = {}
  for i, f in ipairs(fields) do
    if i > M.MAX_FIELDS then
      break
    end
    f._rank = nil
    table.insert(out, f)
  end
  return out
end

--- Keys for the Received Fields list and "Copy All to Field Order": every key ever
--- received, in the default display order.
--- @param received table<string, any> Set of received keys.
--- @param hidden string[]|nil Keys left out (Hidden Fields), or nil to keep all.
--- @return string[]
function M.catalog(received, hidden)
  local isHidden = M.matcher(hidden or {})
  local list = {}
  for key in pairs(received or {}) do
    if not isHidden(key) then
      local def = M.known(key)
      table.insert(list, { key = key, _rank = def and def.rank or 30 })
    end
  end
  M.sortDefault(list)
  local out = {}
  for _, f in ipairs(list) do
    table.insert(out, f.key)
  end
  return out
end

--- Short "key=value unit, ..." summary for a read-only Composer property.
--- @param fields table[]
--- @return string
function M.summary(fields)
  local parts = {}
  for _, f in ipairs(fields) do
    local s = f.label .. ": " .. f.display
    if f.unit and f.unit ~= "" then
      s = s .. " " .. f.unit
    end
    table.insert(parts, s)
  end
  return table.concat(parts, ", ")
end

return M
