--- MQTT Light Driver
--- A Control4 light_v2 driver for MQTT lights.
---
--- Connects to an MQTT broker through the MQTT Broker driver and controls one
--- light. The light's abilities follow from the topics (or JSON keys) that are
--- filled in: On/Off always, then Dimmer, Color Temperature, Color, a White
--- channel and device-side Transitions.

require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

local log = require("lib.logging")
local persist = require("lib.persist")
local events = require("lib.events")
local values = require("lib.values")
local constants = require("constants")

local MqttDevice = require("mqtt.entities.device")
local MqttLight = require("mqtt.light")
local Tasmota = require("mqtt.tasmota")

-- Binding IDs
local LIGHT_PROXY_BINDING = 5001
local MQTT_BINDING = 5002

local SETTINGS_PERSIST_KEY = "LightSettings"
local TASMOTA_PERSIST_KEY = "TasmotaSelection"
local MANUAL = "(Manual)"

-- Tasmota device choice. Declared here because start-up uses them; they are
-- filled in by the Tasmota discovery section further down.
--- Dropdown label -> { mac, load }
local tasmotaChoices = {}
--- The chosen device and output, kept across restarts: { mac, load, label }
local tasmotaSelection = nil
local updateTasmotaList, setTasmotaNotes

--- Properties that make up the light configuration. A change to any of them
--- reconfigures the light.
local CONFIG_PROPERTIES = {
  "Payload Mode",
  "JSON State Topic",
  "JSON Command Topic",
  "Optimistic",
  "QoS",
  "Retain",
  "Power State Topic",
  "Power Value Path",
  "Power Command Topic",
  "State Key",
  "State On",
  "State Off",
  "Payload On",
  "Payload Off",
  "Brightness State Topic",
  "Brightness Value Path",
  "Brightness Command Topic",
  "Brightness Key",
  "Brightness Scale Max",
  "Color Temp State Topic",
  "Color Temp Value Path",
  "Color Temp Command Topic",
  "Color Temp Key",
  "Color Temp Unit",
  "Color Temp Min",
  "Color Temp Max",
  "Color State Topic",
  "Color Value Path",
  "Color Command Topic",
  "Color Key",
  "Color Format",
  "JSON Color Format",
  "Color Includes Brightness",
  "White State Topic",
  "White Value Path",
  "White Command Topic",
  "White Key",
  "White Scale Max",
  "White Color Temp",
  "Transition Command Topic",
  "Transition Key",
  "Transition Unit",
}

--- @type table
local light
--- Topics currently subscribed for the light (availability is tracked by MqttDevice).
local subscribed = {}
--- Last payload per topic, replayed when the configuration changes.
local lastPayloads = {}
--- Last ONLINE_CHANGED state sent to the proxy.
local lastOnline = nil

-----------------------------------------------------------------------
-- Configuration
-----------------------------------------------------------------------

local function prop(name)
  local v = Properties[name]
  if v == nil then
    return ""
  end
  return v
end

--- Build the light configuration from properties.
--- @return table
local function buildConfig()
  local function feature(name)
    return {
      stateTopic = prop(name .. " State Topic"),
      valuePath = prop(name .. " Value Path"),
      commandTopic = prop(name .. " Command Topic"),
    }
  end
  return {
    mode = prop("Payload Mode"),
    optimistic = prop("Optimistic"),
    qos = prop("QoS") ~= "" and prop("QoS") or "0",
    retain = prop("Retain") == "Yes",
    stateOn = prop("State On"),
    stateOff = prop("State Off"),
    payloadOn = prop("Payload On"),
    payloadOff = prop("Payload Off"),
    brightnessMax = tonumber(prop("Brightness Scale Max")) or 100,
    colorTempUnit = prop("Color Temp Unit"),
    colorTempMin = tonumber(prop("Color Temp Min")) or 2000,
    colorTempMax = tonumber(prop("Color Temp Max")) or 6500,
    colorFormat = prop("Color Format"),
    jsonColorFormat = prop("JSON Color Format"),
    colorIncludesBrightness = prop("Color Includes Brightness") ~= "No",
    whiteMax = tonumber(prop("White Scale Max")) or 100,
    whiteColorTemp = tonumber(prop("White Color Temp")) or 4000,
    transitionUnit = prop("Transition Unit"),
    topics = {
      power = feature("Power"),
      brightness = feature("Brightness"),
      colorTemp = feature("Color Temp"),
      color = feature("Color"),
      white = feature("White"),
      transition = { commandTopic = prop("Transition Command Topic") },
    },
    json = {
      stateTopic = prop("JSON State Topic"),
      commandTopic = prop("JSON Command Topic"),
      keys = {
        power = prop("State Key"),
        brightness = prop("Brightness Key"),
        colorTemp = prop("Color Temp Key"),
        color = prop("Color Key"),
        white = prop("White Key"),
        transition = prop("Transition Key"),
        colorMode = "color_mode",
      },
    },
  }
end

--- Show or hide configuration properties for the current mode and capabilities.
local function updatePropertyVisibility()
  local cfg = light.cfg
  local caps = light.caps
  local json = light:isJsonMode()
  local topics = not json
  local t = cfg.topics or {}
  local function filled(feature, which)
    return not IsEmpty((t[feature] or {})[which])
  end
  local fmt = cfg.colorFormat
  local F = MqttLight.COLOR_FORMATS
  local rgbFormat = fmt == F.RGB or fmt == F.HEX or fmt == F.HEX_HASH

  local rules = {
    ["JSON State Topic"] = json,
    ["JSON Command Topic"] = json,
    ["Power State Topic"] = topics,
    ["Power Value Path"] = topics and filled("power", "stateTopic"),
    ["Power Command Topic"] = topics,
    ["State Key"] = json,
    ["State On"] = json or filled("power", "stateTopic"),
    ["State Off"] = json or filled("power", "stateTopic"),
    ["Payload On"] = json or filled("power", "commandTopic"),
    ["Payload Off"] = json or filled("power", "commandTopic"),
    ["Brightness State Topic"] = topics,
    ["Brightness Value Path"] = topics and filled("brightness", "stateTopic"),
    ["Brightness Command Topic"] = topics,
    ["Brightness Key"] = json,
    ["Brightness Scale Max"] = caps.brightness,
    ["Color Temp State Topic"] = topics,
    ["Color Temp Value Path"] = topics and filled("colorTemp", "stateTopic"),
    ["Color Temp Command Topic"] = topics,
    ["Color Temp Key"] = json,
    ["Color Temp Unit"] = caps.colorTemp,
    ["Color Temp Min"] = caps.colorTemp,
    ["Color Temp Max"] = caps.colorTemp,
    ["Color State Topic"] = topics,
    ["Color Value Path"] = topics and filled("color", "stateTopic"),
    ["Color Command Topic"] = topics,
    ["Color Key"] = json,
    ["Color Format"] = topics and caps.color,
    ["JSON Color Format"] = json and caps.color,
    ["Color Includes Brightness"] = topics and caps.color and rgbFormat,
    ["White State Topic"] = topics,
    ["White Value Path"] = topics and filled("white", "stateTopic"),
    ["White Command Topic"] = topics,
    ["White Key"] = json,
    ["White Scale Max"] = caps.white,
    ["White Color Temp"] = caps.white and not caps.colorTemp,
    ["Transition Command Topic"] = topics,
    ["Transition Key"] = json,
    ["Transition Unit"] = caps.transition,
  }
  for name, visible in pairs(rules) do
    C4:SetPropertyAttribs(name, visible and constants.SHOW_PROPERTY or constants.HIDE_PROPERTY)
  end
end

--- Update availability property visibility (same behaviour as MQTT General).
local function updateAvailabilityPropertyVisibility()
  local hasAvailabilityTopic = not IsEmpty(Properties["Availability Topic"])
  local vis = hasAvailabilityTopic and constants.SHOW_PROPERTY or constants.HIDE_PROPERTY
  C4:SetPropertyAttribs("Availability Topic Value", vis)
  C4:SetPropertyAttribs("Availability Status", vis)
  C4:SetPropertyAttribs("Payload Available", vis)
  C4:SetPropertyAttribs("Payload Not Available", vis)
  C4:SetPropertyAttribs("Availability Value Path", vis)
  local hasAvailPath = not IsEmpty(Properties["Availability Value Path"])
  local pathResultVis = (hasAvailabilityTopic and hasAvailPath) and constants.SHOW_PROPERTY or constants.HIDE_PROPERTY
  C4:SetPropertyAttribs("Availability Value Path Result", pathResultVis)
end

-----------------------------------------------------------------------
-- Subscriptions and online state
-----------------------------------------------------------------------

--- Bring broker subscriptions in line with the configuration.
local function syncSubscriptions()
  if not MqttDevice:isConnected() then
    return
  end
  local deviceId = tostring(C4:GetDeviceID())
  local wanted = {}
  for _, topic in ipairs(light:subscriptions()) do
    wanted[topic] = true
  end
  for topic, _ in pairs(subscribed) do
    if not wanted[topic] then
      log:debug("Unsubscribing from %s", topic)
      SendToProxy(MQTT_BINDING, "UNSUBSCRIBE", { topic = topic, device_id = deviceId })
      subscribed[topic] = nil
      lastPayloads[topic] = nil
    end
  end
  for topic, _ in pairs(wanted) do
    if not subscribed[topic] then
      log:debug("Subscribing to %s", topic)
      SendToProxy(MQTT_BINDING, "SUBSCRIBE", { topic = topic, qos = light.cfg.qos or "0", device_id = deviceId })
      subscribed[topic] = true
    end
  end
end

--- Tell the proxy whether the light is online.
--- Online means: broker connected, and not reported unavailable.
local function updateOnline(force)
  local online = MqttDevice:isConnected() and MqttDevice:isAvailable() ~= false
  if not force and online == lastOnline then
    return
  end
  lastOnline = online
  SendToProxy(LIGHT_PROXY_BINDING, "ONLINE_CHANGED", { STATE = tostring(online) }, "NOTIFY")
end

--- When the last state request was sent (ms), to merge triggers that arrive together.
local lastStateRequest = nil

--- Ask the device for its full state (Tasmota: cmnd/<topic>/STATE), so the
--- light is right after a restart instead of unknown until the device changes.
--- Sent when the broker connects and when the device comes online.
--- @param reason string
local function requestState(reason)
  local topic = Properties["State Request Topic"]
  if IsEmpty(topic) or not MqttDevice:isConnected() then
    return
  end
  local now = C4:GetTime()
  if lastStateRequest ~= nil and now - lastStateRequest < 2000 then
    return
  end
  lastStateRequest = now
  log:debug("Requesting device state (%s): %s", reason, topic)
  SendToProxy(MQTT_BINDING, "PUBLISH", {
    topic = topic,
    payload = Properties["State Request Payload"] or "",
    qos = light.cfg.qos or "0",
    retain = "false",
  })
end

-----------------------------------------------------------------------
-- Applying configuration
-----------------------------------------------------------------------

--- Re-read properties, update capabilities, subscriptions and visibility.
--- @param force boolean|nil Send capabilities to the proxy even if unchanged.
local function applyConfig(force)
  local capsChanged = light:configure(buildConfig())
  UpdateProperty("Capabilities", light:describeCapabilities())
  if capsChanged or force then
    log:info("Light capabilities: %s", light:describeCapabilities())
    light:refreshProxy()
  end
  updatePropertyVisibility()
  syncSubscriptions()

  -- Re-evaluate cached state with the new configuration
  if not IsEmpty(lastPayloads) then
    light:resetState()
    for topic, payload in pairs(lastPayloads) do
      light:onMessage(topic, payload)
    end
  end
end

local function updateStateProperty()
  UpdateProperty("Light State", light:stateText())
end

-----------------------------------------------------------------------
-- Driver lifecycle
-----------------------------------------------------------------------

function OnDriverInit()
  C4:AllowExecute(true)
  gInitialized = false
  log:setLogName(C4:GetDeviceData(C4:GetDeviceID(), "name"))
  log:setLogLevel(Properties["Log Level"])
  log:setLogMode(Properties["Log Mode"])
  log:trace("OnDriverInit()")

  MqttDevice:init(MQTT_BINDING)

  light = MqttLight.new({
    proxyBinding = LIGHT_PROXY_BINDING,
    brokerBinding = MQTT_BINDING,
    onStateChanged = updateStateProperty,
    onSettingsChanged = function(settings)
      persist:set(SETTINGS_PERSIST_KEY, settings)
    end,
  })
  light:loadSettings(persist:get(SETTINGS_PERSIST_KEY, {}) or {})

  events:restoreEvents()
  values:restoreValues()
end

function OnDriverLateInit()
  log:trace("OnDriverLateInit()")
  if not CheckMinimumVersion("Driver Status") then
    return
  end
  UpdateProperty("Driver Status", "Initializing")

  -- Fire OnPropertyChanged to set the initial state of every property
  for p, _ in pairs(Properties) do
    local status, err = pcall(OnPropertyChanged, p)
    if not status and err ~= nil then
      log:error(err)
    end
  end
  gInitialized = true
  UpdateProperty("Driver Status", "Disconnected")

  local hasAvailabilityTopic = not IsEmpty(Properties["Availability Topic"])
  MqttDevice:registerAvailabilityEvents(hasAvailabilityTopic)
  updateAvailabilityPropertyVisibility()

  applyConfig(true)
  updateStateProperty()
  updateOnline(true)

  tasmotaSelection = persist:get(TASMOTA_PERSIST_KEY, nil)
  updateTasmotaList()
  setTasmotaNotes("")

  -- Request current broker status
  SendToProxy(MQTT_BINDING, "GET_STATUS", {}, "NOTIFY")
end

-----------------------------------------------------------------------
-- Property change handlers
-----------------------------------------------------------------------

function OPC.Driver_Version(propertyValue)
  log:trace("OPC.Driver_Version('%s')", propertyValue)
  C4:UpdateProperty("Driver Version", C4:GetDriverConfigInfo("version"))
end

function OPC.Log_Mode(propertyValue)
  log:trace("OPC.Log_Mode('%s')", propertyValue)
  log:setLogMode(propertyValue)
  CancelTimer("LogMode")
  if not log:isEnabled() then
    return
  end
  log:warn("Log mode '%s' will expire in 3 hours", propertyValue)
  SetTimer("LogMode", 3 * ONE_HOUR, function()
    log:warn("Setting log mode to 'Off' (timer expired)")
    UpdateProperty("Log Mode", "Off", true)
  end)
end

function OPC.Log_Level(propertyValue)
  log:trace("OPC.Log_Level('%s')", propertyValue)
  log:setLogLevel(propertyValue)
  if log:getLogLevel() >= 6 and log:isPrintEnabled() then
    DEBUGPRINT = true
    DEBUG_TIMER = true
    DEBUG_RFN = true
    DEBUG_URL = true
  else
    DEBUGPRINT = false
    DEBUG_TIMER = false
    DEBUG_RFN = false
    DEBUG_URL = false
  end
end

local function availabilityConfig(overrides)
  local cfg = {
    valuePath = Properties["Availability Value Path"],
    payloadAvailable = Properties["Payload Available"],
    payloadNotAvailable = Properties["Payload Not Available"],
  }
  for k, v in pairs(overrides or {}) do
    cfg[k] = v
  end
  return cfg
end

function OPC.Availability_Topic(propertyValue)
  log:trace("OPC.Availability_Topic('%s')", propertyValue)
  if not gInitialized then
    return
  end
  if IsEmpty(propertyValue) then
    MqttDevice:unregisterAvailabilityEvents()
  else
    MqttDevice:registerAvailabilityEvents(true)
  end
  MqttDevice:subscribeToAvailability(propertyValue, tostring(C4:GetDeviceID()))
  updateAvailabilityPropertyVisibility()
  updateOnline()
end

function OPC.Payload_Available(propertyValue)
  log:trace("OPC.Payload_Available('%s')", propertyValue)
  if not gInitialized then
    return
  end
  MqttDevice:reevaluateAvailability(availabilityConfig({ payloadAvailable = propertyValue }))
  updateOnline()
end

function OPC.Payload_Not_Available(propertyValue)
  log:trace("OPC.Payload_Not_Available('%s')", propertyValue)
  if not gInitialized then
    return
  end
  MqttDevice:reevaluateAvailability(availabilityConfig({ payloadNotAvailable = propertyValue }))
  updateOnline()
end

function OPC.Availability_Value_Path(propertyValue)
  log:trace("OPC.Availability_Value_Path('%s')", propertyValue)
  if not gInitialized then
    return
  end
  MqttDevice:reevaluateAvailability(availabilityConfig({ valuePath = propertyValue }))
  updateAvailabilityPropertyVisibility()
  updateOnline()
end

--- Property name -> OPC handler name, the way handlers.lua sanitizes it.
local function handlerName(name)
  local s = string.gsub(name, "%W", "_")
  s = string.gsub(s, "[_]+", "_")
  s = string.gsub(s, "^[_| ]+", "")
  s = string.gsub(s, "[_| ]+$", "")
  return s
end

local function onConfigPropertyChanged(propertyValue)
  log:trace("Light configuration property changed: '%s'", propertyValue)
  if not gInitialized then
    return
  end
  applyConfig(false)
end

for _, name in ipairs(CONFIG_PROPERTIES) do
  OPC[handlerName(name)] = onConfigPropertyChanged
end

-----------------------------------------------------------------------
-- Tasmota discovery: pick a device, every setting follows
-----------------------------------------------------------------------

local function deviceId()
  return tostring(C4:GetDeviceID())
end

local function requestTasmotaList()
  SendToProxy(MQTT_BINDING, "GET_TASMOTA_DEVICES", { device_id = deviceId() })
end

local function requestTasmotaDevice(mac)
  SendToProxy(MQTT_BINDING, "GET_TASMOTA_DEVICE", { device_id = deviceId(), mac = mac })
end

setTasmotaNotes = function(text)
  UpdateProperty("Tasmota Notes", text or "")
  C4:SetPropertyAttribs("Tasmota Notes", IsEmpty(text) and constants.HIDE_PROPERTY or constants.SHOW_PROPERTY)
end

--- Rebuild the Tasmota Device dropdown.
updateTasmotaList = function()
  local labels = {}
  for label in pairs(tasmotaChoices) do
    labels[#labels + 1] = label
  end
  table.sort(labels, function(a, b)
    return a:lower() < b:lower()
  end)
  local current = MANUAL
  if tasmotaSelection ~= nil then
    current = tasmotaSelection.label
    if tasmotaChoices[current] == nil then
      -- Chosen device not announced (yet): keep it selectable
      labels[#labels + 1] = current
    end
  end
  table.insert(labels, 1, MANUAL)
  C4:UpdatePropertyList("Tasmota Device", table.concat(labels, ","), current)
end

--- Fill in every setting for the chosen device and output.
--- @param dev table parsed device (mqtt.tasmota)
local function applyTasmotaDevice(dev)
  local selection = tasmotaSelection
  if selection == nil then
    return
  end
  local props, err = Tasmota.lightProperties(dev, selection.load)
  if props == nil then
    setTasmotaNotes("This output no longer exists on " .. dev.topic .. " (" .. tostring(err) .. ")")
    return
  end
  -- A Tasmota fade topic (cmnd/<topic>/Speed) follows the device; anything else stays.
  local transition = Properties["Transition Command Topic"] or ""
  if transition:match("/Speed$") then
    props["Transition Command Topic"] = Tasmota.topicFor(dev, 1, "Speed")
  end

  local changed = {}
  for name, value in pairs(props) do
    if Properties[name] ~= nil and Properties[name] ~= value then
      UpdateProperty(name, value)
      Properties[name] = value
      changed[#changed + 1] = name
    end
  end
  table.sort(changed)
  log:info("Applied Tasmota device %s (%s): %d settings changed", dev.topic, selection.load, #changed)
  setTasmotaNotes(table.concat(Tasmota.notes(dev), " "))

  -- Availability has its own handler (events, subscription); then everything else.
  OnPropertyChanged("Availability Topic")
  OnPropertyChanged("Availability Value Path")
  applyConfig(false)
  requestState("Tasmota device applied")
end

function OPC.Tasmota_Device(propertyValue)
  log:trace("OPC.Tasmota_Device('%s')", propertyValue)
  if not gInitialized then
    return
  end
  if IsEmpty(propertyValue) or propertyValue == MANUAL then
    if tasmotaSelection ~= nil then
      log:info("Tasmota device cleared; settings stay as they are")
    end
    tasmotaSelection = nil
    persist:set(TASMOTA_PERSIST_KEY, nil)
    setTasmotaNotes("")
    return
  end
  local choice = tasmotaChoices[propertyValue]
  if choice == nil then
    return -- the stored selection, shown before the list arrived
  end
  tasmotaSelection = { mac = choice.mac, load = choice.load, label = propertyValue }
  persist:set(TASMOTA_PERSIST_KEY, tasmotaSelection)
  requestTasmotaDevice(choice.mac)
end

--- The broker's list of Tasmota devices.
function EC.TASMOTA_DEVICES(tParams)
  log:trace("EC.TASMOTA_DEVICES()")
  local ok, list = pcall(JSON.decode, JSON, Select(tParams, "devices") or "[]")
  if not ok or type(list) ~= "table" then
    log:warn("Could not read the Tasmota device list")
    return
  end
  tasmotaChoices = {}
  for _, dev in ipairs(list) do
    for _, load in ipairs(dev.loads or {}) do
      local label = string.format("%s [%s] %s", tostring(dev.name), tostring(dev.topic), tostring(load.label))
      label = label:gsub(",", " ")
      tasmotaChoices[label] = { mac = dev.mac, load = load.id }
      -- The chosen output may have been renamed: keep following it by MAC and output.
      if tasmotaSelection and tasmotaSelection.mac == dev.mac and tasmotaSelection.load == load.id then
        if tasmotaSelection.label ~= label then
          tasmotaSelection.label = label
          persist:set(TASMOTA_PERSIST_KEY, tasmotaSelection)
        end
      end
    end
  end
  updateTasmotaList()
end

--- One device in full, after choosing it or when it changed.
function EC.TASMOTA_DEVICE(tParams)
  local mac = Select(tParams, "mac")
  log:trace("EC.TASMOTA_DEVICE(%s)", mac)
  if tasmotaSelection == nil or mac ~= tasmotaSelection.mac then
    return
  end
  local payload = Select(tParams, "device") or ""
  if payload == "" then
    setTasmotaNotes("The broker does not know this device any more. Check that it is connected.")
    return
  end
  local ok, dev = pcall(JSON.decode, JSON, payload)
  if not ok or type(dev) ~= "table" then
    log:warn("Could not read Tasmota device %s", mac)
    return
  end
  applyTasmotaDevice(dev)
end

--- A device appeared, changed or disappeared.
function RFP.TASMOTA_DEVICES_CHANGED(idBinding, strCommand, tParams, args)
  if idBinding ~= MQTT_BINDING then
    return
  end
  local mac = Select(tParams, "mac")
  requestTasmotaList()
  if tasmotaSelection ~= nil and (IsEmpty(mac) or mac == tasmotaSelection.mac) then
    requestTasmotaDevice(tasmotaSelection.mac)
  end
end

-----------------------------------------------------------------------
-- Receive From Proxy (RFP) handlers
-----------------------------------------------------------------------

function RFP.BROKER_CONNECTED(idBinding, strCommand, tParams, args)
  log:trace("RFP.BROKER_CONNECTED(%s, %s, %s, %s)", idBinding, strCommand, tParams, args)
  if idBinding ~= MQTT_BINDING then
    return
  end
  MqttDevice:setConnected(true)
  subscribed = {}
  syncSubscriptions()
  MqttDevice:subscribeToAvailability(Properties["Availability Topic"], tostring(C4:GetDeviceID()))
  updateOnline()
  requestState("broker connected")
  requestTasmotaList()
end

function RFP.BROKER_DISCONNECTED(idBinding, strCommand, tParams, args)
  log:trace("RFP.BROKER_DISCONNECTED(%s, %s, %s, %s)", idBinding, strCommand, tParams, args)
  if idBinding ~= MQTT_BINDING then
    return
  end
  MqttDevice:setConnected(false)
  subscribed = {}
  updateOnline()
end

--- Commands from the light_v2 proxy.
RFP[LIGHT_PROXY_BINDING] = function(idBinding, strCommand, tParams, _args)
  log:debug("Light command %s %s", strCommand, tParams)
  if not light:handleProxyCommand(strCommand, tParams or {}) then
    log:debug("Unhandled light command: %s", strCommand)
  end
end

-----------------------------------------------------------------------
-- On Binding Changed (OBC) handler
-----------------------------------------------------------------------

OBC[MQTT_BINDING] = function(idBinding, strClass, bIsBound, otherDeviceId, otherBindingId)
  log:trace("OBC[MQTT_BINDING](%s, %s, %s, %s, %s)", idBinding, strClass, bIsBound, otherDeviceId, otherBindingId)
  MqttDevice:reset()
  subscribed = {}
  UpdateProperty("Driver Status", "Disconnected")
  updateOnline()
  if bIsBound then
    SendToProxy(MQTT_BINDING, "GET_STATUS", {}, "NOTIFY")
  end
end

-----------------------------------------------------------------------
-- Execute Command (EC) handlers
-----------------------------------------------------------------------

function EC.MQTT_MESSAGE(tParams)
  log:trace("EC.MQTT_MESSAGE(%s)", tParams)
  local topic = Select(tParams, "topic")
  local payload = Select(tParams, "payload") or ""
  if IsEmpty(topic) then
    return
  end
  log:debug("Received MQTT message: topic=%s payload=%s", topic, payload)

  local availabilityTopic = Properties["Availability Topic"]
  if not IsEmpty(availabilityTopic) and topic == availabilityTopic then
    local wasAvailable = MqttDevice:isAvailable()
    MqttDevice:updateAvailability(payload, availabilityConfig())
    updateOnline()
    if MqttDevice:isAvailable() == true and wasAvailable ~= true then
      requestState("device online")
    end
  end

  if subscribed[topic] then
    lastPayloads[topic] = payload
  end
  light:onMessage(topic, payload)
end
