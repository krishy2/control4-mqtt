--- @module "mqtt.tasmota"
--- Tasmota native discovery: what a device announces about itself, and the
--- MQTT Light settings that follow from it.
---
--- Tasmota publishes a retained JSON description to
--- tasmota/discovery/<MAC>/config whenever it connects (SetOption19 0, the
--- default). An empty payload on that topic means the device turned discovery
--- off. The format follows Tasmota's xdrv_12_discovery.ino; the light state
--- keys follow ResponseLightState in xdrv_04_light.ino:
---
---   linked light       POWER (one output) or POWER<n>, Dimmer, Color, CT, White
---   RGB + white split  POWER<n> + Dimmer1 (color), POWER<n+1> + Dimmer2 (white)
---   SetOption68        one dimmer per PWM channel: POWER<n> + Channel<n>
---
--- Pure Lua: no Control4 calls.

local Tasmota = {}

Tasmota.DISCOVERY_PATTERN = "^tasmota/discovery/([^/]+)/config$"
Tasmota.DISCOVERY_FILTER = "tasmota/discovery/+/config"

-- Light subtypes (lt_st)
Tasmota.LIGHT_NONE = 0
Tasmota.LIGHT_SINGLE = 1
Tasmota.LIGHT_CT = 2
Tasmota.LIGHT_RGB = 3
Tasmota.LIGHT_RGBW = 4
Tasmota.LIGHT_RGBCW = 5

Tasmota.LIGHT_TYPE_NAMES = {
  [0] = "",
  [1] = "dimmer",
  [2] = "CCT",
  [3] = "RGB",
  [4] = "RGBW",
  [5] = "RGBCCT",
}

-- Output types in "rl"
local RL_RELAY, RL_LIGHT = 1, 2

local function str(v)
  if v == nil then
    return nil
  end
  if type(v) == "string" then
    return v
  end
  return tostring(v)
end

local function num(v)
  return tonumber(v)
end

local function decode(payload)
  if type(payload) == "table" then
    return payload
  end
  local ok, t = pcall(JSON.decode, JSON, payload)
  if ok and type(t) == "table" then
    return t
  end
  return nil
end

--- Is this topic a Tasmota discovery config? Returns the MAC if so.
--- @param topic string
--- @return string|nil mac
function Tasmota.discoveryMac(topic)
  return type(topic) == "string" and topic:match(Tasmota.DISCOVERY_PATTERN) or nil
end

--- Parse a discovery payload into a compact device description.
--- @param payload string|table
--- @return table|nil device nil when the payload is empty or not a discovery config
--- @return string|nil err
function Tasmota.parse(payload)
  if payload == nil or payload == "" then
    return nil, "empty"
  end
  local t = decode(payload)
  if t == nil then
    return nil, "not JSON"
  end
  local topic = str(t.t)
  local mac = str(t.mac)
  if topic == nil or topic == "" or mac == nil then
    return nil, "not a Tasmota discovery config"
  end
  local so = type(t.so) == "table" and t.so or {}
  local function opt(n)
    return num(so[tostring(n)]) or 0
  end

  -- Keep only what the drivers need, trimmed to the outputs that exist.
  local rl = {}
  local lastUsed = 0
  for i, v in ipairs(type(t.rl) == "table" and t.rl or {}) do
    rl[i] = num(v) or 0
    if rl[i] ~= 0 then
      lastUsed = i
    end
  end
  for i = #rl, lastUsed + 1, -1 do
    rl[i] = nil
  end
  local fn = {}
  for i = 1, #rl do
    local name = type(t.fn) == "table" and str(t.fn[i]) or nil
    fn[i] = name or ""
  end
  -- Buttons (btn: 1 = present) and switches (swc: switch mode, -1 = none), with switch names
  local buttons, switches = {}, {}
  for i, v in ipairs(type(t.btn) == "table" and t.btn or {}) do
    if num(v) == 1 then
      buttons[#buttons + 1] = i
    end
  end
  for i, v in ipairs(type(t.swc) == "table" and t.swc or {}) do
    if num(v) ~= nil and num(v) >= 0 then
      local swn = type(t.swn) == "table" and str(t.swn[i]) or nil
      switches[#switches + 1] = { index = i, name = swn }
    end
  end
  -- Shutters: their tilt settings (sht) and options (sho), one entry per shutter
  local sht, sho = {}, {}
  for i, v in ipairs(type(t.sht) == "table" and t.sht or {}) do
    if type(v) == "table" then
      sht[i] = { num(v[1]) or 0, num(v[2]) or 0, num(v[3]) or 0 }
    end
  end
  for i, v in ipairs(type(t.sho) == "table" and t.sho or {}) do
    sho[i] = num(v) or 0
  end
  local tp = type(t.tp) == "table" and t.tp or {}
  local state = type(t.state) == "table" and t.state or {}

  return {
    mac = mac,
    topic = topic,
    fullTopic = str(t.ft) or "%prefix%/%topic%/",
    prefixes = { str(tp[1]) or "cmnd", str(tp[2]) or "stat", str(tp[3]) or "tele" },
    hostname = str(t.hn) or "",
    name = str(t.dn) or topic,
    friendlyNames = fn,
    ip = str(t.ip) or "",
    model = str(t.md) or "",
    version = str(t.sw) or "",
    relays = rl,
    lightType = num(t.lt_st) or 0,
    linked = num(t.lk) ~= 0,
    online = str(t.onln) or "Online",
    offline = str(t.ofln) or "Offline",
    stateOff = str(state[1]) or "OFF",
    stateOn = str(state[2]) or "ON",
    so4 = opt(4),
    so17 = opt(17),
    so68 = opt(68),
    so82 = opt(82),
    so73 = opt(73),
    so114 = opt(114),
    buttons = buttons,
    switches = switches,
    shutterTilt = sht,
    shutterOptions = sho,
    ifan = num(t["if"]) == 1,
  }
end

--- Build a topic from the device's full topic pattern.
--- @param dev table
--- @param prefix integer 1 = cmnd, 2 = stat, 3 = tele
--- @param command string e.g. "POWER", "RESULT", "LWT"
--- @return string
function Tasmota.topicFor(dev, prefix, command)
  local ft = dev.fullTopic or "%prefix%/%topic%/"
  local id = (dev.mac or ""):gsub("[^%x]", ""):sub(-6):upper()
  local function rep(s, key, value)
    return (s:gsub("%%" .. key .. "%%", (value:gsub("%%", "%%%%"))))
  end
  ft = rep(ft, "prefix", dev.prefixes[prefix] or "")
  ft = rep(ft, "topic", dev.topic or "")
  ft = rep(ft, "hostname", dev.hostname or "")
  ft = rep(ft, "id", id)
  if ft:sub(-1) ~= "/" then
    ft = ft .. "/"
  end
  return ft .. command
end

--- Outputs a Control4 light can be made of: lights first, then relays.
--- @param dev table
--- @return table[] loads { id, kind, index, label, power, ... }
function Tasmota.loads(dev)
  local rl = dev.relays or {}
  local devices = 0
  local firstLight = nil
  for i, v in ipairs(rl) do
    if v ~= 0 then
      devices = devices + 1
    end
    if v == RL_LIGHT and firstLight == nil then
      firstLight = i
    end
  end
  local function powerKey(index, forceIndex)
    if devices <= 1 and not forceIndex then
      return "POWER"
    end
    return "POWER" .. index
  end
  local lt = dev.lightType or 0
  local typeName = Tasmota.LIGHT_TYPE_NAMES[lt] or ""
  local loads = {}

  if firstLight ~= nil and lt > 0 then
    if dev.so68 == 1 then
      -- One dimmer per PWM channel
      local ch = 0
      for i = firstLight, #rl do
        if rl[i] == RL_LIGHT then
          ch = ch + 1
          loads[#loads + 1] = {
            id = "channel" .. i,
            kind = "channel",
            index = i,
            label = string.format("Channel %d", ch),
            power = powerKey(i, true),
            dimmer = "Channel" .. i,
          }
        end
      end
    elseif lt >= Tasmota.LIGHT_RGBW and not dev.linked then
      loads[#loads + 1] = {
        id = "light" .. firstLight,
        kind = "color",
        index = firstLight,
        label = "RGB light",
        power = powerKey(firstLight, true),
        dimmer = "Dimmer1",
        color = true,
      }
      loads[#loads + 1] = {
        id = "light" .. (firstLight + 1),
        kind = "white",
        index = firstLight + 1,
        label = lt == Tasmota.LIGHT_RGBCW and "CCT light" or "White light",
        power = powerKey(firstLight + 1, true),
        dimmer = "Dimmer2",
        ct = lt == Tasmota.LIGHT_RGBCW,
      }
    else
      loads[#loads + 1] = {
        id = "light" .. firstLight,
        kind = "light",
        index = firstLight,
        label = typeName .. " light",
        power = powerKey(firstLight),
        dimmer = "Dimmer",
        ct = lt == Tasmota.LIGHT_CT or lt == Tasmota.LIGHT_RGBCW,
        color = lt >= Tasmota.LIGHT_RGB,
        white = lt == Tasmota.LIGHT_RGBW,
      }
    end
  end

  local relayNo = 0
  for i, v in ipairs(rl) do
    if v == RL_RELAY then
      relayNo = relayNo + 1
      local fname = dev.friendlyNames and dev.friendlyNames[i] or ""
      local label = string.format("Relay %d", i)
      if fname ~= "" and fname ~= dev.name then
        label = string.format("Relay %d '%s'", i, fname)
      end
      loads[#loads + 1] = { id = "relay" .. i, kind = "relay", index = i, label = label, power = powerKey(i) }
    end
  end
  return loads
end

--- The load with this id, or nil.
function Tasmota.load(dev, loadId)
  for _, l in ipairs(Tasmota.loads(dev)) do
    if l.id == loadId then
      return l
    end
  end
  return nil
end

--- A Control4 name for one output of a device.
---
--- One output: the Tasmota DeviceName. Several outputs: the output's own
--- FriendlyName when it has one, otherwise the DeviceName followed by the
--- output ("Kitchen RGB light", "Kitchen Relay 2"). Tasmota's default names
--- ("Tasmota", "Tasmota2", ...) are passed over for the device topic.
--- @param dev table
--- @param loadId string
--- @return string|nil
function Tasmota.loadName(dev, loadId)
  local load = Tasmota.load(dev, loadId)
  if load == nil then
    return nil
  end
  local function given(v)
    v = str(v)
    if v == nil or not v:match("%S") or v:match("^Tasmota%d*$") then
      return nil
    end
    return v:match("^%s*(.-)%s*$")
  end
  local names = type(dev.friendlyNames) == "table" and dev.friendlyNames or {}
  local base = given(dev.name) or given(names[1]) or str(dev.topic) or "Tasmota"
  if #Tasmota.loads(dev) == 1 then
    return base
  end
  local friendly = given(names[load.index])
  if friendly ~= nil and friendly ~= base then
    -- An RGB and white pair given the same FriendlyName still need two names.
    if load.kind == "color" or load.kind == "white" then
      local other = given(names[load.kind == "color" and load.index + 1 or load.index - 1])
      if other == friendly then
        return friendly .. " " .. load.label
      end
    end
    return friendly
  end
  return base .. " " .. load.label:gsub("%s*'.*'$", "")
end

--- Things on the device that should be changed for the light to work well.
--- @param dev table
--- @return string[]
function Tasmota.notes(dev)
  local notes = {}
  if dev.so4 == 1 then
    notes[#notes + 1] = "SetOption4 is 1: answers go to stat/<topic>/<COMMAND> instead of RESULT. Run SetOption4 0."
  end
  return notes
end

--- Compact entry for lists sent to child drivers.
--- @param dev table
--- @return table
function Tasmota.summary(dev)
  local loads = {}
  for _, l in ipairs(Tasmota.loads(dev)) do
    loads[#loads + 1] = { id = l.id, label = l.label }
  end
  return {
    mac = dev.mac,
    topic = dev.topic,
    name = dev.name,
    ip = dev.ip,
    loads = loads,
    buttons = #Tasmota.buttons(dev),
    shutters = Tasmota.shutters(dev),
    fans = Tasmota.fans(dev),
  }
end

local RL_SHUTTER = 3

--- Shutters on the device: two relays marked as shutter (rl 3) each.
--- @param dev table
--- @return table[] { id, index, label, tilt, tiltMin, tiltMax, inverted }
function Tasmota.shutters(dev)
  local relays = 0
  for _, v in ipairs(dev.relays or {}) do
    if v == RL_SHUTTER then
      relays = relays + 1
    end
  end
  local out = {}
  local count = math.floor(relays / 2)
  for i = 1, count do
    local tilt = (dev.shutterTilt or {})[i] or { 0, 0, 0 }
    local hasTilt = tilt[1] ~= tilt[2]
    out[#out + 1] = {
      id = "shutter" .. i,
      index = i,
      label = count > 1 and ("Shutter " .. i) or "Shutter",
      tilt = hasTilt,
      tiltMin = hasTilt and tilt[1] or -90,
      tiltMax = hasTilt and tilt[2] or 90,
      inverted = (((dev.shutterOptions or {})[i] or 0) % 2) == 1,
    }
  end
  return out
end

--- MQTT Shutter property values for one shutter.
--- @param dev table
--- @param id string "shutter<n>"
--- @return table|nil props, string|nil err
function Tasmota.shutterProperties(dev, id)
  local sh
  for _, s in ipairs(Tasmota.shutters(dev)) do
    if s.id == id then
      sh = s
    end
  end
  if sh == nil then
    return nil, "no such shutter on " .. tostring(dev.topic)
  end
  local n = tostring(sh.index)
  local result = Tasmota.topicFor(dev, 2, "RESULT")
  local function cmnd(c)
    return Tasmota.topicFor(dev, 1, c .. n)
  end
  local key = "$.Shutter" .. n
  return {
    ["Payload Mode"] = "Separate Topics",
    ["Position State Topic"] = result,
    ["Position Value Path"] = key .. ".Position",
    ["Position Command Topic"] = cmnd("ShutterPosition"),
    ["Target Value Path"] = key .. ".Target",
    ["Movement State Topic"] = result,
    ["Movement Value Path"] = key .. ".Direction",
    ["Open Command Topic"] = cmnd("ShutterOpen"),
    ["Open Payload"] = "",
    ["Close Command Topic"] = cmnd("ShutterClose"),
    ["Close Payload"] = "",
    ["Stop Command Topic"] = cmnd("ShutterStop"),
    ["Stop Payload"] = "",
    ["Tilt State Topic"] = sh.tilt and result or "",
    ["Tilt Value Path"] = sh.tilt and (key .. ".Tilt") or "",
    ["Tilt Command Topic"] = sh.tilt and cmnd("ShutterTilt") or "",
    ["Tilt Min"] = tostring(sh.tiltMin),
    ["Tilt Max"] = tostring(sh.tiltMax),
    ["Invert Position"] = sh.inverted and "Yes" or "No",
    ["State Request Topic"] = cmnd("ShutterPosition"),
    ["State Request Payload"] = "",
    ["Availability Topic"] = Tasmota.topicFor(dev, 3, "LWT"),
    ["Availability Value Path"] = "",
    ["Payload Available"] = dev.online,
    ["Payload Not Available"] = dev.offline,
  }
end

--- A Control4 name for a shutter: the device name (with the shutter when it has several).
function Tasmota.shutterName(dev, id)
  for _, s in ipairs(Tasmota.shutters(dev)) do
    if s.id == id then
      local base = dev.name
      if base == nil or base == "" or base:match("^Tasmota%d*$") then
        base = dev.topic
      end
      return s.label == "Shutter" and base or (base .. " " .. s.label)
    end
  end
  return nil
end

--- Fans on the device: a Sonoff iFan (discovery "if": 1) has one, run with
--- FanSpeed 0 (off) to 3 and reported as FanSpeed on stat/<topic>/RESULT.
--- @param dev table
--- @return table[] { id, label }
function Tasmota.fans(dev)
  if not dev.ifan then
    return {}
  end
  return { { id = "fan", label = "Fan" } }
end

--- MQTT Fan property values for the iFan's fan.
--- @param dev table
--- @param id string "fan"
--- @return table|nil props, string|nil err
function Tasmota.fanProperties(dev, id)
  if id ~= "fan" or not dev.ifan then
    return nil, "no fan on " .. tostring(dev.topic)
  end
  return {
    ["Payload Mode"] = "Separate Topics",
    ["Power State Topic"] = "",
    ["Power Value Path"] = "",
    ["Power Command Topic"] = "",
    ["Speed State Topic"] = Tasmota.topicFor(dev, 2, "RESULT"),
    ["Speed Value Path"] = "$.FanSpeed",
    ["Speed Command Topic"] = Tasmota.topicFor(dev, 1, "FanSpeed"),
    ["Speed Values"] = "1,2,3",
    ["Speed Off Value"] = "0",
    ["Direction State Topic"] = "",
    ["Direction Command Topic"] = "",
    ["State Request Topic"] = Tasmota.topicFor(dev, 1, "STATE"),
    ["State Request Payload"] = "",
    ["Availability Topic"] = Tasmota.topicFor(dev, 3, "LWT"),
    ["Availability Value Path"] = "",
    ["Payload Available"] = dev.online,
    ["Payload Not Available"] = dev.offline,
  }
end

--- A Control4 name for a fan: the device name.
function Tasmota.fanName(dev, id)
  if id ~= "fan" or not dev.ifan then
    return nil
  end
  local base = dev.name
  if base == nil or base == "" or base:match("^Tasmota%d*$") then
    base = dev.topic
  end
  return base .. " Fan"
end

--- Tasmota button actions (SetOption73 1).
Tasmota.BUTTON_ACTIONS = "SINGLE,DOUBLE,TRIPLE,QUAD,PENTA,HOLD"

--- Buttons and switches that publish their presses, as MQTT General Events.
--- Buttons publish only when decoupled from the relays (SetOption73 1), switches
--- only when detached (SetOption114 1); both on stat/<topic>/RESULT as
--- {"Button1":{"Action":"SINGLE"}} or {"Switch1":{"Action":"ON"}}.
--- @param dev table
--- @return table[] { id, label, stateTopic, valuePath, eventTypeFilter }
function Tasmota.buttons(dev)
  local out = {}
  local result = Tasmota.topicFor(dev, 2, "RESULT")
  if dev.so73 == 1 then
    for _, i in ipairs(dev.buttons or {}) do
      out[#out + 1] = {
        id = "button" .. i,
        label = "Button " .. i,
        stateTopic = result,
        valuePath = "$.Button" .. i .. ".Action",
        eventTypeFilter = Tasmota.BUTTON_ACTIONS,
      }
    end
  end
  if dev.so114 == 1 then
    for _, sw in ipairs(dev.switches or {}) do
      local label = "Switch " .. sw.index
      if sw.name and sw.name ~= "" and sw.name ~= label and sw.name ~= "Switch" .. sw.index then
        label = sw.name
      end
      out[#out + 1] = {
        id = "switch" .. sw.index,
        label = label,
        stateTopic = result,
        valuePath = "$.Switch" .. sw.index .. ".Action",
        eventTypeFilter = "",
      }
    end
  end
  return out
end

--- Why buttons on the device do not show up, if they would with a setting changed.
--- @param dev table
--- @return string[]
function Tasmota.buttonNotes(dev)
  local notes = {}
  if dev.so73 ~= 1 and #(dev.buttons or {}) > 0 then
    notes[#notes + 1] = string.format(
      "%s has %d button(s) that control its relays; run SetOption73 1 on it to use them as events.",
      dev.name,
      #dev.buttons
    )
  end
  if dev.so114 ~= 1 and #(dev.switches or {}) > 0 then
    notes[#notes + 1] = string.format(
      "%s has %d switch input(s) that control its relays; run SetOption114 1 on it to use them as events.",
      dev.name,
      #dev.switches
    )
  end
  return notes
end

--- MQTT Light property values for one load of a device.
--- @param dev table
--- @param loadId string
--- @return table|nil properties name -> value
--- @return string|nil err
function Tasmota.lightProperties(dev, loadId)
  local load = Tasmota.load(dev, loadId)
  if load == nil then
    return nil, "no such output on " .. tostring(dev.topic)
  end
  local result = Tasmota.topicFor(dev, 2, "RESULT")
  local function cmnd(c)
    return Tasmota.topicFor(dev, 1, c)
  end
  local function feature(prefix, enabled, path, command)
    local p = {}
    p[prefix .. " State Topic"] = enabled and result or ""
    p[prefix .. " Value Path"] = enabled and ("$." .. path) or ""
    p[prefix .. " Command Topic"] = enabled and cmnd(command) or ""
    return p
  end

  local props = {
    ["Payload Mode"] = "Separate Topics",
    ["State Request Topic"] = cmnd("STATE"),
    ["State Request Payload"] = "",
    ["Availability Topic"] = Tasmota.topicFor(dev, 3, "LWT"),
    ["Availability Value Path"] = "",
    ["Payload Available"] = dev.online,
    ["Payload Not Available"] = dev.offline,
    ["State On"] = dev.stateOn,
    ["State Off"] = dev.stateOff,
    ["Payload On"] = dev.stateOn,
    ["Payload Off"] = dev.stateOff,
    ["Brightness Scale Max"] = "100",
    ["White Scale Max"] = "100",
  }
  local function merge(t)
    for k, v in pairs(t) do
      props[k] = v
    end
  end
  merge(feature("Power", true, load.power, load.power))
  merge(feature("Brightness", load.dimmer ~= nil, load.dimmer or "", load.dimmer or ""))
  merge(feature("Color Temp", load.ct == true, "CT", "CT"))
  merge(feature("Color", load.color == true, "Color", "Color"))
  merge(feature("White", load.white == true, "White", "White"))

  if load.ct then
    props["Color Temp Unit"] = "Mireds"
    if dev.so82 == 1 then
      -- SetOption82: CT limited to 200-380 mireds
      props["Color Temp Min"] = "2630"
      props["Color Temp Max"] = "5000"
    else
      props["Color Temp Min"] = "2000"
      props["Color Temp Max"] = "6500"
    end
  end
  if load.color then
    -- SetOption17 1 reports Color as decimal "r,g,b,..."
    props["Color Format"] = dev.so17 == 1 and "RGB (r,g,b)" or "Hex (RRGGBB)"
    props["Color Includes Brightness"] = "Yes"
  end
  return props
end

return Tasmota
