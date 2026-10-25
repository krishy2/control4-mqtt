--- @module "mqtt.shelly"
--- Shelly Gen2+ (Plus, Pro, Gen3, Gen4) discovery over MQTT, and the MQTT
--- Light settings that follow from it.
---
--- A Gen2+ device publishes `<prefix>/online` = true when it connects (false
--- as its last will). Sent `announce` on `shellies/command` or
--- `<prefix>/command`, it publishes its device info (Shelly.GetDeviceInfo) to
--- `shellies/announce` and `<prefix>/announce`; the second gives its topic
--- prefix. Its outputs come from Shelly.GetConfig, asked for over RPC:
---
---   request  <prefix>/rpc   {"id":1,"src":"control4/shelly","method":"Shelly.GetConfig"}
---   answer   control4/shelly/rpc   {"id":1,"src":"<device id>","dst":"control4/shelly","result":{...}}
---
--- The light then controls one output with <Type>.Set over the same RPC
--- channel, and follows it through NotifyStatus on `<prefix>/events/rpc`,
--- `<prefix>/status/<type>:<n>` (when "Generic status update over MQTT" is on)
--- and the answers to <Type>.GetStatus.
---
--- Gen1 devices are not supported.
---
--- Pure Lua: no Control4 calls.

local Shelly = {}

Shelly.BROADCAST_TOPIC = "shellies/command"
Shelly.DISCOVERY_SRC = "control4/shelly"
Shelly.DISCOVERY_REPLY_TOPIC = Shelly.DISCOVERY_SRC .. "/rpc"
--- Subscriptions for an external broker: announces and online messages for
--- prefixes of one or two levels (the default prefix is the device ID).
Shelly.EXTERNAL_FILTERS = { "+/announce", "+/+/announce", "+/online", "+/+/online", Shelly.DISCOVERY_REPLY_TOPIC }

--- Component types the light can use, in list order.
Shelly.TYPES = { "light", "cct", "rgb", "rgbw", "switch" }
local TYPE_ORDER = { light = 1, cct = 2, rgb = 3, rgbw = 4, switch = 5 }

--- RPC method prefix per type.
Shelly.METHODS = { light = "Light", cct = "CCT", rgb = "RGB", rgbw = "RGBW", switch = "Switch" }

local TYPE_LABELS = { light = "Dimmer", cct = "CCT light", rgb = "RGB light", rgbw = "RGBW light", switch = "Relay" }

Shelly.DEFAULT_CT_MIN = 2700
Shelly.DEFAULT_CT_MAX = 6500

local function decode(payload)
  if type(payload) == "table" then
    return payload
  end
  if type(payload) ~= "string" or payload == "" then
    return nil
  end
  local ok, t = pcall(JSON.decode, JSON, payload)
  if ok and type(t) == "table" then
    return t
  end
  return nil
end

local function text(v)
  if type(v) ~= "string" then
    return nil
  end
  v = v:match("^%s*(.-)%s*$")
  return v ~= "" and v or nil
end

--- The topic prefix from an announce or online topic, or nil.
--- @param topic string
--- @param suffix string "announce" or "online"
--- @return string|nil
function Shelly.prefixFrom(topic, suffix)
  if type(topic) ~= "string" then
    return nil
  end
  local prefix = topic:match("^(.+)/" .. suffix .. "$")
  if prefix == nil or prefix == "shellies" then
    return nil
  end
  return prefix
end

--- A Gen2+ announce: the device info, or nil for anything else (Gen1, other devices).
--- @param payload string|table
--- @return table|nil { id, mac, model, gen, app, ver, name }
function Shelly.parseAnnounce(payload)
  local t = decode(payload)
  if t == nil then
    return nil
  end
  local gen = tonumber(t.gen)
  local id = text(t.id)
  if gen == nil or gen < 2 or id == nil then
    return nil
  end
  local mac = (text(t.mac) or ""):gsub("[^%x]", ""):upper()
  if mac == "" then
    return nil
  end
  return {
    id = id,
    mac = mac,
    model = text(t.model) or "",
    gen = gen,
    app = text(t.app) or "",
    ver = text(t.ver) or "",
    name = text(t.name),
    profile = text(t.profile),
  }
end

--- The RPC request for a device's configuration.
--- @param rpcId integer
--- @return string
function Shelly.configRequest(rpcId)
  return JSON:encode({ id = rpcId, src = Shelly.DISCOVERY_SRC, method = "Shelly.GetConfig" })
end

--- An RPC answer on the discovery reply topic.
--- @param payload string|table
--- @return table|nil { id, src, result?, error? }
function Shelly.parseReply(payload)
  local t = decode(payload)
  if t == nil or text(t.src) == nil then
    return nil
  end
  return { id = tonumber(t.id), src = t.src, result = t.result, error = t.error }
end

--- Build the device record from its announce and its configuration.
--- @param info table from parseAnnounce
--- @param prefix string topic prefix
--- @param config table Shelly.GetConfig result
--- @return table device
function Shelly.build(info, prefix, config)
  local components = {}
  for key, cfg in pairs(type(config) == "table" and config or {}) do
    local kind, index = tostring(key):match("^(%a+):(%d+)$")
    if kind and TYPE_ORDER[kind] then
      local c = { key = key, type = kind, index = tonumber(index), name = text(type(cfg) == "table" and cfg.name) }
      if kind == "cct" and type(cfg) == "table" and type(cfg.ct_range) == "table" then
        c.ctMin, c.ctMax = tonumber(cfg.ct_range[1]), tonumber(cfg.ct_range[2])
      end
      components[#components + 1] = c
    end
  end
  table.sort(components, function(a, b)
    if a.type ~= b.type then
      return TYPE_ORDER[a.type] < TYPE_ORDER[b.type]
    end
    return a.index < b.index
  end)
  local sys = type(config) == "table" and type(config.sys) == "table" and config.sys or {}
  local device = type(sys.device) == "table" and sys.device or {}
  return {
    type = "shelly",
    mac = info.mac,
    id = info.id,
    topic = prefix,
    name = text(device.name) or info.name or info.id,
    model = info.model,
    app = info.app,
    gen = info.gen,
    version = info.ver,
    profile = info.profile,
    ip = "",
    components = components,
  }
end

--- The outputs a light can use, in the same shape as Tasmota.loads.
--- @param dev table
--- @return table[] { id, kind, index, label, name? }
function Shelly.loads(dev)
  local counts = {}
  for _, c in ipairs(dev.components or {}) do
    counts[c.type] = (counts[c.type] or 0) + 1
  end
  local loads = {}
  for _, c in ipairs(dev.components or {}) do
    local label = TYPE_LABELS[c.type] or c.type
    if counts[c.type] > 1 then
      label = string.format("%s %d", label, c.index + 1)
    end
    if c.name and c.name ~= dev.name then
      label = string.format("%s '%s'", label, c.name)
    end
    loads[#loads + 1] = { id = c.key, kind = c.type, index = c.index, label = label, name = c.name }
  end
  return loads
end

--- The component with this key, or nil.
function Shelly.component(dev, key)
  for _, c in ipairs(dev.components or {}) do
    if c.key == key then
      return c
    end
  end
  return nil
end

--- Compact entry for lists sent to child drivers.
function Shelly.summary(dev)
  local loads = {}
  for _, l in ipairs(Shelly.loads(dev)) do
    loads[#loads + 1] = { id = l.id, label = l.label }
  end
  return { type = "shelly", mac = dev.mac, topic = dev.topic, name = dev.name, ip = dev.ip, loads = loads }
end

--- Where a light's state requests are answered: <src>/rpc.
--- @param prefix string
--- @param key string component key, e.g. "light:0"
--- @return string src
function Shelly.lightSrc(prefix, key)
  return "control4/" .. tostring(prefix) .. "/" .. tostring(key):gsub(":", "_")
end

--- The RPC request for one component's status.
function Shelly.statusRequest(prefix, key)
  local kind, index = tostring(key):match("^(%a+):(%d+)$")
  return JSON:encode({
    id = 1,
    src = Shelly.lightSrc(prefix, key),
    method = (Shelly.METHODS[kind] or "Light") .. ".GetStatus",
    params = { id = tonumber(index) or 0 },
  })
end

--- MQTT Light property values for one output of a device.
--- @param dev table
--- @param key string component key
--- @return table|nil properties
--- @return string|nil err
function Shelly.lightProperties(dev, key)
  local c = Shelly.component(dev, key)
  if c == nil then
    return nil, "no such output on " .. tostring(dev.topic)
  end
  local props = {
    ["Payload Mode"] = "Shelly (Gen2+)",
    ["Shelly Topic Prefix"] = dev.topic,
    ["Shelly Component"] = c.key,
    ["State Request Topic"] = dev.topic .. "/rpc",
    ["State Request Payload"] = Shelly.statusRequest(dev.topic, c.key),
    ["Availability Topic"] = dev.topic .. "/online",
    ["Availability Value Path"] = "",
    ["Payload Available"] = "true",
    ["Payload Not Available"] = "false",
  }
  if c.type == "cct" then
    props["Color Temp Min"] = tostring(c.ctMin or Shelly.DEFAULT_CT_MIN)
    props["Color Temp Max"] = tostring(c.ctMax or Shelly.DEFAULT_CT_MAX)
  end
  return props
end

--- A Control4 name for one output: the output's name, else the device name
--- (with the output when the device has several).
--- @return string|nil
function Shelly.loadName(dev, key)
  local c = Shelly.component(dev, key)
  if c == nil then
    return nil
  end
  local function given(v)
    v = text(v)
    -- Unnamed devices report their ID ("shellyplus1pm-a8032ab12345") as the name.
    if v == nil or v == dev.id then
      return nil
    end
    return v
  end
  local base = given(dev.name) or dev.id or dev.topic
  local loads = Shelly.loads(dev)
  if given(c.name) then
    return c.name
  end
  if #loads == 1 then
    return base
  end
  for _, l in ipairs(loads) do
    if l.id == key then
      return base .. " " .. l.label:gsub("%s*'.*'$", "")
    end
  end
  return base
end

--- Things to fix on the device for the light to work well.
function Shelly.notes(dev)
  local notes = {}
  if #(dev.components or {}) == 0 then
    notes[#notes + 1] = "No light or relay outputs found (a cover or sensor profile?)."
  end
  return notes
end

return Shelly
