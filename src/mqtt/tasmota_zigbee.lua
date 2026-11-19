--- Zigbee devices behind a Tasmota Zigbee gateway.
---
--- A gateway is an ordinary Tasmota (found through Tasmota discovery) that
--- answers ZbStatus1 with the list of its paired devices. ZbStatus3 <device>
--- then gives one device in full:
---
---   {"ZbStatus3":[{"Device":"0xE53A","Name":"spot1","IEEEAddr":"0xA4C1...",
---     "ModelId":"TS0502B","Manufacturer":"_TZ3210_a046u4au","Endpoints":[1,242],
---     "Config":["~01.1","O01","L01"],"ColorMode":2,...}]}
---
--- Config lists what Tasmota knows of the device: "~01.N" a light on endpoint 1
--- of type N (0 on/off, 1 dimmer, 2 white with color temperature, 3 RGB,
--- 4 RGBW, 5 RGB with color temperature), "O01" On/Off and "L01" Level (brightness)
--- on endpoint 1, "T01" temperature and so on.
---
--- Devices report on tele/<gateway>/SENSOR wrapped in ZbReceived, or with
--- SetOption89 1 on tele/<gateway>/<short address>/SENSOR (the friendly name in
--- place of the address with SetOption112 1). The key inside ZbReceived is the
--- short address ("0xE53A"), or the friendly name with SetOption83 1. Which one
--- a gateway uses is learnt from its messages; until then SetOption89 1 is
--- assumed. Commands go to cmnd/<gateway>/ZbSend naming the device by its IEEE
--- address, which never changes.

local Tasmota = require("mqtt.tasmota")

local Zigbee = {}

Zigbee.TYPE = "zigbee"

--- Tasmota light types (ZbLight) and what each can do.
Zigbee.LIGHT_TYPES = {
  [0] = { label = "Switch", dimmer = false, ct = false, color = false },
  [1] = { label = "Dimmer", dimmer = true, ct = false, color = false },
  [2] = { label = "White light", dimmer = true, ct = true, color = false },
  [3] = { label = "RGB light", dimmer = true, ct = false, color = true },
  [4] = { label = "RGBW light", dimmer = true, ct = false, color = true },
  [5] = { label = "RGB and white light", dimmer = true, ct = true, color = true },
}

--- ZCL ColorMode attribute: 0 hue/saturation, 1 xy, 2 color temperature.
local COLOR_MODE_CT = 2

local function str(v)
  if type(v) == "string" then
    return v
  end
  if type(v) == "number" then
    return tostring(v)
  end
  return nil
end

local function decode(payload)
  if type(payload) ~= "string" or payload == "" then
    return nil
  end
  local ok, t = pcall(JSON.decode, JSON, payload)
  if ok and type(t) == "table" then
    return t
  end
  return nil
end

--- A short address as Tasmota writes it: "0xE53A".
--- @param v any
--- @return string|nil
function Zigbee.shortAddress(v)
  local s = str(v)
  if s == nil then
    return nil
  end
  local hex = s:match("^0[xX](%x+)$") or s:match("^(%x%x%x%x)$")
  if hex == nil or #hex > 4 then
    return nil
  end
  return "0x" .. string.rep("0", 4 - #hex) .. hex:upper()
end

--- The parts of a Tasmota gateway a Zigbee device needs.
--- @param gw table parsed Tasmota device (mqtt.tasmota)
--- @return table
function Zigbee.gatewayInfo(gw)
  return {
    mac = gw.mac,
    name = gw.name,
    topic = gw.topic,
    hostname = gw.hostname,
    fullTopic = gw.fullTopic,
    prefixes = gw.prefixes,
    online = gw.online,
    offline = gw.offline,
  }
end

--- The topic that asks a Tasmota for its Zigbee devices.
function Zigbee.listTopic(gw)
  return Tasmota.topicFor(gw, 1, "ZbStatus1")
end

--- The topic one device's details are asked on (payload: its address).
function Zigbee.detailTopic(gw)
  return Tasmota.topicFor(gw, 1, "ZbStatus3")
end

--- Where a gateway answers commands.
function Zigbee.resultTopic(gw)
  return Tasmota.topicFor(gw, 2, "RESULT")
end

--- The gateway's own sensor topic (all devices without SetOption89).
function Zigbee.sensorTopic(gw)
  return Tasmota.topicFor(gw, 3, "SENSOR")
end

--- Topic filter for per-device sensor topics (SetOption89 1).
function Zigbee.deviceSensorFilter(gw)
  return Tasmota.topicFor(gw, 3, "+/SENSOR")
end

--- Read an answer on stat/<gateway>/RESULT.
--- @param payload string
--- @return table|nil { kind = "list", devices = { {short, name} } } or { kind = "detail", devices = {...} }
function Zigbee.parseResult(payload)
  local t = decode(payload)
  if t == nil then
    return nil
  end
  if type(t.ZbStatus1) == "table" then
    local out = {}
    for _, d in ipairs(t.ZbStatus1) do
      local short = type(d) == "table" and Zigbee.shortAddress(d.Device) or nil
      if short ~= nil then
        out[#out + 1] = { short = short, name = str(d.Name) }
      end
    end
    return { kind = "list", devices = out }
  end
  local detail = t.ZbStatus3 or t.ZbStatus2
  if type(detail) == "table" then
    local out = {}
    for _, d in ipairs(detail) do
      if type(d) == "table" and Zigbee.shortAddress(d.Device) ~= nil then
        out[#out + 1] = d
      end
    end
    return { kind = "detail", devices = out }
  end
  return nil
end

--- Read the Config list of a ZbStatus3 answer.
--- @return table { light = {endpoint, type}|nil, clusters = { O = endpoint, L = endpoint, ... } }
local function parseConfig(config)
  local out = { clusters = {} }
  for _, c in ipairs(type(config) == "table" and config or {}) do
    if type(c) == "string" then
      local ep, lt = c:match("^~(%x%x)%.(%d+)$")
      if ep ~= nil then
        out.light = { endpoint = tonumber(ep, 16), type = tonumber(lt) }
      else
        local letter, cep = c:match("^(%a)(%x%x)$")
        if letter ~= nil and out.clusters[letter] == nil then
          out.clusters[letter] = tonumber(cep, 16)
        end
      end
    end
  end
  return out
end

--- One device from its ZbStatus3 entry.
--- @param gw table gateway (Zigbee.gatewayInfo or a parsed Tasmota device)
--- @param d table one ZbStatus3 entry
--- @param old table|nil the device as known before (keeps what was learnt)
--- @return table|nil device
function Zigbee.build(gw, d, old)
  local short = Zigbee.shortAddress(d.Device)
  if short == nil then
    return nil
  end
  local ieee = str(d.IEEEAddr)
  if ieee == nil or not ieee:match("^0[xX]%x+$") then
    return nil
  end
  ieee = "0x" .. ieee:sub(3):upper()
  local cfg = parseConfig(d.Config)
  local name = str(d.Name)
  if name ~= nil and not name:match("%S") then
    name = nil
  end
  local dev = {
    type = Zigbee.TYPE,
    mac = ieee,
    ieee = ieee,
    short = short,
    name = name or short,
    named = name ~= nil,
    topic = gw.topic,
    gateway = Zigbee.gatewayInfo(gw),
    model = str(d.ModelId),
    manufacturer = str(d.Manufacturer),
    light = cfg.light,
    clusters = cfg.clusters,
    colorMode = tonumber(d.ColorMode),
  }
  if old ~= nil and old.short == short then
    dev.stateTopic = old.stateTopic
    dev.stateKey = old.stateKey
  end
  return dev
end

--- The light type Tasmota has for the device, raised to what the device
--- shows it can do (a light set as a dimmer that reports color temperature
--- mode is a white light).
--- @return integer|nil type (see Zigbee.LIGHT_TYPES), nil when not a light
--- @return integer|nil configured the type Tasmota has, when it differs
function Zigbee.lightType(dev)
  local configured = dev.light and dev.light.type or nil
  local t = configured
  if t == nil or Zigbee.LIGHT_TYPES[t] == nil then
    local c = dev.clusters or {}
    if c.L ~= nil then
      t = 1
    elseif c.O ~= nil then
      t = 0
    else
      return nil, nil
    end
    configured = nil
  end
  if dev.colorMode == COLOR_MODE_CT and not Zigbee.LIGHT_TYPES[t].ct then
    t = t >= 3 and 5 or 2
  end
  return t, (configured ~= nil and configured ~= t) and configured or nil
end

--- The device as a Control4 light: at most one output, "light".
--- @return table[] loads { id, label, power, dimmer, ct, color }
function Zigbee.loads(dev)
  local t = Zigbee.lightType(dev)
  if t == nil then
    return {}
  end
  local info = Zigbee.LIGHT_TYPES[t]
  return {
    {
      id = "light",
      kind = "light",
      label = info.label,
      power = true,
      dimmer = info.dimmer,
      ct = info.ct,
      color = info.color,
    },
  }
end

function Zigbee.load(dev, loadId)
  for _, l in ipairs(Zigbee.loads(dev)) do
    if l.id == loadId then
      return l
    end
  end
  return nil
end

--- A Control4 name: the friendly name, or the model and address.
function Zigbee.loadName(dev, loadId)
  if Zigbee.load(dev, loadId) == nil then
    return nil
  end
  if dev.named then
    return dev.name
  end
  return string.format("%s %s", dev.model or "Zigbee light", dev.short)
end

--- Where the device's state arrives, and its key inside ZbReceived.
--- Learnt from the device's messages; until then SetOption89 1 is assumed.
--- @return string topic, string key
function Zigbee.state(dev)
  if dev.stateTopic ~= nil and dev.stateKey ~= nil then
    return dev.stateTopic, dev.stateKey
  end
  local gw = dev.gateway or {}
  local style = gw.style or {}
  local topic
  if style.gatewayTopic then
    topic = Zigbee.sensorTopic(gw)
  else
    local segment = (style.nameInTopic and dev.named) and dev.name or dev.short:sub(3)
    topic = Tasmota.topicFor(gw, 3, segment .. "/SENSOR")
  end
  local key = (style.nameAsKey and dev.named) and dev.name or dev.short
  return topic, key
end

--- What a ZbReceived message says about the gateway's options.
--- @param gw table
--- @param topic string the message's topic
--- @param key string the key inside ZbReceived
--- @param dev table the device the entry is for
--- @return table style { gatewayTopic, nameInTopic, nameAsKey }
function Zigbee.styleFrom(gw, topic, key, dev)
  local style = {}
  if topic == Zigbee.sensorTopic(gw) then
    style.gatewayTopic = true
  else
    local segment = topic:match("([^/]+)/SENSOR$")
    style.nameInTopic = dev.named and segment == dev.name and segment ~= dev.short:sub(3) or nil
  end
  style.nameAsKey = (dev.named and key == dev.name and Zigbee.shortAddress(key) == nil) or nil
  return style
end

--- The entries of a ZbReceived message.
--- @return table|nil { key -> entry }
function Zigbee.parseReceived(payload)
  local t = decode(payload)
  if t == nil or type(t.ZbReceived) ~= "table" then
    return nil
  end
  return t.ZbReceived
end

--- Things on the gateway or the device that should change for the light to
--- work well.
--- @return string[]
function Zigbee.notes(dev)
  local notes = {}
  local t, configured = Zigbee.lightType(dev)
  if configured ~= nil then
    notes[#notes + 1] = string.format(
      "Tasmota has this light as type %d (%s) but it reports color temperature. Run ZbLight %s,%d on the gateway.",
      configured,
      Zigbee.LIGHT_TYPES[configured] and Zigbee.LIGHT_TYPES[configured].label or "?",
      dev.named and dev.name or dev.short,
      t
    )
  end
  if t ~= nil and Zigbee.LIGHT_TYPES[t].color then
    notes[#notes + 1] = "Color is not controlled through the Zigbee gateway yet: on/off, brightness"
      .. (Zigbee.LIGHT_TYPES[t].ct and " and color temperature" or "")
      .. " are."
  end
  if not dev.named then
    notes[#notes + 1] = string.format("The device has no name; give it one with ZbName %s,<name>.", dev.short)
  end
  if dev.stateTopic == nil then
    notes[#notes + 1] =
      "The state topic is a guess until the device reports; it assumes SetOption89 1 (a topic per device)."
  end
  return notes
end

--- Compact entry for lists sent to child drivers.
function Zigbee.summary(dev)
  local loads = {}
  for _, l in ipairs(Zigbee.loads(dev)) do
    loads[#loads + 1] = { id = l.id, label = l.label }
  end
  return {
    type = Zigbee.TYPE,
    mac = dev.mac,
    topic = dev.topic,
    name = dev.name,
    model = dev.model,
    loads = loads,
    buttons = 0,
  }
end

--- MQTT Light properties for the device.
--- @return table|nil props, string|nil error
function Zigbee.lightProperties(dev, loadId)
  local load = Zigbee.load(dev, loadId)
  if load == nil then
    return nil, "not a light: " .. tostring(dev.name)
  end
  local gw = dev.gateway or {}
  local stateTopic, key = Zigbee.state(dev)
  local send = Tasmota.topicFor(gw, 1, "ZbSend")
  local function feature(prefix, enabled, attribute)
    local p = {}
    p[prefix .. " State Topic"] = enabled and stateTopic or ""
    p[prefix .. " Value Path"] = enabled and string.format("$.ZbReceived['%s'].%s", key, attribute) or ""
    p[prefix .. " Command Topic"] = enabled and send or ""
    p[prefix .. " Command Payload"] = enabled
        and string.format('{"Device":"%s","Send":{"%s":{value}}}', dev.ieee, attribute)
      or ""
    return p
  end
  local props = {
    ["Payload Mode"] = "Separate Topics",
    -- Reading On/Off: the answer arrives as ZbReceived on the state topic.
    ["State Request Topic"] = send,
    ["State Request Payload"] = string.format('{"Device":"%s","Cluster":"0x0006","Read":"0x0000"}', dev.ieee),
    ["Availability Topic"] = Tasmota.topicFor(gw, 3, "LWT"),
    ["Availability Value Path"] = "",
    ["Payload Available"] = gw.online or "Online",
    ["Payload Not Available"] = gw.offline or "Offline",
    ["State On"] = "1",
    ["State Off"] = "0",
    ["Payload On"] = "1",
    ["Payload Off"] = "0",
    ["Brightness Scale Max"] = "254",
  }
  local function merge(t)
    for k, v in pairs(t) do
      props[k] = v
    end
  end
  merge(feature("Power", true, "Power"))
  merge(feature("Brightness", load.dimmer, "Dimmer"))
  merge(feature("Color Temp", load.ct, "CT"))
  merge(feature("Color", false, ""))
  merge(feature("White", false, ""))
  if load.ct then
    props["Color Temp Unit"] = "Mireds"
    props["Color Temp Min"] = "2000"
    props["Color Temp Max"] = "6500"
  end
  return props
end

return Zigbee
