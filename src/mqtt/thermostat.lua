--- @module "mqtt.thermostat"
--- MQTT thermostat model for the MQTT Thermostat driver (Control4
--- thermostatV2 proxy).
---
--- Every ability has its own topics; an ability exists when its topic is
--- filled in:
---   temperature   current temperature (state)
---   humidity      current humidity (state)
---   heat / cool   setpoints (state + command); the same command topic for
---                 both makes it a single-setpoint thermostat
---   mode          HVAC mode (state + command), with a value map
---   power         on/off (state + command): mode Off switches it off
---   action        HVAC state (Heating, Cooling, Idle, ...), with a value map
---   fan           fan mode (state + command), with a value map
---
--- Commands use a payload template ("{value}" by default) so devices that
--- need more than the value work too, e.g. TuyaMCU "TuyaSend2 16,{value}".
--- Temperatures are in the device's scale (C or F), times an optional
--- multiplier (10 for devices that send 215 for 21.5).

local log = require("lib.logging")
local stateParser = require("mqtt.state_parser")

local Thermostat = {}
Thermostat.__index = Thermostat

--- Control4 HVAC modes, states and fan modes, with the device values used
--- when no value map is set (Home Assistant MQTT climate style).
Thermostat.HVAC_MODES = { "Off", "Heat", "Cool", "Auto", "Fan Only", "Dry" }
Thermostat.DEFAULT_MODE_VALUES = {
  Off = "off",
  Heat = "heat",
  Cool = "cool",
  Auto = "auto",
  ["Fan Only"] = "fan_only",
  Dry = "dry",
}
Thermostat.HVAC_STATES = { "Off", "Heating", "Cooling", "Idle", "Drying", "Fan Only" }
Thermostat.DEFAULT_ACTION_VALUES = {
  Off = "off",
  Heating = "heating",
  Cooling = "cooling",
  Idle = "idle",
  Drying = "drying",
  ["Fan Only"] = "fan",
}
Thermostat.FAN_MODES = { "Auto", "On", "Off", "Low", "Medium", "High" }
Thermostat.DEFAULT_FAN_VALUES = { Auto = "auto", On = "on", Off = "off", Low = "low", Medium = "medium", High = "high" }

local function trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function notEmpty(s)
  return s ~= nil and trim(s) ~= ""
end

local function decodeJson(payload)
  local ok, t = pcall(JSON.decode, JSON, payload)
  if ok and type(t) == "table" then
    return t
  end
  return nil
end

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

local function roundTo(v, step)
  step = (step and step > 0) and step or 0.1
  return math.floor(v / step + 0.5) * step
end

--- A number as text without float noise ("21.5", "22").
local function numText(v)
  local s = string.format("%.2f", v):gsub("0+$", ""):gsub("%.$", "")
  return s
end

function Thermostat.toCelsius(v, scale)
  return scale == "F" and (v - 32) * 5 / 9 or v
end

function Thermostat.fromCelsius(c, scale)
  return scale == "F" and c * 9 / 5 + 32 or c
end

--- Parse "Off=0, Heat=1" into { Off = "0", Heat = "1" } (Control4 name -> device value).
--- Names are matched to the allowed Control4 names case-insensitively.
--- @return table|nil map, string[] order
function Thermostat.parseValueMap(text, allowed)
  if not notEmpty(text) then
    return nil, {}
  end
  local byLower = {}
  for _, name in ipairs(allowed) do
    byLower[name:lower()] = name
  end
  local map, order = {}, {}
  for pair in tostring(text):gmatch("[^,;]+") do
    local name, value = pair:match("^%s*(.-)%s*=%s*(.-)%s*$")
    local c4 = name and byLower[name:lower()]
    if c4 and value ~= "" then
      if map[c4] == nil then
        order[#order + 1] = c4
      end
      map[c4] = value
    end
  end
  return map, order
end

--- The Control4 name for a device value: the map first, then the Control4
--- names themselves and the defaults, ignoring case.
local function toC4(value, map, defaults, allowed)
  if value == nil then
    return nil
  end
  local v = trim(tostring(value)):lower()
  if v == "" then
    return nil
  end
  for c4, dv in pairs(map or {}) do
    if trim(dv):lower() == v then
      return c4
    end
  end
  for _, c4 in ipairs(allowed) do
    if c4:lower() == v or (defaults[c4] or ""):lower() == v then
      return c4
    end
  end
  return nil
end

-------------------------------------------------------------------------------
-- Construction and configuration
-------------------------------------------------------------------------------

function Thermostat.new(opts)
  local self = setmetatable({}, Thermostat)
  self.proxyBinding = opts.proxyBinding
  self.brokerBinding = opts.brokerBinding
  self.onStateChanged = opts.onStateChanged
  self.cfg = {}
  self.caps = {}
  self:resetState()
  return self
end

function Thermostat:resetState()
  -- What the device reported, in Celsius for temperatures
  self.device = {}
  -- What the proxy was last told: notification -> value
  self.sent = {}
end

local function feature(cfg, name)
  return (cfg.features or {})[name] or {}
end

function Thermostat:_has(name, which)
  return notEmpty(feature(self.cfg, name)[which or "stateTopic"])
end

--- Apply a configuration; true when the capabilities changed.
function Thermostat:configure(cfg)
  self.cfg = cfg or {}
  self.modeMap, self.modeOrder = Thermostat.parseValueMap(feature(cfg, "mode").values, Thermostat.HVAC_MODES)
  self.actionMap = Thermostat.parseValueMap(feature(cfg, "action").values, Thermostat.HVAC_STATES)
  self.fanMap, self.fanOrder = Thermostat.parseValueMap(feature(cfg, "fan").values, Thermostat.FAN_MODES)
  local old = self.caps
  self.caps = self:computeCapabilities()
  for _, k in ipairs({ "heat", "cool", "auto", "single", "humidity", "modes", "fanModes" }) do
    if tostring(old[k]) ~= tostring(self.caps[k]) then
      return true
    end
  end
  return false
end

function Thermostat:scale()
  return self.cfg.scale == "F" and "F" or "C"
end

function Thermostat:computeCapabilities()
  local caps = {}
  local heatCmd = trim(feature(self.cfg, "heat").commandTopic)
  local coolCmd = trim(feature(self.cfg, "cool").commandTopic)
  local heat = heatCmd ~= "" or self:_has("heat")
  local cool = coolCmd ~= "" or self:_has("cool")
  caps.single = heat and cool and heatCmd ~= "" and heatCmd == coolCmd
  if caps.single then
    -- One setpoint: Control4 shows a single setpoint, the mode picks heat or cool.
    caps.heat, caps.cool = false, false
  else
    caps.heat, caps.cool = heat, cool
  end
  -- A single setpoint on its own (only a heat or only a cool topic) is still that.
  caps.humidity = self:_has("humidity")
  caps.temperature = self:_has("temperature")

  local modes = {}
  local function add(m)
    for _, x in ipairs(modes) do
      if x == m then
        return
      end
    end
    modes[#modes + 1] = m
  end
  if self:_has("mode", "commandTopic") then
    if self.modeMap then
      for _, m in ipairs(self.modeOrder) do
        add(m)
      end
    else
      add("Off")
      if heat then
        add("Heat")
      end
      if cool then
        add("Cool")
      end
      if heat and cool and not caps.single then
        add("Auto")
      end
    end
  else
    if self:_has("power", "commandTopic") then
      add("Off")
    end
    if heat then
      add("Heat")
    end
    if cool then
      add("Cool")
    end
  end
  if self:_has("power", "commandTopic") then
    add("Off")
  end
  if #modes == 0 then
    add(cool and "Cool" or "Heat")
  end
  caps.modes = table.concat(modes, ",")
  caps.modeList = modes
  local auto = false
  for _, m in ipairs(modes) do
    auto = auto or m == "Auto"
  end
  caps.auto = auto and caps.heat and caps.cool

  local fans = {}
  if self:_has("fan", "commandTopic") or self:_has("fan") then
    if self.fanMap then
      fans = self.fanOrder
    else
      fans = { "Auto", "Low", "Medium", "High" }
    end
  end
  caps.fanModes = table.concat(fans, ",")
  return caps
end

--- Topics to subscribe to.
function Thermostat:subscriptions()
  local set, list = {}, {}
  for _, name in ipairs({ "temperature", "humidity", "heat", "cool", "mode", "power", "action", "fan" }) do
    local t = trim(feature(self.cfg, name).stateTopic)
    if t ~= "" and not set[t] then
      set[t] = true
      list[#list + 1] = t
    end
  end
  table.sort(list)
  return list
end

function Thermostat:hasStateFeedback()
  return #self:subscriptions() > 0
end

function Thermostat:isOptimistic()
  local o = self.cfg.optimistic
  if o == "Yes" then
    return true
  elseif o == "No" then
    return false
  end
  return not self:hasStateFeedback()
end

-------------------------------------------------------------------------------
-- Proxy
-------------------------------------------------------------------------------

function Thermostat:_notify(command, params)
  SendToProxy(self.proxyBinding, command, params or {}, "NOTIFY")
end

--- Notify only when the value changed (or force).
function Thermostat:_notifyChanged(command, key, params, force)
  local sig = key .. "=" .. tostring(params[key])
  if not force and self.sent[command] == sig then
    return
  end
  self.sent[command] = sig
  self:_notify(command, params)
end

--- Setpoint limits and step, in the device scale.
function Thermostat:limits()
  local s = self:scale()
  local min = tonumber(self.cfg.setpointMin) or (s == "F" and 40 or 5)
  local max = tonumber(self.cfg.setpointMax) or (s == "F" and 95 or 35)
  local step = tonumber(self.cfg.setpointStep) or (s == "F" and 1 or 0.5)
  return math.min(min, max), math.max(min, max), step
end

--- Send what the thermostat can do.
function Thermostat:sendCapabilities()
  local c = self.caps
  self:_notify("DYNAMIC_CAPABILITIES_CHANGED", {
    CAN_HEAT = c.heat,
    CAN_COOL = c.cool,
    CAN_DO_AUTO = c.auto,
    HAS_SINGLE_SETPOINT = c.single,
    HAS_HUMIDITY = c.humidity,
  })
  local s = self:scale()
  local min, max, step = self:limits()
  local minC, maxC = Thermostat.toCelsius(min, s), Thermostat.toCelsius(max, s)
  local minF, maxF = Thermostat.fromCelsius(minC, "F"), Thermostat.fromCelsius(maxC, "F")
  local resC = s == "C" and step or (step >= 1.5 and 1 or 0.5)
  local resF = s == "F" and step or (step >= 1 and 2 or 1)
  local caps = {}
  for _, p in ipairs({ "HEAT", "COOL", "SINGLE" }) do
    caps[p .. "_SETPOINT_MIN_C"] = math.floor(minC + 0.5)
    caps[p .. "_SETPOINT_MAX_C"] = math.floor(maxC + 0.5)
    caps[p .. "_SETPOINT_MIN_F"] = math.floor(minF + 0.5)
    caps[p .. "_SETPOINT_MAX_F"] = math.floor(maxF + 0.5)
    caps[p .. "_SETPOINT_RESOLUTION_C"] = resC
    caps[p .. "_SETPOINT_RESOLUTION_F"] = resF
  end
  self:_notify("DYNAMIC_CAPABILITIES_CHANGED", caps)
  self:_notify("ALLOWED_HVAC_MODES_CHANGED", { MODES = c.modes })
  if c.fanModes ~= "" then
    self:_notify("ALLOWED_FAN_MODES_CHANGED", { MODES = c.fanModes })
  end
  self:_notify("SCALE_CHANGED", { SCALE = s })
end

--- Resend capabilities and the last state.
function Thermostat:refreshProxy()
  self:sendCapabilities()
  self.sent = {}
  self:_report(true)
end

function Thermostat:setConnected(connected)
  self:_notify("CONNECTION", { CONNECTED = connected and "true" or "false" })
end

--- The HVAC mode the device is in, as a Control4 mode.
function Thermostat:hvacMode()
  local d = self.device
  if d.power == false then
    return "Off"
  end
  if d.mode ~= nil then
    return d.mode
  end
  if d.power == true then
    -- Powered on, no mode topic: the one mode it has
    for _, m in ipairs(self.caps.modeList or {}) do
      if m ~= "Off" then
        return m
      end
    end
  end
  return nil
end

--- Tell the proxy everything that changed.
function Thermostat:_report(force)
  local d, s = self.device, self:scale()
  local function temp(command, value)
    if value ~= nil then
      local v = Thermostat.fromCelsius(value, s)
      self:_notifyChanged(command, "SETPOINT", { SETPOINT = numText(roundTo(v, 0.1)), SCALE = s }, force)
    end
  end
  if d.temperature ~= nil then
    local v = Thermostat.fromCelsius(d.temperature, s)
    self:_notifyChanged(
      "TEMPERATURE_CHANGED",
      "TEMPERATURE",
      { TEMPERATURE = numText(roundTo(v, 0.1)), SCALE = s },
      force
    )
  end
  if d.humidity ~= nil then
    self:_notifyChanged("HUMIDITY_CHANGED", "HUMIDITY", { HUMIDITY = tostring(math.floor(d.humidity + 0.5)) }, force)
  end
  if self.caps.single then
    temp("SINGLE_SETPOINT_CHANGED", d.heat or d.cool)
  else
    if self.caps.heat then
      temp("HEAT_SETPOINT_CHANGED", d.heat)
    end
    if self.caps.cool then
      temp("COOL_SETPOINT_CHANGED", d.cool)
    end
  end
  local mode = self:hvacMode()
  if mode ~= nil then
    self:_notifyChanged("HVAC_MODE_CHANGED", "MODE", { MODE = mode }, force)
  end
  local state = d.action
  if d.power == false and self:_has("action") then
    state = "Off"
  end
  if state ~= nil then
    self:_notifyChanged("HVAC_STATE_CHANGED", "STATE", { STATE = state }, force)
  end
  if d.fan ~= nil then
    self:_notifyChanged("FAN_MODE_CHANGED", "MODE", { MODE = d.fan }, force)
  end
  if self.onStateChanged then
    self.onStateChanged(self)
  end
end

-------------------------------------------------------------------------------
-- Device -> Control4
-------------------------------------------------------------------------------

function Thermostat:_multiplier()
  local m = tonumber(self.cfg.multiplier) or 1
  return m ~= 0 and m or 1
end

--- A device temperature (with multiplier, in the device scale) in Celsius.
function Thermostat:_deviceTemp(value)
  local n = tonumber(value)
  if n == nil then
    return nil
  end
  return Thermostat.toCelsius(n / self:_multiplier(), self:scale())
end

function Thermostat:_parsePower(value)
  local p = feature(self.cfg, "power")
  local on, off = trim(p.stateOn), trim(p.stateOff)
  if type(value) == "boolean" then
    return value
  end
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

--- Handle an MQTT message; true when it belongs to this thermostat.
function Thermostat:onMessage(topicName, payload)
  topicName = trim(topicName)
  local d = self.device
  local handled = false
  local function value(name)
    local f = feature(self.cfg, name)
    if trim(f.stateTopic) == "" or trim(f.stateTopic) ~= topicName then
      return nil
    end
    handled = true
    return extract(payload, f.valuePath)
  end
  local v = value("temperature")
  if v ~= nil then
    d.temperature = self:_deviceTemp(v) or d.temperature
  end
  v = value("humidity")
  if v ~= nil then
    d.humidity = tonumber(v) or d.humidity
  end
  v = value("heat")
  if v ~= nil then
    d.heat = self:_deviceTemp(v) or d.heat
  end
  v = value("cool")
  if v ~= nil then
    d.cool = self:_deviceTemp(v) or d.cool
  end
  v = value("mode")
  if v ~= nil then
    local m = toC4(v, self.modeMap, Thermostat.DEFAULT_MODE_VALUES, Thermostat.HVAC_MODES)
    if m == nil then
      log:debug("Unknown HVAC mode value '%s'", tostring(v))
    else
      d.mode = m
    end
  end
  v = value("power")
  if v ~= nil then
    local p = self:_parsePower(v)
    if p ~= nil then
      d.power = p
    end
  end
  v = value("action")
  if v ~= nil then
    local a
    if self.actionMap ~= nil then
      a = toC4(v, self.actionMap, Thermostat.DEFAULT_ACTION_VALUES, Thermostat.HVAC_STATES)
    else
      -- No map: a relay or switch state (ON/OFF, true/false, 1/0) is heating
      -- (cooling for cool-only devices) or idle; otherwise the state names.
      local p = self:_parsePower(v)
      if p ~= nil then
        a = p and (self.caps.cool and not self.caps.heat and "Cooling" or "Heating") or "Idle"
      else
        a = toC4(v, nil, Thermostat.DEFAULT_ACTION_VALUES, Thermostat.HVAC_STATES)
      end
    end
    if a ~= nil then
      d.action = a
    end
  end
  v = value("fan")
  if v ~= nil then
    d.fan = toC4(v, self.fanMap, Thermostat.DEFAULT_FAN_VALUES, Thermostat.FAN_MODES) or d.fan
  end
  if not handled then
    return false
  end
  self:_report(false)
  return true
end

-------------------------------------------------------------------------------
-- Control4 -> device
-------------------------------------------------------------------------------

function Thermostat:_publish(topicName, payload)
  topicName = trim(topicName)
  if topicName == "" then
    return false
  end
  log:debug("Publishing %s -> %s", topicName, payload)
  SendToProxy(self.brokerBinding, "PUBLISH", {
    topic = topicName,
    payload = tostring(payload or ""),
    qos = self.cfg.qos or "0",
    retain = self.cfg.retain and "true" or "false",
  })
  return true
end

--- Fill a payload template: {value} becomes the value ("{value}" when empty).
local function fill(template, value)
  template = template or ""
  if trim(template) == "" then
    template = "{value}"
  end
  return (template:gsub("{value}", (tostring(value):gsub("%%", "%%%%"))))
end

--- Temperatures from the proxy: CELSIUS, FAHRENHEIT, or VALUE with SCALE.
function Thermostat.celsiusFromParams(p)
  local c = tonumber(p.CELSIUS)
  if c ~= nil then
    return c
  end
  local f = tonumber(p.FAHRENHEIT)
  if f ~= nil then
    return Thermostat.toCelsius(f, "F")
  end
  local v = tonumber(p.VALUE or p.SETPOINT)
  if v == nil then
    return nil
  end
  local s = tostring(p.SCALE or ""):upper():sub(1, 1)
  return Thermostat.toCelsius(v, s == "F" and "F" or "C")
end

--- Send a setpoint (in Celsius) for "heat" or "cool".
function Thermostat:setSetpoint(which, celsius)
  local f = feature(self.cfg, which)
  if trim(f.commandTopic) == "" then
    log:debug("No %s setpoint command topic", which)
    return
  end
  local s = self:scale()
  local min, max, step = self:limits()
  local v = roundTo(math.max(min, math.min(max, Thermostat.fromCelsius(celsius, s))), step)
  local m = self:_multiplier()
  local out = m ~= 1 and tostring(math.floor(v * m + 0.5)) or numText(v)
  self:_publish(f.commandTopic, fill(f.template, out))
  if self:isOptimistic() or not self:_has(which) then
    self.device[which] = Thermostat.toCelsius(v, s)
    if self.caps.single then
      self.device.heat, self.device.cool = self.device[which], self.device[which]
    end
    self:_report(false)
  end
end

--- Step a setpoint up or down by the setpoint step.
function Thermostat:stepSetpoint(which, direction)
  local current = self.device[which] or (self.caps.single and (self.device.heat or self.device.cool))
  if current == nil then
    return
  end
  local s = self:scale()
  local _, _, step = self:limits()
  self:setSetpoint(which, Thermostat.toCelsius(Thermostat.fromCelsius(current, s) + direction * step, s))
end

function Thermostat:setPower(on)
  local p = feature(self.cfg, "power")
  if trim(p.commandTopic) == "" then
    return false
  end
  local payload = on and (notEmpty(p.payloadOn) and p.payloadOn or "ON")
    or (notEmpty(p.payloadOff) and p.payloadOff or "OFF")
  self:_publish(p.commandTopic, payload)
  if self:isOptimistic() or not self:_has("power") then
    self.device.power = on
  end
  return true
end

--- Set the HVAC mode (a Control4 mode name).
function Thermostat:setMode(mode)
  local f = feature(self.cfg, "mode")
  local hasMode = trim(f.commandTopic) ~= ""
  local hasPower = self:_has("power", "commandTopic")
  if mode == "Off" and hasPower then
    self:setPower(false)
    if self:isOptimistic() or not self:_has("power") then
      self:_report(false)
    end
    return
  end
  if hasPower and mode ~= "Off" and self.device.power ~= true then
    self:setPower(true)
  end
  if hasMode then
    local value = (self.modeMap or Thermostat.DEFAULT_MODE_VALUES)[mode]
    if value == nil then
      log:warn("HVAC mode '%s' has no device value; add it to the Mode Values", mode)
      return
    end
    self:_publish(f.commandTopic, fill(f.template, value))
    if self:isOptimistic() or not self:_has("mode") then
      self.device.mode = mode
    end
  end
  if self:isOptimistic() or not (self:_has("mode") or self:_has("power")) then
    self:_report(false)
  end
end

function Thermostat:setFanMode(mode)
  local f = feature(self.cfg, "fan")
  if trim(f.commandTopic) == "" then
    return
  end
  local value = (self.fanMap or Thermostat.DEFAULT_FAN_VALUES)[mode]
  if value == nil then
    log:warn("Fan mode '%s' has no device value", mode)
    return
  end
  self:_publish(f.commandTopic, fill(f.template, value))
  if self:isOptimistic() or not self:_has("fan") then
    self.device.fan = mode
    self:_report(false)
  end
end

--- Commands from the thermostatV2 proxy; true when handled.
function Thermostat:handleProxyCommand(command, params)
  params = params or {}
  local single = self.caps.single
  local function setpointTarget(which)
    -- A single-setpoint thermostat takes either on its one topic.
    if single then
      return trim(feature(self.cfg, "heat").commandTopic) ~= "" and "heat" or "cool"
    end
    return which
  end
  if command == "SET_SETPOINT_HEAT" or command == "SET_SETPOINT_COOL" or command == "SET_SETPOINT_SINGLE" then
    local c = Thermostat.celsiusFromParams(params)
    if c ~= nil then
      local which = command == "SET_SETPOINT_COOL" and "cool" or "heat"
      self:setSetpoint(setpointTarget(which), c)
    end
  elseif command:match("^INC_SETPOINT_") or command:match("^DEC_SETPOINT_") then
    local which = command:match("COOL$") and "cool" or "heat"
    self:stepSetpoint(setpointTarget(which), command:match("^INC") and 1 or -1)
  elseif command == "SET_MODE_HVAC" then
    if params.MODE then
      self:setMode(params.MODE)
    end
  elseif command == "SET_MODE_OFF" then
    self:setMode("Off")
  elseif command == "SET_MODE_HEAT" then
    self:setMode("Heat")
  elseif command == "SET_MODE_COOL" then
    self:setMode("Cool")
  elseif command == "SET_MODE_AUTO" then
    self:setMode("Auto")
  elseif command == "SET_MODE_FAN" then
    if params.MODE then
      self:setFanMode(params.MODE)
    end
  elseif command == "SET_SCALE" then
    local s = tostring(params.SCALE or ""):upper():sub(1, 1)
    if s == "C" or s == "F" then
      self:_notify("SCALE_CHANGED", { SCALE = s })
    end
  else
    return false
  end
  return true
end

function Thermostat:stateText()
  local d, s = self.device, self:scale()
  local parts = {}
  local mode = self:hvacMode()
  if mode then
    parts[#parts + 1] = mode
  end
  if d.action then
    parts[#parts + 1] = d.action
  end
  if d.temperature then
    parts[#parts + 1] = numText(roundTo(Thermostat.fromCelsius(d.temperature, s), 0.1)) .. "°" .. s
  end
  local sp = d.heat or d.cool
  if sp then
    parts[#parts + 1] = "setpoint " .. numText(roundTo(Thermostat.fromCelsius(sp, s), 0.1)) .. "°" .. s
  end
  return #parts > 0 and table.concat(parts, ", ") or "Unknown"
end

return Thermostat
