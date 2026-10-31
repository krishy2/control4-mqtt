--- @module "mqtt.fan"
--- MQTT fan model for the MQTT Fan driver (Control4 "fan" proxy).
---
--- The fan proxy reads its speed count, speed names and reverse ability from
--- driver.xml only; no fan capability is dynamic. The driver therefore always
--- declares 6 speeds and can_reverse, and this model maps the device's real
--- speeds (Speed Count, or the number of Speed Values) onto Control4 levels
--- 1-6 with cfg.mapping:
---   Spread    device speed s of N is Control4 level floor(s * 6 / N), so the
---             top speed is always level 6 (3 speeds: levels 2, 4, 6)
---   Direct    device speed s is level s; levels above N run the top speed
--- Level 0 is off.
---
--- The proxy protocol (docs-driverworks-proxyprotocol-fan):
---   proxy -> driver   ON, OFF, TOGGLE, SET_SPEED { SPEED }, CYCLE_SPEED_UP,
---                     CYCLE_SPEED_DOWN, SET_DIRECTION { DIRECTION },
---                     TOGGLE_DIRECTION, DESIGNATE_PRESET { PRESET },
---                     GET_CURRENT_STATE
---   driver -> proxy   ON / OFF (power flips), CURRENT_SPEED { SPEED } (every
---                     report, 0 when off), DIRECTION { DIRECTION },
---                     PRESET_SPEED { SPEED }
---
--- Two payload styles, like the light:
---   Separate Topics  power, speed and direction state topics with value paths,
---                    and command topics (Tasmota iFan: cmnd/<t>/FanSpeed)
---   JSON             one state and one command topic carrying an object
---                    (Zigbee2MQTT: {"fan_state":"ON","fan_mode":"low"})
---
--- Capability rule, as in the light: an ability exists when its topic (or key)
--- is filled in. On/Off always; speeds with a speed topic/key; reverse with a
--- direction topic/key.

local log = require("lib.logging")
local stateParser = require("mqtt.state_parser")

local Fan = {}
Fan.__index = Fan

Fan.MODE_TOPICS = "Separate Topics"
Fan.MODE_JSON = "JSON"
Fan.MAPPING_SPREAD = "Spread over 6 Levels"
Fan.MAPPING_DIRECT = "Levels 1 to N"
Fan.ON_PRESET = "Preset Speed"
Fan.ON_LAST = "Last Speed"
Fan.FORWARD, Fan.REVERSE = "FORWARD", "REVERSE"

--- Control4 levels: the driver declares this many speeds (driver.xml).
Fan.LEVELS = 6
Fan.MAX_SPEEDS = 6

local function trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function notEmpty(s)
  return s ~= nil and trim(s) ~= ""
end

local function clamp(v, lo, hi)
  return math.max(lo, math.min(hi, v))
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

--- A value from a payload: the whole payload, or a JSONPath into it.
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

--- A value from a JSON table by a plain key or a JSONPath ("$.a.b").
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

--- "low, medium, high" -> { "low", "medium", "high" }
function Fan.splitValues(s)
  local out = {}
  for part in tostring(s or ""):gmatch("[^,]+") do
    part = trim(part)
    if part ~= "" then
      out[#out + 1] = part
    end
  end
  return out
end

-------------------------------------------------------------------------------
-- Construction and configuration
-------------------------------------------------------------------------------

--- @param opts table { proxyBinding, brokerBinding, onStateChanged? }
function Fan.new(opts)
  local self = setmetatable({}, Fan)
  self.proxyBinding = opts.proxyBinding
  self.brokerBinding = opts.brokerBinding
  self.onStateChanged = opts.onStateChanged
  self.cfg = {}
  self.caps = { speeds = 1 }
  self.preset = nil -- Control4 level chosen with DESIGNATE_PRESET
  self.lastSpeed = nil -- last device speed the fan ran at (for On = Last Speed)
  self:resetState()
  return self
end

function Fan:resetState()
  -- What the device reported
  self.device = { power = nil, speed = nil, direction = nil }
  -- What the proxy was last told
  self.level = nil
  self.direction = nil
end

function Fan:isJson()
  return self.cfg.mode == Fan.MODE_JSON
end

--- Apply a configuration; true when the capabilities changed.
function Fan:configure(cfg)
  self.cfg = cfg or {}
  local old = self.caps
  self.caps = self:computeCapabilities()
  for _, k in ipairs({ "speeds", "hasSpeed", "reverse", "power" }) do
    if old[k] ~= self.caps[k] then
      return true
    end
  end
  return false
end

--- Does a feature have a topic (topics mode) or key (JSON mode)?
--- @return boolean has, boolean canCommand
function Fan:_has(feature)
  if self:isJson() then
    local json = self.cfg.json or {}
    local has = (notEmpty(json.stateTopic) or notEmpty(json.commandTopic)) and notEmpty((json.keys or {})[feature])
    return has, has and notEmpty(json.commandTopic)
  end
  local t = (self.cfg.topics or {})[feature] or {}
  return notEmpty(t.stateTopic) or notEmpty(t.commandTopic), notEmpty(t.commandTopic)
end

--- The device values for speeds 1..N.
function Fan:speedValues()
  local values = Fan.splitValues(self.cfg.speedValues)
  if #values > 0 then
    while #values > Fan.MAX_SPEEDS do
      table.remove(values)
    end
    return values
  end
  local n = clamp(math.floor(tonumber(self.cfg.speedCount) or 3), 1, Fan.MAX_SPEEDS)
  for i = 1, n do
    values[i] = tostring(i)
  end
  return values
end

function Fan:computeCapabilities()
  local caps = {}
  caps.power, caps.powerCmd = self:_has("power")
  caps.hasSpeed, caps.speedCmd = self:_has("speed")
  caps.reverse, caps.directionCmd = self:_has("direction")
  caps.speeds = caps.hasSpeed and #self:speedValues() or 1
  return caps
end

function Fan:describeCapabilities()
  local c = self.caps
  local parts = { "On/Off" }
  if c.hasSpeed then
    parts[#parts + 1] = string.format("%d Speed%s", c.speeds, c.speeds == 1 and "" or "s")
  end
  if c.reverse then
    parts[#parts + 1] = "Reverse"
  end
  if not self:hasStateFeedback() then
    parts[#parts + 1] = "no state feedback"
  end
  return table.concat(parts, ", ")
end

--- Topics to subscribe to.
function Fan:subscriptions()
  local set, list = {}, {}
  local function add(t)
    t = trim(t)
    if t ~= "" and not set[t] then
      set[t] = true
      list[#list + 1] = t
    end
  end
  if self:isJson() then
    add((self.cfg.json or {}).stateTopic)
  else
    for _, feature in ipairs({ "power", "speed", "direction" }) do
      add(((self.cfg.topics or {})[feature] or {}).stateTopic)
    end
  end
  table.sort(list)
  return list
end

function Fan:hasStateFeedback()
  return #self:subscriptions() > 0
end

function Fan:isOptimistic()
  local o = self.cfg.optimistic
  if o == "Yes" then
    return true
  elseif o == "No" then
    return false
  end
  return not self:hasStateFeedback()
end

-------------------------------------------------------------------------------
-- Speeds and levels
-------------------------------------------------------------------------------

function Fan:_direct()
  return self.cfg.mapping == Fan.MAPPING_DIRECT
end

--- Device speed (1..N) -> Control4 level (1..6).
function Fan:levelForSpeed(speed)
  local n = self.caps.speeds
  speed = clamp(math.floor(tonumber(speed) or n), 1, n)
  if self:_direct() then
    return speed
  end
  return math.floor(speed * Fan.LEVELS / n)
end

--- Control4 level (1..6) -> device speed (1..N); 0 for off.
function Fan:speedForLevel(level)
  level = math.floor(tonumber(level) or 0)
  if level <= 0 then
    return 0
  end
  local n = self.caps.speeds
  level = clamp(level, 1, Fan.LEVELS)
  if self:_direct() then
    return math.min(level, n)
  end
  return clamp(math.ceil(level * n / Fan.LEVELS), 1, n)
end

--- A speed value from the device -> device speed (1..N), 0 for off, nil when unknown.
function Fan:parseSpeed(value)
  if value == nil or type(value) == "table" then
    return nil
  end
  local s = trim(value)
  local off = trim(self.cfg.speedOff)
  if off ~= "" and s:lower() == off:lower() then
    return 0
  end
  local values = self:speedValues()
  for i, v in ipairs(values) do
    if s:lower() == v:lower() then
      return i
    end
  end
  local n = tonumber(s)
  if n == nil then
    return nil
  end
  -- Numbers (percentages, levels): the nearest speed value, 0 below the lowest.
  local best, bestDist, lowest = nil, math.huge, math.huge
  for i, v in ipairs(values) do
    local vn = tonumber(v)
    if vn == nil then
      return nil
    end
    lowest = math.min(lowest, vn)
    if math.abs(vn - n) < bestDist then
      best, bestDist = i, math.abs(vn - n)
    end
  end
  if n <= 0 and lowest > 0 then
    return 0
  end
  return best
end

function Fan:parsePower(value)
  if type(value) == "boolean" then
    return value
  end
  if value == nil or type(value) == "table" then
    return nil
  end
  local on, off = trim(self.cfg.stateOn), trim(self.cfg.stateOff)
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

function Fan:parseDirection(value)
  if value == nil or type(value) == "table" then
    return nil
  end
  local s = trim(value):lower()
  local fwd, rev = trim(self.cfg.directionForward):lower(), trim(self.cfg.directionReverse):lower()
  if fwd ~= "" and s == fwd then
    return Fan.FORWARD
  elseif rev ~= "" and s == rev then
    return Fan.REVERSE
  elseif s == "forward" or s == "fwd" then
    return Fan.FORWARD
  elseif s == "reverse" or s == "rev" then
    return Fan.REVERSE
  end
  return nil
end

--- The Control4 level the device is at, from what it reported; nil when unknown.
function Fan:deviceLevel()
  local d = self.device
  local on = d.power
  if not self.caps.power or on == nil then
    -- No power feedback: the speed says it all.
    if d.speed == nil then
      return on == nil and nil or (on and self:levelForSpeed(self.lastSpeed) or 0)
    end
    on = d.speed > 0
  end
  if not on then
    return 0
  end
  if not self.caps.hasSpeed then
    return self:levelForSpeed(1)
  end
  local speed = (d.speed ~= nil and d.speed > 0) and d.speed or self.lastSpeed
  return self:levelForSpeed(speed)
end

-------------------------------------------------------------------------------
-- Proxy
-------------------------------------------------------------------------------

function Fan:_notify(command, params)
  log:trace("fan notify %s %s", command, params)
  SendToProxy(self.proxyBinding, command, params or {}, "NOTIFY")
end

function Fan:_stateChanged()
  if self.onStateChanged then
    self.onStateChanged(self)
  end
end

--- Tell the proxy a level (and ON / OFF when the power flips).
function Fan:_reportLevel(level, force)
  if level == nil then
    return
  end
  local before = self.level
  if not force and before == level then
    return
  end
  self.level = level
  if level > 0 then
    self.lastSpeed = self:speedForLevel(level)
  end
  if force or before == nil or (before > 0) ~= (level > 0) then
    self:_notify(level > 0 and "ON" or "OFF")
  end
  self:_notify("CURRENT_SPEED", { SPEED = tostring(level) })
  self:_stateChanged()
end

function Fan:_reportDirection(direction, force)
  if direction == nil or (not force and direction == self.direction) then
    return
  end
  self.direction = direction
  self:_notify("DIRECTION", { DIRECTION = direction })
  self:_stateChanged()
end

function Fan:notifyPreset()
  if self.preset ~= nil then
    self:_notify("PRESET_SPEED", { SPEED = tostring(self.preset) })
  end
end

--- Resend everything the proxy shows (start-up, GET_CURRENT_STATE).
function Fan:refreshProxy()
  if self.level ~= nil then
    self:_reportLevel(self.level, true)
  end
  if self.caps.reverse and self.direction ~= nil then
    self:_reportDirection(self.direction, true)
  end
  self:notifyPreset()
end

-------------------------------------------------------------------------------
-- Device -> Control4
-------------------------------------------------------------------------------

function Fan:_apply(u)
  local d = self.device
  for k, v in pairs(u) do
    d[k] = v
  end
  if d.speed ~= nil and d.speed > 0 then
    self.lastSpeed = d.speed
  end
  self:_reportLevel(self:deviceLevel())
  if self.caps.reverse then
    self:_reportDirection(d.direction)
  end
end

--- Handle an MQTT message; true when it belongs to this fan.
function Fan:onMessage(topicName, payload)
  topicName = trim(topicName)
  if topicName == "" then
    return false
  end
  local u, handled = {}, false
  if self:isJson() then
    local json = self.cfg.json or {}
    if trim(json.stateTopic) ~= topicName then
      return false
    end
    handled = true
    local t = decodeJson(payload)
    if t == nil then
      return true
    end
    local keys = json.keys or {}
    if self.caps.power then
      u.power = self:parsePower(lookup(t, keys.power))
    end
    if self.caps.hasSpeed then
      u.speed = self:parseSpeed(lookup(t, keys.speed))
    end
    if self.caps.reverse then
      u.direction = self:parseDirection(lookup(t, keys.direction))
    end
  else
    local topics = self.cfg.topics or {}
    local function feature(name)
      local t = topics[name] or {}
      if trim(t.stateTopic) == "" or trim(t.stateTopic) ~= topicName then
        return nil
      end
      handled = true
      return extract(payload, t.valuePath)
    end
    u.power = self:parsePower(feature("power"))
    u.speed = self.caps.hasSpeed and self:parseSpeed(feature("speed")) or nil
    u.direction = self:parseDirection(feature("direction"))
  end
  if not handled then
    return false
  end
  self:_apply(u)
  return true
end

-------------------------------------------------------------------------------
-- Control4 -> device
-------------------------------------------------------------------------------

function Fan:_publish(topicName, payload)
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

function Fan:_command(feature)
  return trim(((self.cfg.topics or {})[feature] or {}).commandTopic)
end

function Fan:isOn()
  return (self.level or 0) > 0
end

--- A speed command payload: the Speed Command Payload template with {value}
--- replaced, or the value itself when there is no template.
function Fan:_speedPayload(value)
  local template = trim(self.cfg.speedTemplate)
  if template == "" then
    return value
  end
  return (template:gsub("{value}", (tostring(value):gsub("%%", "%%%%"))))
end

--- Run the fan at a device speed (1..N), or turn it off (0).
--- @return boolean sent
function Fan:_sendSpeed(speed)
  local caps, cfg = self.caps, self.cfg
  local values = self:speedValues()
  if self:isJson() then
    local json = cfg.json or {}
    local keys = json.keys or {}
    local obj = {}
    if speed <= 0 then
      if caps.powerCmd then
        obj[trim(keys.power)] = cfg.payloadOff
      elseif caps.speedCmd and notEmpty(cfg.speedOff) then
        obj[trim(keys.speed)] = trim(cfg.speedOff)
      end
    else
      if caps.powerCmd then
        obj[trim(keys.power)] = cfg.payloadOn
      end
      if caps.speedCmd then
        obj[trim(keys.speed)] = values[speed]
      end
    end
    if next(obj) == nil then
      log:warn("Nothing to send: fill in a State Key (or a Speed Key with Speed Off Value)")
      return false
    end
    -- Numbers stay numbers in JSON (Speed Values "1,2,3", "33,66,100").
    for k, v in pairs(obj) do
      obj[k] = tonumber(v) or v
    end
    return self:_publish(json.commandTopic, JSON:encode(obj))
  end

  if speed <= 0 then
    if caps.powerCmd then
      return self:_publish(self:_command("power"), cfg.payloadOff)
    elseif caps.speedCmd and notEmpty(cfg.speedOff) then
      return self:_publish(self:_command("speed"), self:_speedPayload(trim(cfg.speedOff)))
    end
    log:warn("Cannot turn the fan off: fill in a Power Command Topic, or a Speed Off Value")
    return false
  end
  local sent = false
  -- Power on first when the speed topic cannot turn the fan on by itself.
  if caps.powerCmd and (not self:isOn() or not caps.speedCmd) then
    sent = self:_publish(self:_command("power"), cfg.payloadOn) or sent
  end
  if caps.speedCmd then
    sent = self:_publish(self:_command("speed"), self:_speedPayload(values[speed])) or sent
  end
  if not sent then
    log:warn("Cannot turn the fan on: fill in a Power or Speed Command Topic")
  end
  return sent
end

--- After a command: optimistic fans are assumed to be where they were sent.
function Fan:_commanded(level)
  if self:isOptimistic() then
    local speed = self:speedForLevel(level)
    self.device.power = level > 0
    if speed > 0 then
      self.device.speed = speed
    elseif self.caps.hasSpeed and not self.caps.power then
      self.device.speed = 0
    end
    self:_reportLevel(level)
  end
end

--- Set a Control4 level (0 = off, 1-6).
function Fan:setLevel(level)
  level = clamp(math.floor(tonumber(level) or 0), 0, Fan.LEVELS)
  local speed = self:speedForLevel(level)
  if self:_sendSpeed(speed) then
    self:_commanded(speed > 0 and self:levelForSpeed(speed) or 0)
  end
end

--- The level ON goes to: the preset, or the last speed.
function Fan:onLevel()
  if self.cfg.onSpeed == Fan.ON_LAST and self.lastSpeed ~= nil then
    return self:levelForSpeed(self.lastSpeed)
  end
  if self.preset ~= nil then
    return self:levelForSpeed(self:speedForLevel(self.preset))
  end
  return Fan.LEVELS
end

function Fan:on()
  self:setLevel(self:onLevel())
end

function Fan:off()
  self:setLevel(0)
end

function Fan:toggle()
  if self:isOn() then
    self:off()
  else
    self:on()
  end
end

--- One device speed up (from off: the lowest); stays at the top speed.
function Fan:speedUp()
  local current = self:isOn() and self:speedForLevel(self.level) or 0
  self:setLevel(self:levelForSpeed(math.min(self.caps.speeds, current + 1)))
end

--- One device speed down; from the lowest speed: off.
function Fan:speedDown()
  if not self:isOn() then
    return
  end
  local current = self:speedForLevel(self.level)
  if current <= 1 then
    return self:off()
  end
  self:setLevel(self:levelForSpeed(current - 1))
end

function Fan:setDirection(direction)
  if not self.caps.directionCmd then
    log:warn("Cannot change direction: fill in a Direction Command Topic (or Direction Key)")
    return
  end
  local value = direction == Fan.REVERSE and trim(self.cfg.directionReverse) or trim(self.cfg.directionForward)
  local sent
  if self:isJson() then
    local json = self.cfg.json or {}
    sent = self:_publish(json.commandTopic, JSON:encode({ [trim((json.keys or {}).direction)] = value }))
  else
    sent = self:_publish(self:_command("direction"), value)
  end
  if sent and self:isOptimistic() then
    self.device.direction = direction
    self:_reportDirection(direction)
  end
end

function Fan:toggleDirection()
  self:setDirection(self.direction == Fan.REVERSE and Fan.FORWARD or Fan.REVERSE)
end

--- DESIGNATE_PRESET: the level ON goes to.
--- @return boolean changed
function Fan:designatePreset(preset)
  local n = math.floor(tonumber(preset) or 0)
  if n < 1 then
    return false
  end
  self.preset = clamp(n, 1, Fan.LEVELS)
  self:notifyPreset()
  return true
end

--- Commands from the fan proxy; true when handled.
function Fan:handleProxyCommand(command, params)
  params = params or {}
  if command == "ON" then
    self:on()
  elseif command == "OFF" then
    self:off()
  elseif command == "TOGGLE" then
    self:toggle()
  elseif command == "SET_SPEED" then
    self:setLevel(params.SPEED)
  elseif command == "CYCLE_SPEED_UP" then
    self:speedUp()
  elseif command == "CYCLE_SPEED_DOWN" then
    self:speedDown()
  elseif command == "SET_DIRECTION" then
    local d = tostring(params.DIRECTION or params.str or ""):upper()
    if d == "" then
      d = params.FORWARD ~= nil and Fan.FORWARD or (params.REVERSE ~= nil and Fan.REVERSE or "")
    end
    if d == Fan.FORWARD or d == Fan.REVERSE then
      self:setDirection(d)
    else
      log:warn("SET_DIRECTION with an unknown direction: %s", params)
    end
  elseif command == "TOGGLE_DIRECTION" then
    self:toggleDirection()
  elseif command == "DESIGNATE_PRESET" then
    self:designatePreset(params.PRESET)
  elseif command == "GET_CURRENT_STATE" then
    self:refreshProxy()
  else
    return false
  end
  return true
end

function Fan:stateText()
  if self.level == nil then
    return "Unknown"
  end
  if self.level <= 0 then
    return "Off"
  end
  local text
  if self.caps.hasSpeed then
    local speed = self:speedForLevel(self.level)
    local value = self:speedValues()[speed]
    text = string.format("Speed %d of %d (%s, level %d)", speed, self.caps.speeds, value, self.level)
  else
    text = "On"
  end
  if self.caps.reverse and self.direction == Fan.REVERSE then
    text = text .. ", reverse"
  end
  return text
end

return Fan
