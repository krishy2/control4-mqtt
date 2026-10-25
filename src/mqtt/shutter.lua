--- @module "mqtt.shutter"
--- MQTT shutter model for the MQTT Shutter driver (Control4 "blind" proxy).
---
--- The proxy protocol follows Control4's own 2 Relay Blinds driver:
---   proxy -> driver   SET_LEVEL_TARGET { LEVEL_TARGET }, STOP
---   driver -> proxy   SET_CAN_STOP { CAN_STOP },
---                     SET_HAS_LEVEL { HAS_LEVEL, LEVEL_OPEN, LEVEL_CLOSED, ... },
---                     MOVING { LEVEL_TARGET, RAMP_RATE }, STOPPED { LEVEL }
--- With a position the levels are 0 (closed) to 100 (open). Without one the
--- shutter only opens and closes: LEVEL_OPEN 2, stop 1, LEVEL_CLOSED 0.
---
--- One driver controls either the shutter's position or its slats (tilt),
--- picked with cfg.control; a venetian blind uses two drivers.
---
--- Three payload styles, like the light:
---   Separate Topics  position/state/tilt state topics with value paths, and
---                    command topics (Tasmota: cmnd/<t>/ShutterPosition1 ...)
---   JSON             one state and one command topic carrying an object
---                    (Zigbee2MQTT: {"state":"OPEN"}, {"position":50})
---   Shelly (Gen2+)   a cover:N output over Shelly RPC

local log = require("lib.logging")
local stateParser = require("mqtt.state_parser")

local Shutter = {}
Shutter.__index = Shutter

Shutter.MODE_TOPICS = "Separate Topics"
Shutter.MODE_JSON = "JSON"
Shutter.MODE_SHELLY = "Shelly (Gen2+)"
Shutter.CONTROL_POSITION = "Position"
Shutter.CONTROL_TILT = "Tilt"

Shutter.OPENING, Shutter.CLOSING, Shutter.STOPPED = "opening", "closing", "stopped"

-- Proxy levels without a position (from the stock driver)
local DISCRETE_OPEN, DISCRETE_STOP, DISCRETE_CLOSED = 2, 1, 0
-- A move the device does not report the end of is taken as finished after its
-- estimated time plus this much.
local FINISH_MARGIN_MS = 3000

local function trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function notEmpty(s)
  return s ~= nil and trim(s) ~= ""
end

local function round(v)
  return math.floor((tonumber(v) or 0) + 0.5)
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

--- A movement from a state value: Tasmota Direction (1 / -1 / 0), Home
--- Assistant states (opening, closing, stopped, open, closed), Zigbee2MQTT
--- moving (UP, DOWN, STOP) or Shelly cover states.
--- @return string|nil OPENING, CLOSING or STOPPED
function Shutter.parseMovement(value)
  if value == nil then
    return nil
  end
  local n = tonumber(value)
  if n ~= nil then
    return n > 0 and Shutter.OPENING or (n < 0 and Shutter.CLOSING or Shutter.STOPPED)
  end
  local s = trim(value):lower()
  if s == "opening" or s == "up" or s == "rising" then
    return Shutter.OPENING
  elseif s == "closing" or s == "down" or s == "falling" then
    return Shutter.CLOSING
  elseif s == "stopped" or s == "stop" or s == "open" or s == "closed" or s == "idle" or s == "calibrating" then
    return Shutter.STOPPED
  end
  return nil
end

--- An end position from a state value: open -> 100, closed -> 0, else nil.
function Shutter.parseEndpoint(value)
  if value == nil or type(value) == "table" then
    return nil
  end
  local s = trim(value):lower()
  if s == "open" or s == "opened" then
    return 100
  elseif s == "closed" or s == "close" then
    return 0
  end
  return nil
end

-------------------------------------------------------------------------------
-- Construction and configuration
-------------------------------------------------------------------------------

--- @param opts table { proxyBinding, brokerBinding, now?, timerPrefix?, onStateChanged? }
function Shutter.new(opts)
  local self = setmetatable({}, Shutter)
  self.proxyBinding = opts.proxyBinding
  self.brokerBinding = opts.brokerBinding
  self.now = opts.now or function()
    return C4 and C4.GetTime and C4:GetTime() or os.time() * 1000
  end
  self.timerPrefix = opts.timerPrefix or "MqttShutter"
  self.onStateChanged = opts.onStateChanged
  self.cfg = {}
  self.caps = {}
  self:resetState()
  return self
end

function Shutter:resetState()
  -- What the device reported
  self.device = { position = nil, tilt = nil, movement = nil, target = nil, posControl = nil }
  self.shellyStatus = {}
  -- What the proxy was last told
  self.level = nil
  self.moving = nil -- { target, started, rate } while a move is under way
end

--- Apply a configuration; true when the capabilities changed.
function Shutter:configure(cfg)
  self.cfg = cfg or {}
  local old = self.caps
  self.caps = self:computeCapabilities()
  for _, k in ipairs({ "hasLevel", "canStop", "tilt" }) do
    if old[k] ~= self.caps[k] then
      return true
    end
  end
  return false
end

function Shutter:isTilt()
  return self.cfg.control == Shutter.CONTROL_TILT
end

function Shutter:isShelly()
  return self.cfg.mode == Shutter.MODE_SHELLY
end

function Shutter:isJson()
  return self.cfg.mode == Shutter.MODE_JSON
end

--- Shelly settings, or nil when incomplete.
function Shutter:_shelly()
  local sh = self.cfg.shelly or {}
  local prefix, key = trim(sh.prefix), trim(sh.component)
  local index = key:match("^cover:(%d+)$")
  if prefix == "" or index == nil then
    return nil
  end
  return {
    prefix = prefix,
    key = key,
    index = tonumber(index),
    src = "control4/" .. prefix .. "/" .. key:gsub(":", "_"),
  }
end

local function topic(t)
  return trim((t or {}).commandTopic)
end

--- Capabilities from the configuration (and, for Shelly, its calibration).
function Shutter:computeCapabilities()
  local cfg, caps = self.cfg, {}
  local tilt = self:isTilt()
  if self:isShelly() then
    local ok = self:_shelly() ~= nil
    -- An uncalibrated cover only opens and closes; slats need slat control.
    caps.hasLevel = ok and (tilt or self.device.posControl ~= false)
    caps.canStop = ok
    caps.canOpenClose = ok
  elseif self:isJson() then
    local json = cfg.json or {}
    local keys = json.keys or {}
    local cmd = notEmpty(json.commandTopic)
    caps.hasLevel = cmd and notEmpty(tilt and keys.tilt or keys.position)
    caps.canOpenClose = cmd and (notEmpty(keys.state) or caps.hasLevel)
    caps.canStop = cmd and notEmpty(keys.state) and notEmpty(cfg.payloadStop)
  else
    local t = cfg.topics or {}
    caps.hasLevel = topic(tilt and t.tilt or t.position) ~= ""
    caps.canOpenClose = (topic(t.open) ~= "" and topic(t.close) ~= "") or caps.hasLevel
    caps.canStop = topic(t.stop) ~= ""
  end
  caps.tilt = tilt
  return caps
end

--- Topics to subscribe to.
function Shutter:subscriptions()
  local set, list = {}, {}
  local function add(t)
    t = trim(t)
    if t ~= "" and not set[t] then
      set[t] = true
      list[#list + 1] = t
    end
  end
  if self:isShelly() then
    local sh = self:_shelly()
    if sh then
      add(sh.prefix .. "/status/" .. sh.key)
      add(sh.prefix .. "/events/rpc")
      add(sh.src .. "/rpc")
    end
  elseif self:isJson() then
    add((self.cfg.json or {}).stateTopic)
  else
    local t = self.cfg.topics or {}
    add((t.position or {}).stateTopic)
    add((t.state or {}).stateTopic)
    add((t.tilt or {}).stateTopic)
    add((t.target or {}).stateTopic)
  end
  table.sort(list)
  return list
end

function Shutter:hasStateFeedback()
  return #self:subscriptions() > 0
end

function Shutter:isOptimistic()
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

function Shutter:_notify(command, params)
  log:trace("shutter notify %s %s", command, params)
  SendToProxy(self.proxyBinding, command, params or {}, "NOTIFY", true)
end

function Shutter:_timer(name)
  return self.timerPrefix .. "_" .. name
end

function Shutter:levelOpen()
  return self.caps.hasLevel and 100 or DISCRETE_OPEN
end

function Shutter:levelClosed()
  return self.caps.hasLevel and 0 or DISCRETE_CLOSED
end

--- Tell the proxy what the shutter can do (at start-up and when it changes).
function Shutter:sendCapabilities()
  self:_notify("SET_CAN_STOP", { CAN_STOP = self.caps.canStop and true or false })
  self:_notify("SET_HAS_LEVEL", {
    HAS_LEVEL = true,
    LEVEL_OPEN = self:levelOpen(),
    LEVEL_CLOSED = self:levelClosed(),
    LEVEL_SECONDARY_CLOSED = "",
    LEVEL_UNKNOWN = -1,
    LEVEL_DISCRETE_CONTROL = self.caps.hasLevel and true or false,
    HAS_LEVEL_SECONDARY_CLOSED = false,
  })
end

--- Resend capabilities and the last level.
function Shutter:refreshProxy()
  self:sendCapabilities()
  if self.level ~= nil then
    self:_notify("STOPPED", { LEVEL = self.level })
  end
end

function Shutter:_stateChanged()
  if self.onStateChanged then
    self.onStateChanged(self)
  end
end

--- The proxy level the device is at, from what it reported.
function Shutter:deviceLevel()
  local d = self.device
  local value = self:isTilt() and d.tilt or d.position
  if value == nil then
    return nil
  end
  if self.caps.hasLevel then
    return clamp(round(value), 0, 100)
  end
  if value >= 99 then
    return DISCRETE_OPEN
  elseif value <= 1 then
    return DISCRETE_CLOSED
  end
  return DISCRETE_STOP
end

--- Estimated time (ms) to go from one level to another.
function Shutter:rampTime(from, to)
  local full = (tonumber(self:isTilt() and self.cfg.tiltTime or self.cfg.travelTime) or (self:isTilt() and 2 or 20))
    * 1000
  if not self.caps.hasLevel then
    return round(full)
  end
  if from == nil then
    return round(full)
  end
  return round(full * math.abs((tonumber(to) or 0) - from) / 100)
end

--- A move started: tell the proxy once per target.
function Shutter:_startMoving(target)
  local from = self.level or self:deviceLevel()
  local rate = self:rampTime(from, target)
  if self.moving and self.moving.target == target then
    return
  end
  self.moving = { target = target, started = self.now(), rate = rate }
  self:_notify("MOVING", { LEVEL_TARGET = target, RAMP_RATE = rate })
  -- If the device never says it stopped, finish when it should have arrived.
  SetTimer(self:_timer("Finish"), rate + FINISH_MARGIN_MS, function()
    self:_finish()
  end)
  self:_stateChanged()
end

--- The move ended (or the device reported a position at rest).
function Shutter:_finish(level)
  CancelTimer(self:_timer("Finish"))
  local target = self.moving and self.moving.target
  self.moving = nil
  level = level or self:deviceLevel()
  if level == nil and self:isOptimistic() then
    level = target
  end
  if level == nil then
    level = target
  end
  if level == nil then
    return
  end
  self.level = level
  self:_notify("STOPPED", { LEVEL = level })
  self:_stateChanged()
end

-------------------------------------------------------------------------------
-- Device -> Control4
-------------------------------------------------------------------------------

--- Apply what the device reported: { position?, tilt?, movement?, target?, posControl? }
function Shutter:_apply(u)
  local d = self.device
  local capsBefore = self.caps.hasLevel
  for k, v in pairs(u) do
    d[k] = v
  end
  if u.posControl ~= nil then
    self.caps = self:computeCapabilities()
  end
  if capsBefore ~= self.caps.hasLevel then
    log:info("Shutter positioning %s", self.caps.hasLevel and "available" or "not available (not calibrated?)")
    self:sendCapabilities()
  end

  local movement = d.movement
  if movement == Shutter.OPENING or movement == Shutter.CLOSING then
    local target = self.moving and self.moving.target
    if d.target ~= nil and not self:isTilt() then
      target = self.caps.hasLevel and clamp(round(d.target), 0, 100) or nil
    end
    if target == nil then
      target = movement == Shutter.OPENING and self:levelOpen() or self:levelClosed()
    end
    self:_startMoving(target)
  elseif movement == Shutter.STOPPED or movement == nil then
    local level = self:deviceLevel()
    if level == nil then
      return
    end
    if self.moving and movement == nil then
      -- No movement reported: done when the position reaches the target.
      if math.abs(level - self.moving.target) <= 1 then
        self:_finish(level)
      end
      return
    end
    if self.moving or level ~= self.level then
      self:_finish(level)
    end
  end
end

--- Handle an MQTT message; true when it belongs to this shutter.
function Shutter:onMessage(topicName, payload)
  topicName = trim(topicName)
  if self:isShelly() then
    local st = self:_shellyStatusFrom(topicName, payload)
    if st == false then
      return false
    end
    if st ~= nil then
      self:_apply(self:_shellyUpdate(st))
    end
    return true
  end

  local u, handled = {}, false
  if self:isJson() then
    local json = self.cfg.json or {}
    if trim(json.stateTopic) ~= topicName or topicName == "" then
      return false
    end
    handled = true
    local t = decodeJson(payload)
    if t == nil then
      return true
    end
    local keys = json.keys or {}
    local function key(k)
      if not notEmpty(k) then
        return nil
      end
      k = trim(k)
      if k:sub(1, 1) == "$" then
        return stateParser.extractJsonPath(t, k)
      end
      return t[k]
    end
    local state = key(keys.state)
    u.position = tonumber(key(keys.position))
    if u.position == nil and not notEmpty(keys.position) then
      u.position = Shutter.parseEndpoint(state)
    end
    u.tilt = tonumber(key(keys.tilt))
    u.movement = Shutter.parseMovement(key(keys.moving)) or self:_stateMovement(state)
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
    local state = feature("state")
    u.position = tonumber(feature("position"))
    if u.position == nil and trim((topics.position or {}).stateTopic) == "" then
      u.position = Shutter.parseEndpoint(state)
    end
    u.tilt = tonumber(feature("tilt"))
    u.movement = Shutter.parseMovement(state)
    u.target = tonumber(feature("target"))
  end
  if not handled then
    return false
  end
  if u.position ~= nil then
    u.position = self:_fromDevicePosition(u.position)
  end
  if u.target ~= nil then
    u.target = self:_fromDevicePosition(u.target)
  end
  if u.tilt ~= nil then
    u.tilt = self:_fromDeviceTilt(u.tilt)
  end
  self:_apply(u)
  return true
end

--- A JSON "state" key: OPEN/CLOSE/STOP style values are not movements; only
--- opening/closing/stopped are.
function Shutter:_stateMovement(value)
  if value == nil then
    return nil
  end
  local s = trim(value):lower()
  if s == "opening" or s == "closing" or s == "stopped" then
    return Shutter.parseMovement(s)
  end
  return nil
end

function Shutter:_fromDevicePosition(v)
  v = clamp(tonumber(v) or 0, 0, 100)
  if self.cfg.invert then
    v = 100 - v
  end
  return v
end

function Shutter:_toDevicePosition(v)
  v = clamp(round(v), 0, 100)
  if self.cfg.invert then
    v = 100 - v
  end
  return v
end

--- Tilt in device units (Tilt Min .. Tilt Max) to 0-100.
function Shutter:_fromDeviceTilt(v)
  local lo, hi = tonumber(self.cfg.tiltMin) or 0, tonumber(self.cfg.tiltMax) or 100
  if hi == lo then
    return nil
  end
  return clamp((tonumber(v) - lo) / (hi - lo) * 100, 0, 100)
end

function Shutter:_toDeviceTilt(level)
  local lo, hi = tonumber(self.cfg.tiltMin) or 0, tonumber(self.cfg.tiltMax) or 100
  return round(lo + (hi - lo) * clamp(level, 0, 100) / 100)
end

--- The cover status in a Shelly message (see MqttLight for the same pattern).
--- @return table|nil|false
function Shutter:_shellyStatusFrom(topicName, payload)
  local sh = self:_shelly()
  if sh == nil then
    return false
  end
  local statusTopic, eventTopic, replyTopic =
    sh.prefix .. "/status/" .. sh.key, sh.prefix .. "/events/rpc", sh.src .. "/rpc"
  if topicName ~= statusTopic and topicName ~= eventTopic and topicName ~= replyTopic then
    return false
  end
  local t = decodeJson(payload)
  if t == nil then
    return nil
  end
  local status
  if topicName == statusTopic then
    status = t
  elseif topicName == eventTopic then
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
  -- A full status replaces what was kept; NotifyStatus carries only changes.
  if topicName ~= eventTopic then
    self.shellyStatus = {}
  end
  for k, v in pairs(status) do
    self.shellyStatus[k] = v
  end
  return self.shellyStatus
end

function Shutter:_shellyUpdate(st)
  local u = {}
  u.position = st.pos_control ~= false and tonumber(st.current_pos) or nil
  if u.position == nil then
    -- Not calibrated: only the end positions are known.
    u.position = Shutter.parseEndpoint(st.state)
    if u.position == nil and st.state == "stopped" and st.pos_control == false then
      u.position = 50
    end
  end
  u.target = tonumber(st.target_pos)
  if type(st.slat_pos) == "number" then
    u.tilt = clamp(st.slat_pos, 0, 100)
  end
  u.movement = Shutter.parseMovement(st.state)
  if type(st.pos_control) == "boolean" then
    u.posControl = st.pos_control
  end
  return u
end

-------------------------------------------------------------------------------
-- Control4 -> device
-------------------------------------------------------------------------------

function Shutter:_publish(topicName, payload)
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

function Shutter:_rpc(method, params)
  local sh = self:_shelly()
  if sh == nil then
    log:warn("Shelly Topic Prefix and Shelly Component must be filled in")
    return false
  end
  params.id = sh.index
  self.rpcId = (self.rpcId or 0) % 1000000 + 1
  return self:_publish(
    sh.prefix .. "/rpc",
    JSON:encode({ id = self.rpcId, src = sh.src, method = method, params = params })
  )
end

--- Send one action to the device: "open", "close", "stop" or "level" (0-100).
--- @return boolean sent
function Shutter:_send(action, level)
  local tilt = self:isTilt()
  if self:isShelly() then
    if action == "stop" then
      return self:_rpc("Cover.Stop", {})
    elseif tilt then
      local slat = action == "open" and 100 or (action == "close" and 0 or clamp(round(level), 0, 100))
      return self:_rpc("Cover.GoToPosition", { slat_pos = slat })
    elseif action == "open" then
      return self:_rpc("Cover.Open", {})
    elseif action == "close" then
      return self:_rpc("Cover.Close", {})
    end
    return self:_rpc("Cover.GoToPosition", { pos = self:_toDevicePosition(level) })
  end

  if self:isJson() then
    local json = self.cfg.json or {}
    local keys = json.keys or {}
    local obj = {}
    if action == "stop" then
      obj[trim(keys.state)] = self.cfg.payloadStop
    elseif tilt then
      local l = action == "open" and 100 or (action == "close" and 0 or level)
      obj[trim(keys.tilt)] = self:_toDeviceTilt(l)
    elseif (action == "open" or action == "close") and notEmpty(keys.state) then
      obj[trim(keys.state)] = action == "open" and self.cfg.payloadOpen or self.cfg.payloadClose
    else
      local l = action == "open" and 100 or (action == "close" and 0 or level)
      obj[trim(keys.position)] = self:_toDevicePosition(l)
    end
    if next(obj) == nil then
      return false
    end
    return self:_publish(json.commandTopic, JSON:encode(obj))
  end

  local t = self.cfg.topics or {}
  if action == "stop" then
    return self:_publish(topic(t.stop), (t.stop or {}).payload)
  end
  if tilt then
    local l = action == "open" and 100 or (action == "close" and 0 or level)
    return self:_publish(topic(t.tilt), self:_toDeviceTilt(l))
  end
  if action == "open" and topic(t.open) ~= "" then
    return self:_publish(topic(t.open), (t.open or {}).payload)
  elseif action == "close" and topic(t.close) ~= "" then
    return self:_publish(topic(t.close), (t.close or {}).payload)
  end
  local l = action == "open" and 100 or (action == "close" and 0 or level)
  return self:_publish(topic(t.position), self:_toDevicePosition(l))
end

--- Move to a proxy level (SET_LEVEL_TARGET).
function Shutter:setLevel(target)
  target = tonumber(target)
  if target == nil then
    return
  end
  if not self.caps.hasLevel then
    if target >= DISCRETE_OPEN then
      return self:open()
    elseif target <= DISCRETE_CLOSED then
      return self:close()
    end
    return self:stop()
  end
  target = clamp(round(target), 0, 100)
  local action = "level"
  -- Fully open or closed: use the device's own open/close (end stops) when it has them.
  if target == 100 and self.caps.canOpenClose then
    action = "open"
  elseif target == 0 and self.caps.canOpenClose then
    action = "close"
  end
  if self:_send(action, target) then
    self:_commanded(target)
  end
end

function Shutter:open()
  if self:_send("open", 100) then
    self:_commanded(self:levelOpen())
  end
end

function Shutter:close()
  if self:_send("close", 0) then
    self:_commanded(self:levelClosed())
  end
end

function Shutter:stop()
  if not self:_send("stop") then
    return
  end
  CancelTimer(self:_timer("Finish"))
  if self:isOptimistic() or not self:hasStateFeedback() then
    -- Where it stopped is not known: estimate from the time it ran.
    local m = self.moving
    local level = self.level
    if m and self.caps.hasLevel and self.level ~= nil and m.rate > 0 then
      local f = clamp((self.now() - m.started) / m.rate, 0, 1)
      level = round(self.level + (m.target - self.level) * f)
    elseif not self.caps.hasLevel then
      level = DISCRETE_STOP
    end
    self.moving = nil
    self:_finish(level)
  end
end

--- Open when closed (or closing), else close; stop when moving.
function Shutter:toggle()
  if self.moving then
    return self:stop()
  end
  local level = self.level or self:deviceLevel()
  if level == nil or level <= self:levelClosed() then
    return self:open()
  end
  return self:close()
end

--- After a command: the proxy hears MOVING now; optimistic shutters arrive on time.
function Shutter:_commanded(target)
  self.moving = nil
  self:_startMoving(target)
  if self:isOptimistic() then
    SetTimer(self:_timer("Finish"), self.moving.rate, function()
      self.device[self:isTilt() and "tilt" or "position"] = self.caps.hasLevel and target
        or (target >= DISCRETE_OPEN and 100 or 0)
      self:_finish(target)
    end)
  end
end

--- Commands from the blind proxy.
function Shutter:handleProxyCommand(command, params)
  params = params or {}
  if command == "SET_LEVEL_TARGET" then
    self:setLevel(params.LEVEL_TARGET)
  elseif command == "STOP" then
    self:stop()
  elseif command == "UP" or command == "OPEN" then
    self:open()
  elseif command == "DOWN" or command == "CLOSE" then
    self:close()
  elseif command == "TOGGLE" then
    self:toggle()
  else
    return false
  end
  return true
end

--- Whether the shutter is open at all (for keypad LEDs).
function Shutter:isOpen()
  local level = self.level
  if level == nil then
    return false
  end
  return level > self:levelClosed()
end

function Shutter:stateText()
  if self.moving then
    return string.format("Moving to %d", self.moving.target)
  end
  if self.level == nil then
    return "Unknown"
  end
  if not self.caps.hasLevel then
    return self.level >= DISCRETE_OPEN and "Open" or (self.level <= DISCRETE_CLOSED and "Closed" or "Stopped")
  end
  return string.format("%d%%", self.level)
end

return Shutter
