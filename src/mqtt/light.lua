--- @module "mqtt.light"
--- MQTT light model for the MQTT Light (light_v2) driver.
---
--- Owns the light's configuration, its capabilities (derived from which topics
--- or JSON keys are filled in), the last state reported by the device, and the
--- translation between Control4 light_v2 proxy commands and MQTT payloads.
---
--- Capability rule: a capability exists when its topic (Separate Topics mode)
--- or its key (JSON mode) is filled in.
---   On/Off      always
---   Dimmer      brightness, or a color format that carries brightness
---   Color Temp  color temperature, or a white channel (fixed CCT)
---   Color       color (RGB / Hex / HSB / HS / XY)
---   Transition  transition topic/key (fades run on the device)
---
--- The driver layer feeds it proxy commands (handleProxyCommand) and MQTT
--- messages (onMessage); it sends PUBLISH requests to the broker binding and
--- light_v2 notifies to the proxy binding.

local log = require("lib.logging")
local stateParser = require("mqtt.state_parser")
local Color = require("mqtt.color")

local MqttLight = {}
MqttLight.__index = MqttLight

MqttLight.MODE_TOPICS = "Separate Topics"
MqttLight.MODE_JSON = "JSON"
MqttLight.MODE_SHELLY = "Shelly (Gen2+)"

--- Shelly component types and their RPC method prefixes.
local SHELLY_METHODS = { light = "Light", cct = "CCT", rgb = "RGB", rgbw = "RGBW", switch = "Switch" }
--- Shortest fade a Shelly is sent, in seconds.
local SHELLY_MIN_TRANSITION = 0.5

MqttLight.COLOR_FORMATS = {
  RGB = "RGB (r,g,b)",
  HEX = "Hex (RRGGBB)",
  HEX_HASH = "Hex (#RRGGBB)",
  HSB = "HSB (h,s,b)",
  HS = "HS (h,s)",
  XY = "XY (x,y)",
}

MqttLight.JSON_COLOR_FORMATS = {
  XY = "XY {x,y}",
  RGB = "RGB {r,g,b}",
  HS = "HS {hue,saturation}",
}

MqttLight.TRANSITION_UNITS = {
  SECONDS = "Seconds",
  TENTHS = "Tenths of a Second",
  MS = "Milliseconds",
  TASMOTA = "Tasmota Speed",
}

MqttLight.COLOR_MODE_FULL = 0
MqttLight.COLOR_MODE_CCT = 1

-- Delay before a pressed keypad button starts a hold ramp.
local HOLD_DELAY_MS = 400
-- Window in which consecutive brightness and color commands are combined.
local DEBOUNCE_MS = 50
-- Emulated ramps never step faster than this.
local MIN_STEP_MS = 250
-- Emulated ramps use at most this many steps.
local MAX_STEPS = 40
-- xy distance below which two colors are considered the same.
local XY_TOLERANCE = 0.002

local DEFAULT_SETTINGS = {
  onLevel = 100,
  clickRateUp = 0,
  clickRateDown = 0,
  holdRateUp = 3000,
  holdRateDown = 3000,
  brightnessRateDefault = 0,
  colorRateDefault = 0,
}

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

local function trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function notEmpty(s)
  return s ~= nil and trim(s) ~= ""
end

local function round(v)
  return Color.round(v)
end

local function nowMs()
  if C4 and C4.GetTime then
    return C4:GetTime()
  end
  return os.time() * 1000
end

--- Split "a,b,c" into numbers.
local function numberList(s)
  local out = {}
  for part in tostring(s):gmatch("[^,;%s]+") do
    local n = tonumber(part)
    if n == nil then
      return nil
    end
    table.insert(out, n)
  end
  return out
end

local function decodeJson(payload)
  if type(payload) == "table" then
    return payload
  end
  local ok, t = pcall(JSON.decode, JSON, payload)
  if ok and type(t) == "table" then
    return t
  end
  return nil
end

--- Pull a value from a JSON table by a plain key or a JSONPath ("$.a.b").
local function lookup(t, key)
  if type(t) ~= "table" or not notEmpty(key) then
    return nil
  end
  key = trim(key)
  if key:sub(1, 1) == "$" then
    return stateParser.extractJsonPath(t, key)
  end
  return t[key]
end

--- Extract the value of interest from a raw payload with an optional JSONPath.
--- @return any|nil value nil when the path is missing or the payload is not JSON
local function extract(payload, valuePath)
  if not notEmpty(valuePath) then
    return payload
  end
  local t = decodeJson(payload)
  if t == nil then
    return nil
  end
  return stateParser.extractJsonPath(t, trim(valuePath))
end

local function sameXy(a, b)
  if a == nil or b == nil then
    return a == b
  end
  return math.abs(a.x - b.x) < XY_TOLERANCE and math.abs(a.y - b.y) < XY_TOLERANCE and a.mode == b.mode
end

local function boolStr(b)
  return b and "true" or "false"
end

-------------------------------------------------------------------------------
-- Construction and configuration
-------------------------------------------------------------------------------

--- Create a light.
--- @param opts table { proxyBinding, brokerBinding, now?, onStateChanged?, onSettingsChanged? }
--- @return table
function MqttLight.new(opts)
  local self = setmetatable({}, MqttLight)
  self.proxyBinding = opts.proxyBinding
  self.brokerBinding = opts.brokerBinding
  self.now = opts.now or nowMs
  self.onStateChanged = opts.onStateChanged
  self.onSettingsChanged = opts.onSettingsChanged
  self.timerPrefix = opts.timerPrefix or "MqttLight"
  self.cfg = {}
  self.caps = {}
  self.settings = {}
  for k, v in pairs(DEFAULT_SETTINGS) do
    self.settings[k] = v
  end
  self:resetState()
  return self
end

--- Forget everything the device has reported.
function MqttLight:resetState()
  -- What the device reported (or what we assume when optimistic)
  self.device = {
    power = nil, -- boolean
    brightness = nil, -- 0-100
    colorBrightness = nil, -- 0-100, from a color format that carries brightness
    kelvin = nil,
    white = nil, -- 0-100
    color = nil, -- { x, y }
    mode = nil, -- COLOR_MODE_*
  }
  -- Shelly: the component status so far (NotifyStatus sends only what changed)
  self.shellyStatus = {}
  -- What was last reported to the proxy
  self.level = nil
  self.color = nil -- { x, y, mode }
  self.offColor = nil -- color requested while off, applied at next turn on
  self.colorOverride = false -- explicit color while on: stop default-on/warm-dim
  self.ramp = nil
  self.press = nil
  self.pending = nil
  self.lastMode = nil
end

--- Apply a new configuration and recompute capabilities.
--- @param cfg table see the driver's buildConfig()
--- @return boolean changed Whether the capabilities changed
function MqttLight:configure(cfg)
  self.cfg = cfg or {}
  local old = self.caps
  self.caps = self:computeCapabilities()
  for k, v in pairs(self.caps) do
    if old[k] ~= v then
      return true
    end
  end
  for k, v in pairs(old) do
    if self.caps[k] ~= v then
      return true
    end
  end
  return false
end

--- Load persisted proxy settings (rates, presets).
--- @param settings table|nil
function MqttLight:loadSettings(settings)
  for k, v in pairs(settings or {}) do
    self.settings[k] = v
  end
end

function MqttLight:_saveSettings()
  if self.onSettingsChanged then
    self.onSettingsChanged(self.settings)
  end
end

function MqttLight:isJsonMode()
  return self.cfg.mode == MqttLight.MODE_JSON
end

function MqttLight:isShellyMode()
  return self.cfg.mode == MqttLight.MODE_SHELLY
end

--- Shelly settings: { prefix, key, kind, index, src } or nil when incomplete.
function MqttLight:_shelly()
  local sh = self.cfg.shelly or {}
  local prefix = trim(sh.prefix)
  local key = trim(sh.component)
  local kind, index = key:match("^(%a+):(%d+)$")
  if prefix == "" or kind == nil or SHELLY_METHODS[kind] == nil then
    return nil
  end
  return {
    prefix = prefix,
    key = key,
    kind = kind,
    index = tonumber(index),
    src = "control4/" .. prefix .. "/" .. key:gsub(":", "_"),
  }
end

--- Does a feature have a topic (topics mode) or key (JSON mode)?
--- @param feature string power|brightness|colorTemp|color|white|transition
--- @return boolean has
--- @return boolean canCommand
function MqttLight:_has(feature)
  local cfg = self.cfg
  if self:isJsonMode() then
    local json = cfg.json or {}
    local hasTopic = notEmpty(json.stateTopic) or notEmpty(json.commandTopic)
    local key = (json.keys or {})[feature]
    local has = hasTopic and notEmpty(key)
    return has, has and notEmpty(json.commandTopic)
  end
  local t = (cfg.topics or {})[feature] or {}
  if feature == "transition" then
    return notEmpty(t.commandTopic), notEmpty(t.commandTopic)
  end
  return notEmpty(t.stateTopic) or notEmpty(t.commandTopic), notEmpty(t.commandTopic)
end

--- Whether the configured color format carries brightness.
function MqttLight:_colorCarriesBrightness()
  if self:isJsonMode() then
    return false
  end
  local fmt = self.cfg.colorFormat
  if fmt == MqttLight.COLOR_FORMATS.HSB then
    return true
  end
  if
    fmt == MqttLight.COLOR_FORMATS.RGB
    or fmt == MqttLight.COLOR_FORMATS.HEX
    or fmt == MqttLight.COLOR_FORMATS.HEX_HASH
  then
    return self.cfg.colorIncludesBrightness ~= false
  end
  return false
end

--- Compute capabilities from the configuration.
--- @return table
function MqttLight:computeCapabilities()
  if self:isShellyMode() then
    return self:_shellyCapabilities()
  end
  local caps = {}
  caps.power = true
  caps.brightness = self:_has("brightness")
  caps.colorTemp = self:_has("colorTemp")
  caps.color = self:_has("color")
  caps.white = self:_has("white")
  caps.transition = self:_has("transition")
  caps.colorBrightness = caps.color and self:_colorCarriesBrightness()
  caps.dimmer = caps.brightness or caps.colorBrightness or (caps.white and not caps.color and not caps.colorTemp)
  caps.cct = caps.colorTemp or caps.white

  local minK = tonumber(self.cfg.colorTempMin) or 2000
  local maxK = tonumber(self.cfg.colorTempMax) or 6500
  if caps.colorTemp then
    caps.cctMin, caps.cctMax = math.min(minK, maxK), math.max(minK, maxK)
  elseif caps.white then
    local k = tonumber(self.cfg.whiteColorTemp) or 4000
    caps.cctMin, caps.cctMax = k, k
  end
  if caps.cctMin then
    -- light_v2 requires increments of 10 within 500-20000
    caps.cctMin = Color.clamp(round(caps.cctMin / 10) * 10, 500, 20000)
    caps.cctMax = Color.clamp(round(caps.cctMax / 10) * 10, 500, 20000)
  end
  return caps
end

--- Capabilities of a Shelly component, from its type.
function MqttLight:_shellyCapabilities()
  local sh = self:_shelly()
  local kind = sh and sh.kind or "switch"
  local caps = { power = true }
  caps.brightness = kind ~= "switch"
  caps.colorTemp = kind == "cct"
  caps.color = kind == "rgb" or kind == "rgbw"
  caps.white = kind == "rgbw"
  caps.transition = kind ~= "switch"
  caps.colorBrightness = false
  caps.dimmer = caps.brightness
  caps.cct = caps.colorTemp or caps.white
  if caps.colorTemp then
    local minK = tonumber(self.cfg.colorTempMin) or 2700
    local maxK = tonumber(self.cfg.colorTempMax) or 6500
    caps.cctMin, caps.cctMax = math.min(minK, maxK), math.max(minK, maxK)
  elseif caps.white then
    local k = tonumber(self.cfg.whiteColorTemp) or 4000
    caps.cctMin, caps.cctMax = k, k
  end
  if caps.cctMin then
    caps.cctMin = Color.clamp(round(caps.cctMin / 10) * 10, 500, 20000)
    caps.cctMax = Color.clamp(round(caps.cctMax / 10) * 10, 500, 20000)
  end
  return caps
end

--- Human readable capability list.
--- @return string
function MqttLight:describeCapabilities()
  local c = self.caps
  local parts = { "On/Off" }
  if c.dimmer then
    table.insert(parts, "Dimmer")
  end
  if c.colorTemp then
    table.insert(parts, string.format("Color Temp (%d-%dK)", c.cctMin, c.cctMax))
  end
  if c.color then
    table.insert(parts, "Color")
  end
  if c.white then
    table.insert(parts, "White Channel")
  end
  if c.transition then
    table.insert(parts, "Transition")
  end
  return table.concat(parts, ", ")
end

--- Fade time range in ms. Composer reads these as 16-bit numbers, so the
--- maximum must stay at 32767 (32.7 s); driver.xml declares the same.
MqttLight.RATE_MIN = 0
MqttLight.RATE_MAX = 32767

--- light_v2 DYNAMIC_CAPABILITIES_CHANGED parameters for the current config.
--- Color and CCT are always sent together, as the proxy docs require.
--- @return table
function MqttLight:dynamicCapabilities()
  local c = self.caps
  local params = {
    dimmer = boolStr(c.dimmer),
    set_level = boolStr(c.dimmer),
    supports_target = "true",
    supports_brightness_stop = boolStr(c.dimmer),
    supports_color = boolStr(c.color),
    supports_color_correlated_temperature = boolStr(c.cct),
    color_rate_behavior = c.transition and "1" or "0",
    -- Always sent: Composer reads missing ranges as 0-0 and then refuses the
    -- proxy's default fade time (0.75 s), even on a light without color.
    brightness_rate_min = tostring(MqttLight.RATE_MIN),
    brightness_rate_max = tostring(MqttLight.RATE_MAX),
    color_rate_min = tostring(MqttLight.RATE_MIN),
    color_rate_max = tostring(MqttLight.RATE_MAX),
  }
  if c.cct then
    params.color_correlated_temperature_min = tostring(c.cctMin)
    params.color_correlated_temperature_max = tostring(c.cctMax)
  end
  return params
end

--- Topics this light must subscribe to.
--- @return string[]
function MqttLight:subscriptions()
  local set, list = {}, {}
  local function add(topic)
    if notEmpty(topic) and not set[trim(topic)] then
      set[trim(topic)] = true
      table.insert(list, trim(topic))
    end
  end
  if self:isShellyMode() then
    local sh = self:_shelly()
    if sh then
      add(sh.prefix .. "/status/" .. sh.key)
      add(sh.prefix .. "/events/rpc")
      add(sh.src .. "/rpc")
    end
  elseif self:isJsonMode() then
    add((self.cfg.json or {}).stateTopic)
  else
    for _, feature in ipairs({ "power", "brightness", "colorTemp", "color", "white" }) do
      add(((self.cfg.topics or {})[feature] or {}).stateTopic)
    end
  end
  table.sort(list)
  return list
end

--- Whether any state feedback is configured.
function MqttLight:hasStateFeedback()
  return #self:subscriptions() > 0
end

--- Whether commands update the reported state immediately.
function MqttLight:isOptimistic()
  local o = self.cfg.optimistic
  if o == "Yes" then
    return true
  elseif o == "No" then
    return false
  end
  return not self:hasStateFeedback()
end

-------------------------------------------------------------------------------
-- Proxy / broker I/O
-------------------------------------------------------------------------------

function MqttLight:_notify(command, params)
  log:trace("light notify %s %s", command, params)
  SendToProxy(self.proxyBinding, command, params or {}, "NOTIFY")
end

function MqttLight:_publish(topic, payload)
  topic = trim(topic)
  if topic == "" then
    return
  end
  log:debug("Publishing %s -> %s", topic, payload)
  SendToProxy(self.brokerBinding, "PUBLISH", {
    topic = topic,
    payload = tostring(payload),
    qos = self.cfg.qos or "0",
    retain = self.cfg.retain and "true" or "false",
  })
end

function MqttLight:_timer(name)
  return self.timerPrefix .. "_" .. name
end

--- Notify the proxy of the current brightness if it changed (or forced).
function MqttLight:_reportLevel(level, force)
  if level == nil then
    return
  end
  level = Color.clamp(round(level), 0, 100)
  if not force and self.level == level then
    return
  end
  self.level = level
  self:_notify("LIGHT_BRIGHTNESS_CHANGED", { LIGHT_BRIGHTNESS_CURRENT = level })
  self:_stateChanged()
end

--- Notify the proxy of the current color if it changed (or forced).
function MqttLight:_reportColor(color, force)
  if color == nil or not (self.caps.color or self.caps.cct) then
    return
  end
  if not force and sameXy(self.color, color) then
    return
  end
  self.color = { x = color.x, y = color.y, mode = color.mode }
  self:_notify("LIGHT_COLOR_CHANGED", {
    LIGHT_COLOR_CURRENT_X = Color.roundTo(color.x, 4),
    LIGHT_COLOR_CURRENT_Y = Color.roundTo(color.y, 4),
    LIGHT_COLOR_CURRENT_COLOR_MODE = color.mode,
  })
  self:_stateChanged()
end

function MqttLight:_stateChanged()
  if self.onStateChanged then
    self.onStateChanged(self)
  end
end

--- Resend everything the proxy needs after startup or reconnection.
function MqttLight:refreshProxy()
  self:_notify("DYNAMIC_CAPABILITIES_CHANGED", self:dynamicCapabilities())
  self:_notify("CLICK_RATE_UP", { RATE = self.settings.clickRateUp })
  self:_notify("CLICK_RATE_DOWN", { RATE = self.settings.clickRateDown })
  self:_notify("HOLD_RATE_UP", { RATE = self.settings.holdRateUp })
  self:_notify("HOLD_RATE_DOWN", { RATE = self.settings.holdRateDown })
  if self.level ~= nil then
    self:_reportLevel(self.level, true)
  end
  if self.color ~= nil then
    self:_reportColor(self.color, true)
  end
end

-------------------------------------------------------------------------------
-- Device state -> Control4
-------------------------------------------------------------------------------

--- Brightness (0-100) the device is at, from everything it reported.
--- @return number|nil
function MqttLight:deviceLevel()
  local d = self.device
  local bri = d.brightness
  if bri == nil and self.caps.colorBrightness and d.mode ~= MqttLight.COLOR_MODE_CCT then
    bri = d.colorBrightness
  end
  if bri == nil and self.caps.white and not self.caps.brightness and d.mode == MqttLight.COLOR_MODE_CCT then
    bri = d.white
  end
  local on = d.power
  if on == nil and bri ~= nil then
    on = bri > 0
  end
  if on == nil then
    return nil
  end
  if not on then
    return 0
  end
  if not self.caps.dimmer then
    return 100
  end
  if bri == nil then
    return self.level ~= nil and self.level > 0 and self.level or 100
  end
  return math.max(1, Color.clamp(bri, 0, 100))
end

--- Color the device is showing, from everything it reported.
--- @return table|nil { x, y, mode }
function MqttLight:deviceColor()
  local d = self.device
  if d.mode == MqttLight.COLOR_MODE_CCT then
    local k = d.kelvin
    if k == nil and self.caps.white and not self.caps.colorTemp then
      k = self.caps.cctMin
    end
    if k ~= nil then
      local x, y = Color.cctToXy(k)
      return { x = x, y = y, mode = MqttLight.COLOR_MODE_CCT }
    end
  end
  if d.color ~= nil then
    return { x = d.color.x, y = d.color.y, mode = MqttLight.COLOR_MODE_FULL }
  end
  if d.kelvin ~= nil then
    local x, y = Color.cctToXy(d.kelvin)
    return { x = x, y = y, mode = MqttLight.COLOR_MODE_CCT }
  end
  return nil
end

--- Report the device's state to the proxy (unless a ramp is in progress).
function MqttLight:_syncFromDevice(force)
  if self.ramp ~= nil then
    return
  end
  self:_reportLevel(self:deviceLevel(), force)
  self:_reportColor(self:deviceColor(), force)
  self:_stateChanged()
end

--- Parse a power value.
function MqttLight:_parsePower(value)
  if type(value) == "boolean" then
    return value
  end
  local on = trim(self.cfg.stateOn)
  local off = trim(self.cfg.stateOff)
  local parsed = stateParser.parse(trim(value), on, off)
  if parsed == nil and on == "" and off == "" then
    local v = trim(value):upper()
    if v == "ON" or v == "TRUE" or v == "1" then
      return true
    elseif v == "OFF" or v == "FALSE" or v == "0" then
      return false
    end
  end
  return parsed
end

--- Parse a brightness value into 0-100.
function MqttLight:_parseBrightness(value)
  local n = tonumber(value)
  if n == nil then
    return nil
  end
  local max = tonumber(self.cfg.brightnessMax) or 100
  if max <= 0 then
    max = 100
  end
  return Color.clamp(n / max * 100, 0, 100)
end

--- Parse a white channel value into 0-100.
function MqttLight:_parseWhite(value)
  local n = tonumber(value)
  if n == nil then
    return nil
  end
  local max = tonumber(self.cfg.whiteMax) or 100
  if max <= 0 then
    max = 100
  end
  return Color.clamp(n / max * 100, 0, 100)
end

--- Parse a color temperature value into Kelvin.
function MqttLight:_parseColorTemp(value)
  local n = tonumber(value)
  if n == nil or n <= 0 then
    return nil
  end
  if self.cfg.colorTempUnit == "Kelvin" then
    return n
  end
  return Color.miredToKelvin(n)
end

--- Parse a color value.
--- @return table|nil { x, y, brightness?, black? }
function MqttLight:_parseColor(value)
  if type(value) == "table" then
    local x, y = tonumber(value.x), tonumber(value.y)
    if x and y then
      return { x = x, y = y }
    end
    local r, g, b = tonumber(value.r), tonumber(value.g), tonumber(value.b)
    if r and g and b then
      local cx, cy = Color.rgbToXy(r, g, b)
      if cx == nil then
        return { black = true, brightness = 0 }
      end
      return { x = cx, y = cy, brightness = Color.rgbBrightness(r, g, b) }
    end
    local h = tonumber(value.hue or value.h)
    local s = tonumber(value.saturation or value.s)
    if h and s then
      local cx, cy = Color.rgbToXy(Color.hsvToRgb(h, s, 100))
      return { x = cx, y = cy }
    end
    return nil
  end

  local s = trim(value)
  if s == "" then
    return nil
  end
  if s:sub(1, 1) == "{" then
    local t = decodeJson(s)
    return t and self:_parseColor(t) or nil
  end

  local fmt = self.cfg.colorFormat
  local F = MqttLight.COLOR_FORMATS
  if fmt == F.HSB or fmt == F.HS then
    local n = numberList(s)
    if not n or #n < 2 then
      return nil
    end
    local cx, cy = Color.rgbToXy(Color.hsvToRgb(n[1], n[2], 100))
    local out = { x = cx, y = cy }
    if fmt == F.HSB and n[3] then
      out.brightness = Color.clamp(n[3], 0, 100)
    end
    return out
  elseif fmt == F.XY then
    local n = numberList(s)
    if not n or #n < 2 then
      return nil
    end
    return { x = n[1], y = n[2] }
  end

  -- RGB or Hex: accept either spelling
  local r, g, b
  local whiteLit = nil
  if s:find(",") then
    local n = numberList(s)
    if not n or #n < 3 then
      return nil
    end
    r, g, b = n[1], n[2], n[3]
  else
    local hex = s:gsub("^#", "")
    if not hex:match("^%x%x%x%x%x%x") then
      return nil
    end
    r = tonumber(hex:sub(1, 2), 16)
    g = tonumber(hex:sub(3, 4), 16)
    b = tonumber(hex:sub(5, 6), 16)
    -- Tasmota RGBW/RGBCCT report extra white channels after RGB ("FF000000").
    local tail = hex:sub(7)
    if tail:match("^%x+$") then
      whiteLit = tail:match("[1-9A-Fa-f]") ~= nil
    end
  end
  local cx, cy = Color.rgbToXy(r, g, b)
  if cx == nil then
    return { black = true, brightness = 0, modeHint = whiteLit and MqttLight.COLOR_MODE_CCT or nil }
  end
  return {
    x = cx,
    y = cy,
    brightness = Color.rgbBrightness(r, g, b),
    modeHint = whiteLit == false and MqttLight.COLOR_MODE_FULL or nil,
  }
end

--- Apply parsed updates to the device model. Decides the active color mode.
--- @param u table { power?, brightness?, kelvin?, white?, color?, colorModeHint? }
function MqttLight:_applyUpdate(u)
  local d = self.device
  local ctChanged = u.kelvin ~= nil and u.kelvin ~= d.kelvin
  local colorChanged = false

  if u.power ~= nil then
    d.power = u.power
  end
  if u.brightness ~= nil then
    d.brightness = u.brightness
  end
  if u.white ~= nil then
    d.white = u.white
  end
  if u.kelvin ~= nil then
    d.kelvin = u.kelvin
  end
  if u.color ~= nil then
    if u.color.black then
      d.colorBrightness = 0
    else
      local prev = d.color
      d.color = { x = u.color.x, y = u.color.y }
      colorChanged = prev == nil
        or math.abs(prev.x - u.color.x) > XY_TOLERANCE
        or math.abs(prev.y - u.color.y) > XY_TOLERANCE
      if u.color.brightness ~= nil then
        d.colorBrightness = u.color.brightness
      end
    end
  end

  -- Which color mode is active?
  local hint = u.colorModeHint
  if hint == nil and u.color ~= nil then
    hint = u.color.modeHint
  end
  if hint ~= nil then
    d.mode = hint
  elseif ctChanged and colorChanged then
    d.mode = self.lastMode or MqttLight.COLOR_MODE_CCT
  elseif ctChanged then
    d.mode = MqttLight.COLOR_MODE_CCT
  elseif colorChanged then
    d.mode = MqttLight.COLOR_MODE_FULL
  elseif u.color and u.color.black and self.caps.white and (d.white or 0) > 0 then
    -- RGB channels off with the white channel lit: white mode
    d.mode = MqttLight.COLOR_MODE_CCT
  elseif u.white ~= nil and u.white > 0 and not self.caps.colorTemp and d.mode == nil then
    d.mode = MqttLight.COLOR_MODE_CCT
  end
  if d.mode == nil then
    if self.caps.color then
      d.mode = d.color and MqttLight.COLOR_MODE_FULL or (d.kelvin and MqttLight.COLOR_MODE_CCT) or nil
    elseif self.caps.cct then
      d.mode = MqttLight.COLOR_MODE_CCT
    end
  end
end

--- Handle an MQTT message for this light.
--- @param topic string
--- @param payload string
--- @return boolean handled Whether the topic belongs to this light
function MqttLight:onMessage(topic, payload)
  topic = trim(topic)
  local u = {}
  local handled = false

  if self:isShellyMode() then
    local status = self:_shellyStatusFrom(topic, payload)
    if status == false then
      return false
    end
    if status ~= nil then
      u = self:_shellyUpdate(status)
    end
    handled = true
  elseif self:isJsonMode() then
    local json = self.cfg.json or {}
    if trim(json.stateTopic) ~= topic then
      return false
    end
    handled = true
    local t = decodeJson(payload)
    if t == nil then
      log:debug("JSON state payload is not JSON: %s", payload)
      return true
    end
    local keys = json.keys or {}
    local v = lookup(t, keys.power)
    if v ~= nil then
      u.power = self:_parsePower(v)
    end
    if self.caps.brightness then
      v = lookup(t, keys.brightness)
      u.brightness = v ~= nil and self:_parseBrightness(v) or nil
    end
    if self.caps.colorTemp then
      v = lookup(t, keys.colorTemp)
      u.kelvin = v ~= nil and self:_parseColorTemp(v) or nil
    end
    if self.caps.white then
      v = lookup(t, keys.white)
      u.white = v ~= nil and self:_parseWhite(v) or nil
    end
    if self.caps.color then
      v = lookup(t, keys.color)
      if v ~= nil then
        u.color = self:_parseColor(v)
      end
    end
    local mode = lookup(t, keys.colorMode or "color_mode")
    if type(mode) == "string" then
      mode = mode:lower()
      if mode == "color_temp" or mode == "ct" or mode == "white" then
        u.colorModeHint = MqttLight.COLOR_MODE_CCT
      elseif mode == "xy" or mode == "hs" or mode == "rgb" or mode == "rgbw" or mode == "rgbww" then
        u.colorModeHint = MqttLight.COLOR_MODE_FULL
      end
    end
  else
    local topics = self.cfg.topics or {}
    local function feature(name, parse)
      local t = topics[name] or {}
      if trim(t.stateTopic) ~= topic or trim(t.stateTopic) == "" then
        return nil
      end
      handled = true
      local value = extract(payload, t.valuePath)
      if value == nil then
        -- Shared topics (e.g. Tasmota stat/<x>/RESULT) often omit a key.
        log:trace("No %s value in payload on %s", name, topic)
        return nil
      end
      return parse(self, value)
    end
    u.power = feature("power", MqttLight._parsePower)
    u.brightness = feature("brightness", MqttLight._parseBrightness)
    u.kelvin = feature("colorTemp", MqttLight._parseColorTemp)
    u.white = feature("white", MqttLight._parseWhite)
    u.color = feature("color", MqttLight._parseColor)
  end

  if not handled then
    return false
  end
  self:_applyUpdate(u)
  self:_syncFromDevice(false)
  return true
end

--- The component status in a Shelly message.
--- @return table|nil|false status; nil: our topic but nothing for us; false: not our topic
function MqttLight:_shellyStatusFrom(topic, payload)
  local sh = self:_shelly()
  if sh == nil then
    return false
  end
  local statusTopic = sh.prefix .. "/status/" .. sh.key
  local eventTopic = sh.prefix .. "/events/rpc"
  local replyTopic = sh.src .. "/rpc"
  if topic ~= statusTopic and topic ~= eventTopic and topic ~= replyTopic then
    return false
  end
  local t = decodeJson(payload)
  if t == nil then
    return nil
  end
  local status
  if topic == statusTopic then
    status = t
  elseif topic == eventTopic then
    if t.method ~= "NotifyStatus" and t.method ~= "NotifyFullStatus" then
      return nil
    end
    status = type(t.params) == "table" and t.params[sh.key] or nil
  else
    if t.error ~= nil then
      log:warn("Shelly %s answered with an error: %s", sh.prefix, t.error)
      return nil
    end
    status = t.result
  end
  if type(status) ~= "table" then
    return nil
  end
  -- NotifyStatus carries only what changed: keep the rest.
  for k, v in pairs(status) do
    self.shellyStatus[k] = v
  end
  return self.shellyStatus
end

--- Turn a Shelly component status into a device update.
function MqttLight:_shellyUpdate(st)
  local u = {}
  local kind = (self:_shelly() or {}).kind
  if type(st.output) == "boolean" then
    u.power = st.output
  end
  local bri = tonumber(st.brightness)
  if kind == "cct" then
    u.kelvin = tonumber(st.ct)
    u.colorModeHint = MqttLight.COLOR_MODE_CCT
  end
  if (kind == "rgb" or kind == "rgbw") and type(st.rgb) == "table" then
    local r, g, b = tonumber(st.rgb[1]) or 0, tonumber(st.rgb[2]) or 0, tonumber(st.rgb[3]) or 0
    local white = tonumber(st.white) or 0
    local x, y = Color.rgbToXy(r, g, b)
    if kind == "rgbw" and x == nil and white > 0 then
      -- Color off, white channel lit: white mode, dimmed with the white level
      u.colorModeHint = MqttLight.COLOR_MODE_CCT
      u.white = Color.clamp(white / 255 * 100, 0, 100)
      bri = u.white
    elseif x ~= nil then
      u.color = { x = x, y = y }
      u.colorModeHint = MqttLight.COLOR_MODE_FULL
    end
  end
  if bri ~= nil and kind ~= "switch" then
    u.brightness = Color.clamp(bri, 0, 100)
  end
  return u
end

--- Send a Shelly <Type>.Set over RPC.
--- @param cmd table { power?, level?, color?, rate? }
function MqttLight:_sendShelly(cmd)
  local sh = self:_shelly()
  if sh == nil then
    log:warn("Shelly Topic Prefix and Shelly Component must be filled in")
    return
  end
  local c = self.caps
  local level = cmd.level
  local turningOff = cmd.power == false or (level ~= nil and level <= 0)
  local turningOn = cmd.power == true or (level ~= nil and level > 0)
  local params = { id = sh.index }
  local color = cmd.color

  if turningOff then
    params.on = false
  else
    if turningOn or color ~= nil then
      params.on = true
    end
    local inWhite = sh.kind == "rgbw"
      and (
        (color and color.mode == MqttLight.COLOR_MODE_CCT)
        or (color == nil and self.device.mode == MqttLight.COLOR_MODE_CCT)
      )
    if inWhite then
      -- Dim with the white level and leave brightness at full, whichever of
      -- the two the device applies to the white channel.
      local lvl = (level ~= nil and level > 0) and level or self.level or 100
      if lvl <= 0 then
        lvl = 100
      end
      params.white = math.max(1, round(lvl * 255 / 100))
      params.brightness = 100
      if color ~= nil then
        params.rgb = { 0, 0, 0 }
      end
    else
      if level ~= nil and level > 0 and c.brightness then
        params.brightness = math.max(1, round(level))
      end
      if color ~= nil then
        if sh.kind == "cct" then
          params.ct = round(Color.clamp(Color.xyToCct(color.x, color.y), c.cctMin or 1000, c.cctMax or 10000))
        elseif c.color then
          local r, g, b = Color.xyToRgb(color.x, color.y)
          params.rgb = { r, g, b }
          if sh.kind == "rgbw" then
            params.white = 0
          end
        end
      end
    end
  end
  if c.transition and cmd.rate ~= nil then
    params.transition_duration = math.max(SHELLY_MIN_TRANSITION, Color.roundTo(cmd.rate / 1000, 2))
  end
  if
    params.on == nil
    and params.brightness == nil
    and params.rgb == nil
    and params.ct == nil
    and params.white == nil
  then
    return
  end
  if sh.kind == "switch" then
    params = { id = sh.index, on = params.on ~= false }
  end
  self.rpcId = (self.rpcId or 0) % 1000000 + 1
  self:_publish(
    sh.prefix .. "/rpc",
    JSON:encode({ id = self.rpcId, src = sh.src, method = SHELLY_METHODS[sh.kind] .. ".Set", params = params })
  )
end

-------------------------------------------------------------------------------
-- Control4 -> device
-------------------------------------------------------------------------------

--- Convert a ramp rate to the configured transition value.
function MqttLight:_transitionValue(rateMs)
  rateMs = math.max(0, tonumber(rateMs) or 0)
  local U = MqttLight.TRANSITION_UNITS
  local unit = self.cfg.transitionUnit or U.SECONDS
  if unit == U.MS then
    return round(rateMs)
  elseif unit == U.TENTHS then
    return round(rateMs / 100)
  elseif unit == U.TASMOTA then
    return Color.clamp(round(rateMs / 500), 1, 40)
  end
  return Color.roundTo(rateMs / 1000, 2)
end

function MqttLight:_brightnessValue(level)
  local max = tonumber(self.cfg.brightnessMax) or 100
  if max <= 0 then
    max = 100
  end
  local v = round(Color.clamp(level, 0, 100) * max / 100)
  if level > 0 and v < 1 then
    v = 1
  end
  return v
end

function MqttLight:_whiteValue(level)
  local max = tonumber(self.cfg.whiteMax) or 100
  if max <= 0 then
    max = 100
  end
  local v = round(Color.clamp(level, 0, 100) * max / 100)
  if level > 0 and v < 1 then
    v = 1
  end
  return v
end

function MqttLight:_colorTempValue(kelvin)
  local c = self.caps
  if c.cctMin then
    kelvin = Color.clamp(kelvin, c.cctMin, c.cctMax)
  end
  if self.cfg.colorTempUnit == "Kelvin" then
    return round(kelvin)
  end
  return Color.kelvinToMired(kelvin)
end

--- Format a full color for a plain topic.
--- @param x number
--- @param y number
--- @param level number brightness 0-100 (used when the format carries brightness)
function MqttLight:_colorValue(x, y, level)
  local F = MqttLight.COLOR_FORMATS
  local fmt = self.cfg.colorFormat or F.RGB
  local r, g, b = Color.xyToRgb(x, y)
  if fmt == F.XY then
    return string.format("%.4f,%.4f", x, y)
  elseif fmt == F.HS or fmt == F.HSB then
    local h, s = Color.rgbToHsv(r, g, b)
    if fmt == F.HS then
      return string.format("%d,%d", round(h), round(s))
    end
    return string.format("%d,%d,%d", round(h), round(s), round(level))
  end
  if self:_colorCarriesBrightness() then
    r, g, b = Color.scaleRgb(r, g, b, level)
  end
  if fmt == F.HEX then
    return string.format("%02X%02X%02X", r, g, b)
  elseif fmt == F.HEX_HASH then
    return string.format("#%02X%02X%02X", r, g, b)
  end
  return string.format("%d,%d,%d", r, g, b)
end

--- Color object for JSON mode.
function MqttLight:_jsonColorValue(x, y)
  local F = MqttLight.JSON_COLOR_FORMATS
  local fmt = self.cfg.jsonColorFormat or F.XY
  if fmt == F.RGB then
    local r, g, b = Color.xyToRgb(x, y)
    return { r = r, g = g, b = b }
  elseif fmt == F.HS then
    local h, s = Color.rgbToHsv(Color.xyToRgb(x, y))
    return { hue = round(h), saturation = round(s) }
  end
  return { x = Color.roundTo(x, 4), y = Color.roundTo(y, 4) }
end

--- Current color, or neutral white when unknown.
function MqttLight:_currentColor()
  return self.color or self:deviceColor() or { x = 0.3127, y = 0.329, mode = MqttLight.COLOR_MODE_FULL }
end

--- Publish a command to the device.
--- @param cmd table { power?: boolean, level?: number, color?: {x,y,mode}, rate?: number }
function MqttLight:_send(cmd)
  local c = self.caps
  local level = cmd.level
  local turningOff = cmd.power == false or (level ~= nil and level <= 0)
  local turningOn = cmd.power == true or (level ~= nil and level > 0)
  local effLevel = (level ~= nil and level > 0) and level
    or (self.level ~= nil and self.level > 0 and self.level)
    or 100
  local color = cmd.color

  if self:isShellyMode() then
    return self:_sendShelly(cmd)
  end

  if self:isJsonMode() then
    local json = self.cfg.json or {}
    local keys = json.keys or {}
    local obj = {}
    if turningOff then
      obj[keys.power or "state"] = notEmpty(self.cfg.payloadOff) and self.cfg.payloadOff or "OFF"
    elseif turningOn or color ~= nil then
      obj[keys.power or "state"] = notEmpty(self.cfg.payloadOn) and self.cfg.payloadOn or "ON"
    end
    if not turningOff then
      if level ~= nil and level > 0 and c.brightness then
        obj[keys.brightness] = self:_brightnessValue(level)
      end
      if color ~= nil then
        if color.mode == MqttLight.COLOR_MODE_CCT and c.colorTemp then
          obj[keys.colorTemp] = self:_colorTempValue(Color.xyToCct(color.x, color.y))
        elseif color.mode == MqttLight.COLOR_MODE_CCT and c.white then
          obj[keys.white] = self:_whiteValue(c.brightness and 100 or effLevel)
        elseif c.color then
          obj[keys.color] = self:_jsonColorValue(color.x, color.y)
        elseif c.colorTemp then
          obj[keys.colorTemp] = self:_colorTempValue(Color.xyToCct(color.x, color.y))
        end
      elseif
        level ~= nil
        and level > 0
        and not c.brightness
        and c.white
        and self.device.mode == MqttLight.COLOR_MODE_CCT
      then
        obj[keys.white] = self:_whiteValue(level)
      end
    end
    if c.transition and cmd.rate ~= nil then
      obj[keys.transition] = self:_transitionValue(cmd.rate)
    end
    if next(obj) then
      self:_publish(json.commandTopic, JSON:encode(obj))
    end
    return
  end

  local topics = self.cfg.topics or {}
  local function cmdTopic(name)
    return trim((topics[name] or {}).commandTopic or "")
  end

  if c.transition and cmd.rate ~= nil then
    self:_publish(cmdTopic("transition"), self:_transitionValue(cmd.rate))
  end

  if turningOff then
    if cmdTopic("power") ~= "" then
      self:_publish(cmdTopic("power"), notEmpty(self.cfg.payloadOff) and self.cfg.payloadOff or "OFF")
    elseif cmdTopic("brightness") ~= "" then
      self:_publish(cmdTopic("brightness"), 0)
    elseif c.colorBrightness and cmdTopic("color") ~= "" then
      local cur = self:_currentColor()
      self:_publish(cmdTopic("color"), self:_colorValue(cur.x, cur.y, 0))
    elseif cmdTopic("white") ~= "" then
      self:_publish(cmdTopic("white"), 0)
    end
    return
  end

  if cmd.power == true and cmdTopic("power") ~= "" then
    self:_publish(cmdTopic("power"), notEmpty(self.cfg.payloadOn) and self.cfg.payloadOn or "ON")
  end

  local colorCarriedLevel = false
  local whiteCarriedLevel = false
  if color ~= nil then
    if color.mode == MqttLight.COLOR_MODE_CCT and cmdTopic("colorTemp") ~= "" then
      self:_publish(cmdTopic("colorTemp"), self:_colorTempValue(Color.xyToCct(color.x, color.y)))
    elseif color.mode == MqttLight.COLOR_MODE_CCT and cmdTopic("white") ~= "" then
      self:_publish(cmdTopic("white"), self:_whiteValue(c.brightness and 100 or effLevel))
      whiteCarriedLevel = not c.brightness
    elseif cmdTopic("color") ~= "" then
      self:_publish(cmdTopic("color"), self:_colorValue(color.x, color.y, effLevel))
      colorCarriedLevel = c.colorBrightness
    elseif cmdTopic("colorTemp") ~= "" then
      self:_publish(cmdTopic("colorTemp"), self:_colorTempValue(Color.xyToCct(color.x, color.y)))
    end
  end

  if level ~= nil and level > 0 then
    if cmdTopic("brightness") ~= "" then
      self:_publish(cmdTopic("brightness"), self:_brightnessValue(level))
    elseif not colorCarriedLevel and not whiteCarriedLevel then
      local inWhite = self.device.mode == MqttLight.COLOR_MODE_CCT and c.white and not c.colorTemp
      if inWhite and cmdTopic("white") ~= "" then
        self:_publish(cmdTopic("white"), self:_whiteValue(level))
      elseif c.colorBrightness and cmdTopic("color") ~= "" then
        local cur = self:_currentColor()
        self:_publish(cmdTopic("color"), self:_colorValue(cur.x, cur.y, level))
      elseif cmdTopic("white") ~= "" and not c.color and not c.colorTemp then
        self:_publish(cmdTopic("white"), self:_whiteValue(level))
      end
    end
  end
end

--- Update the model as if the device confirmed a command (optimistic mode).
function MqttLight:_assume(cmd)
  local d = self.device
  if cmd.level ~= nil then
    if cmd.level <= 0 then
      d.power = false
    else
      d.power = true
      d.brightness = cmd.level
      d.colorBrightness = cmd.level
      if d.mode == MqttLight.COLOR_MODE_CCT and self.caps.white and not self.caps.colorTemp then
        d.white = cmd.level
      end
    end
  elseif cmd.power ~= nil then
    d.power = cmd.power
  end
  if cmd.color ~= nil then
    d.mode = cmd.color.mode
    if cmd.color.mode == MqttLight.COLOR_MODE_CCT then
      d.kelvin = Color.xyToCct(cmd.color.x, cmd.color.y)
    else
      d.color = { x = cmd.color.x, y = cmd.color.y }
    end
  end
end

--- Send a command, track the commanded color mode, and assume when optimistic.
function MqttLight:_execute(cmd)
  if cmd.color ~= nil then
    self.lastMode = cmd.color.mode
  end
  self:_send(cmd)
  if self:isOptimistic() then
    self:_assume(cmd)
  end
end

--- Color to apply with a brightness change that has no explicit color.
--- Turning on: the color requested while off, else the Default On color
--- (warm-dimmed toward the Dim color below the On level). Already on: only the
--- warm-dim adjustment, and only until someone picks a color explicitly.
--- @param targetLevel number
--- @param turningOn boolean
--- @return table|nil
function MqttLight:_autoColor(targetLevel, turningOn)
  if not (self.caps.color or self.caps.cct) then
    return nil
  end
  if turningOn and self.offColor ~= nil then
    local c = self.offColor
    self.offColor = nil
    return c
  end
  if self.colorOverride then
    return nil
  end
  local on = self.settings.onColor
  if on == nil then
    return nil
  end
  local dim = self.settings.dimColor
  local onLevel = tonumber(self.settings.onLevel) or 100
  if not turningOn and (dim == nil or sameXy(dim, on)) then
    return nil
  end
  if dim == nil or targetLevel >= onLevel or onLevel <= 1 then
    if not turningOn and sameXy(self.color, on) then
      return nil
    end
    return { x = on.x, y = on.y, mode = on.mode }
  end
  -- Warm dim: interpolate between Dim (1%) and On (Default On Brightness)
  local f = Color.clamp((targetLevel - 1) / (onLevel - 1), 0, 1)
  if on.mode == MqttLight.COLOR_MODE_CCT and dim.mode == MqttLight.COLOR_MODE_CCT then
    local k1, k2 = Color.xyToCct(dim.x, dim.y), Color.xyToCct(on.x, on.y)
    local x, y = Color.cctToXy(k1 + (k2 - k1) * f)
    return { x = x, y = y, mode = MqttLight.COLOR_MODE_CCT }
  end
  return { x = dim.x + (on.x - dim.x) * f, y = dim.y + (on.y - dim.y) * f, mode = MqttLight.COLOR_MODE_FULL }
end

--- Interpolated level of the running ramp.
function MqttLight:_rampLevel()
  local r = self.ramp
  if r == nil then
    return self.level or 0
  end
  if r.rate <= 0 then
    return r.target
  end
  local f = Color.clamp((self.now() - r.start) / r.rate, 0, 1)
  return r.from + (r.target - r.from) * f
end

function MqttLight:_cancelRampTimers()
  CancelTimer(self:_timer("RampStep"))
  CancelTimer(self:_timer("RampEnd"))
end

--- Finish the running ramp and report where the light ended.
function MqttLight:_finishRamp()
  local r = self.ramp
  self:_cancelRampTimers()
  self.ramp = nil
  if r == nil then
    return
  end
  if self:isOptimistic() then
    self:_reportLevel(r.target, true)
    if r.color then
      self:_reportColor(r.color, true)
    end
  else
    self:_syncFromDevice(true)
  end
end

--- Start a brightness ramp (or jump when rate is 0).
--- @param target number 0-100
--- @param rate number milliseconds
--- @param color table|nil color to apply with this change
function MqttLight:rampTo(target, rate, color)
  target = Color.clamp(tonumber(target) or 0, 0, 100)
  rate = math.max(0, tonumber(rate) or 0)
  self:_cancelRampTimers()
  self.ramp = nil

  if not self.caps.dimmer then
    target = target > 0 and 100 or 0
    rate = 0
  end
  if target > 0 and target < 1 then
    target = 1
  end

  local from = self.level or 0
  if target <= 0 then
    self.colorOverride = false
  elseif color ~= nil then
    self.colorOverride = true
  else
    color = self:_autoColor(target, from <= 0)
  end
  if color ~= nil and target <= 0 then
    self.offColor = color
    color = nil
  end

  local powerOn = (target > 0 and from <= 0) or nil

  if self.caps.dimmer then
    self:_notify("LIGHT_BRIGHTNESS_CHANGING", {
      LIGHT_BRIGHTNESS_CURRENT = round(from),
      LIGHT_BRIGHTNESS_TARGET = round(target),
      RATE = rate,
    })
  end
  if color ~= nil then
    self:_notifyColorChanging(color, rate)
  end

  if rate <= 0 or from == target then
    self:_execute({ power = powerOn, level = target, color = color })
    if self:isOptimistic() then
      self:_reportLevel(target, true)
      if color then
        self:_reportColor(color, true)
      end
    elseif not self:hasStateFeedback() then
      self:_reportLevel(target, true)
    end
    return
  end

  self.ramp = { from = from, target = target, rate = rate, start = self.now(), color = color }

  if self.caps.transition then
    -- The device fades by itself
    self.ramp.native = true
    self:_execute({ power = powerOn, level = target, color = color, rate = rate })
    SetTimer(self:_timer("RampEnd"), rate, function()
      self:_finishRamp()
    end)
    return
  end

  -- Emulate the ramp with stepped level commands
  local steps = math.max(1, math.min(MAX_STEPS, math.floor(rate / MIN_STEP_MS)))
  local interval = rate / steps
  local first = true
  local function step()
    local r = self.ramp
    if r == nil then
      return
    end
    local lvl = self:_rampLevel()
    local done = (self.now() - r.start) >= r.rate
    if done then
      lvl = r.target
    end
    -- Level 0 means off: only the final step of a ramp to off may send it.
    if lvl < 1 and (not done or r.target > 0) then
      lvl = 1
    end
    lvl = round(lvl)
    if first or done or lvl ~= r.lastSent then
      self:_execute({
        power = first and powerOn or nil,
        level = lvl,
        color = first and color or nil,
      })
      r.lastSent = lvl
    end
    first = false
    if done then
      self:_finishRamp()
    else
      SetTimer(self:_timer("RampStep"), interval, step)
    end
  end
  step()
end

--- Stop a running ramp where it is.
function MqttLight:stopRamp()
  local r = self.ramp
  if r == nil then
    return
  end
  local lvl = round(self:_rampLevel())
  -- A fade toward on that is stopped at once must not stop at 0 (off).
  if r.target > 0 and lvl < 1 then
    lvl = 1
  end
  self:_cancelRampTimers()
  self.ramp = nil
  if r.native then
    self:_execute({ level = lvl, rate = 0 })
  elseif self:isOptimistic() then
    self:_assume({ level = lvl })
  end
  -- Report where it stopped now; device feedback corrects it if needed.
  self:_reportLevel(lvl, true)
end

function MqttLight:_notifyColorChanging(color, rate)
  local cur = self.color or color
  self:_notify("LIGHT_COLOR_CHANGING", {
    LIGHT_COLOR_TARGET_X = Color.roundTo(color.x, 4),
    LIGHT_COLOR_TARGET_Y = Color.roundTo(color.y, 4),
    LIGHT_COLOR_TARGET_COLOR_MODE = color.mode,
    LIGHT_COLOR_TARGET_RATE = rate or 0,
    LIGHT_COLOR_CURRENT_X = Color.roundTo(cur.x, 4),
    LIGHT_COLOR_CURRENT_Y = Color.roundTo(cur.y, 4),
    LIGHT_COLOR_CURRENT_COLOR_MODE = cur.mode,
  })
end

--- Queue a brightness and/or color change; consecutive commands are combined.
function MqttLight:_queue(change)
  self.pending = self.pending or {}
  for k, v in pairs(change) do
    self.pending[k] = v
  end
  SetTimer(self:_timer("Flush"), DEBOUNCE_MS, function()
    self:flush()
  end)
end

--- Send whatever is queued.
function MqttLight:flush()
  CancelTimer(self:_timer("Flush"))
  local p = self.pending
  self.pending = nil
  if p == nil then
    return
  end
  if p.level ~= nil then
    self:rampTo(p.level, p.rate, p.color)
    return
  end
  if p.color ~= nil then
    self:setColor(p.color, p.colorRate)
  end
end

--- Change color without changing brightness.
function MqttLight:setColor(color, rate)
  rate = math.max(0, tonumber(rate) or 0)
  local on = (self.level or 0) > 0 or (self.ramp ~= nil and self.ramp.target > 0)
  if not on then
    -- Best practice: don't turn the light on; use this color at the next turn on.
    self.offColor = color
    self:_reportColor(color, true)
    return
  end
  self.colorOverride = true
  self:_notifyColorChanging(color, rate)
  self:_execute({ color = color, rate = self.caps.transition and rate or nil })
  if self:isOptimistic() then
    self:_reportColor(color, true)
  end
end

-------------------------------------------------------------------------------
-- Keypad buttons (BUTTON_ACTION)
-------------------------------------------------------------------------------

local BUTTON_TOP, BUTTON_BOTTOM, BUTTON_TOGGLE = 0, 1, 2
local ACTION_RELEASE_HOLD, ACTION_PRESS, ACTION_RELEASE_CLICK = 0, 1, 2

function MqttLight:_click(buttonId)
  local s = self.settings
  local on = (self.level or 0) > 0
  if buttonId == BUTTON_TOP or (buttonId == BUTTON_TOGGLE and not on) then
    self:rampTo(tonumber(s.onLevel) or 100, s.clickRateUp)
  else
    self:rampTo(0, s.clickRateDown)
  end
end

function MqttLight:_startHold(buttonId)
  local s = self.settings
  local on = (self.level or 0) > 0
  local up = buttonId == BUTTON_TOP or (buttonId == BUTTON_TOGGLE and not on)
  local from = self.level or 0
  local target = up and 100 or 0
  local fullRate = tonumber(up and s.holdRateUp or s.holdRateDown) or 3000
  local rate = math.max(1, round(fullRate * math.abs(target - from) / 100))
  self.press.holding = true
  if from == target then
    return
  end
  self:rampTo(target, rate)
end

--- Handle BUTTON_ACTION from the proxy (keypad bindings).
--- @param buttonId number 0 top, 1 bottom, 2 toggle
--- @param action number 0 release after hold, 1 press, 2 release after click
function MqttLight:buttonAction(buttonId, action)
  buttonId, action = tonumber(buttonId), tonumber(action)
  if buttonId == nil or action == nil then
    return
  end
  -- Echo so the proxy knows the button's state (and fires its button events)
  self:_notify("BUTTON_ACTION", { BUTTON_ID = buttonId, ACTION = action })

  if action == ACTION_PRESS then
    self.press = { id = buttonId, holding = false }
    if self.caps.dimmer then
      SetTimer(self:_timer("Hold"), HOLD_DELAY_MS, function()
        if self.press and self.press.id == buttonId then
          self:_startHold(buttonId)
        end
      end)
    end
    return
  end

  CancelTimer(self:_timer("Hold"))
  local press = self.press
  self.press = nil
  if press ~= nil and press.holding then
    if action == ACTION_RELEASE_HOLD or action == ACTION_RELEASE_CLICK then
      self:stopRamp()
    end
    return
  end
  if action == ACTION_RELEASE_CLICK or action == ACTION_RELEASE_HOLD then
    self:_click(buttonId)
  end
end

-------------------------------------------------------------------------------
-- Proxy commands
-------------------------------------------------------------------------------

local function num(params, ...)
  for _, k in ipairs({ ... }) do
    local v = tonumber(params[k])
    if v ~= nil then
      return v
    end
  end
  return nil
end

--- Handle a command from the light_v2 proxy.
--- @param command string
--- @param params table
--- @return boolean handled
function MqttLight:handleProxyCommand(command, params)
  params = params or {}
  local s = self.settings

  if command == "SET_BRIGHTNESS_TARGET" then
    local target = num(params, "LIGHT_BRIGHTNESS_TARGET", "LEVEL")
    if target == nil then
      return true
    end
    local rate = num(params, "RATE", "LIGHT_BRIGHTNESS_TARGET_RATE", "TIME") or s.brightnessRateDefault
    self:_queue({ level = target, rate = rate })
  elseif command == "SET_COLOR_TARGET" then
    local x = num(params, "LIGHT_COLOR_TARGET_X")
    local y = num(params, "LIGHT_COLOR_TARGET_Y")
    if x == nil or y == nil then
      return true
    end
    local mode = num(params, "LIGHT_COLOR_TARGET_MODE", "LIGHT_COLOR_TARGET_COLOR_MODE") or 0
    local rate = num(params, "LIGHT_COLOR_TARGET_RATE", "RATE") or s.colorRateDefault
    self:_queue({ color = { x = x, y = y, mode = mode }, colorRate = rate })
  elseif command == "SET_BRIGHTNESS_STOP" or command == "STOP_RAMP" then
    self:flush()
    self:stopRamp()
  elseif command == "SET_COLOR_STOP" then
    -- Color changes are not tracked step by step; nothing to stop.
    return true
  elseif command == "ON" or command == "DYNAMIC_ON" then
    self:rampTo(tonumber(s.onLevel) or 100, s.brightnessRateDefault)
  elseif command == "OFF" or command == "DYNAMIC_OFF" then
    self:rampTo(0, s.brightnessRateDefault)
  elseif command == "TOGGLE" then
    if (self.level or 0) > 0 then
      self:rampTo(0, s.brightnessRateDefault)
    else
      self:rampTo(tonumber(s.onLevel) or 100, s.brightnessRateDefault)
    end
  elseif command == "SET_LEVEL" or command == "RAMP_TO_LEVEL" then
    local level = num(params, "LEVEL")
    if level ~= nil then
      self:rampTo(level, num(params, "TIME") or 0)
    end
  -- Load groups (Switch Group and other light groups). MQTT lights have no
  -- device-side groups, so each member acts on the group command itself.
  elseif command == "GROUP_SET_LEVEL" or command == "GROUP_RAMP_TO_LEVEL" then
    local level = num(params, "LEVEL")
    if level ~= nil then
      self:rampTo(level, command == "GROUP_RAMP_TO_LEVEL" and (num(params, "TIME") or 0) or 0)
    end
  elseif command == "GROUP_START_RAMP" then
    local up = tostring(params.RAMP_UP or ""):lower()
    local rampUp = up == "true" or up == "1"
    local rate = num(params, "RATE") or (rampUp and s.holdRateUp or s.holdRateDown) or 3000
    -- The rate is for the whole range; scale it to the distance left.
    local from = self.level or 0
    local target = rampUp and 100 or 0
    self:rampTo(target, math.max(1, round(rate * math.abs(target - from) / 100)))
  elseif command == "GROUP_STOP_RAMP" then
    self:stopRamp()
  elseif command == "JOIN_GROUP" or command == "LEAVE_GROUP" or command == "SET_GROUP_SYNC" then
    log:debug("%s group %s (keep sync %s)", command, tostring(params.GROUP_ID), tostring(params.KEEP_SYNC))
  elseif command == "BUTTON_ACTION" then
    self:buttonAction(params.BUTTON_ID, params.ACTION)
  elseif command == "SET_CLICK_RATE_UP" or command == "SET_CLICK_RATE_DOWN" then
    local rate = num(params, "RATE")
    if rate ~= nil then
      local up = command == "SET_CLICK_RATE_UP"
      s[up and "clickRateUp" or "clickRateDown"] = rate
      self:_notify(up and "CLICK_RATE_UP" or "CLICK_RATE_DOWN", { RATE = rate })
      self:_saveSettings()
    end
  elseif command == "SET_HOLD_RATE_UP" or command == "SET_HOLD_RATE_DOWN" then
    local rate = num(params, "RATE")
    if rate ~= nil then
      local up = command == "SET_HOLD_RATE_UP"
      s[up and "holdRateUp" or "holdRateDown"] = rate
      self:_notify(up and "HOLD_RATE_UP" or "HOLD_RATE_DOWN", { RATE = rate })
      self:_saveSettings()
    end
  elseif command == "SET_PRESET_LEVEL" then
    local level = num(params, "LEVEL")
    if level ~= nil then
      s.onLevel = level
      self:_notify("PRESET_LEVEL", { BRIGHTNESS = level })
      self:_saveSettings()
    end
  elseif command == "UPDATE_BRIGHTNESS_PRESET" then
    local id = num(params, "PRESET_ID", "ID")
    local level = num(params, "LEVEL")
    if level ~= nil and (id == 1 or params.NAME == "On") and params.COMMAND ~= "REMOVED" then
      s.onLevel = level
      self:_saveSettings()
    end
  elseif command == "UPDATE_BRIGHTNESS_ON_MODE" then
    local level = num(params, "BRIGHTNESS_PRESET_LEVEL")
    if level ~= nil and level > 0 then
      s.onLevel = level
      self:_saveSettings()
    end
  elseif command == "UPDATE_BRIGHTNESS_RATE_DEFAULT" or command == "SET_BRIGHTNESS_RATE_DEFAULT" then
    s.brightnessRateDefault = num(params, "RATE") or 0
    self:_saveSettings()
  elseif command == "UPDATE_COLOR_RATE_DEFAULT" or command == "SET_COLOR_RATE_DEFAULT" then
    s.colorRateDefault = num(params, "RATE") or 0
    self:_saveSettings()
  elseif command == "UPDATE_COLOR_PRESET" then
    local name = tostring(params.NAME or "")
    local x, y = num(params, "COLOR_X"), num(params, "COLOR_Y")
    local key = (name == "On" and "onColor") or ((name == "Dim" or name == "Off") and "dimColor") or nil
    if key ~= nil then
      if params.COMMAND == "REMOVED" or x == nil or y == nil then
        s[key] = nil
      else
        s[key] = { x = x, y = y, mode = num(params, "COLOR_MODE") or 0 }
      end
      self:_saveSettings()
    end
  else
    return false
  end
  return true
end

-------------------------------------------------------------------------------
-- Display
-------------------------------------------------------------------------------

--- One-line state summary for the driver's read-only property.
--- @return string
function MqttLight:stateText()
  if self.level == nil then
    return "Unknown"
  end
  if self.level <= 0 then
    return "Off"
  end
  local parts = { "On" }
  if self.caps.dimmer then
    table.insert(parts, string.format("%d%%", self.level))
  end
  local c = self.color
  if c ~= nil then
    if c.mode == MqttLight.COLOR_MODE_CCT then
      table.insert(parts, string.format("%dK", round(Color.xyToCct(c.x, c.y) / 10) * 10))
    elseif self.caps.color then
      local r, g, b = Color.xyToRgb(c.x, c.y)
      table.insert(parts, string.format("#%02X%02X%02X", r, g, b))
    end
  end
  return table.concat(parts, " ")
end

return MqttLight
