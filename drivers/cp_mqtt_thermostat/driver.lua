--- MQTT Thermostat Driver
--- A Control4 thermostat (thermostatV2 proxy) for MQTT thermostats: the
--- Tasmota Thermostat driver, TuyaMCU thermostats running Tasmota, or any
--- device with MQTT topics. An ability exists when its topic is filled in.

require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

local log = require("lib.logging")
local events = require("lib.events")
local values = require("lib.values")
local constants = require("constants")

local AutoBind = require("mqtt.autobind")
local MqttDevice = require("mqtt.entities.device")
local Thermostat = require("mqtt.thermostat")

-- Binding IDs
local THERMOSTAT_PROXY_BINDING = 5001
local MQTT_BINDING = 5002

--- Property name prefix -> feature key
local FEATURES = {
  { key = "temperature", prefix = "Temperature", state = "Temperature State Topic", path = "Temperature Value Path" },
  { key = "humidity", prefix = "Humidity", state = "Humidity State Topic", path = "Humidity Value Path" },
  { key = "heat", prefix = "Heat Setpoint" },
  { key = "cool", prefix = "Cool Setpoint" },
  { key = "mode", prefix = "Mode" },
  { key = "fan", prefix = "Fan Mode" },
}

--- Properties that make up the configuration.
local CONFIG_PROPERTIES = {
  "Device Temperature Scale",
  "Temperature Multiplier",
  "Setpoint Min",
  "Setpoint Max",
  "Setpoint Step",
  "Optimistic",
  "QoS",
  "Retain",
  "Temperature State Topic",
  "Temperature Value Path",
  "Humidity State Topic",
  "Humidity Value Path",
  "Heat Setpoint State Topic",
  "Heat Setpoint Value Path",
  "Heat Setpoint Command Topic",
  "Heat Setpoint Command Payload",
  "Cool Setpoint State Topic",
  "Cool Setpoint Value Path",
  "Cool Setpoint Command Topic",
  "Cool Setpoint Command Payload",
  "Mode State Topic",
  "Mode Value Path",
  "Mode Command Topic",
  "Mode Command Payload",
  "Mode Values",
  "Power State Topic",
  "Power Value Path",
  "Power Command Topic",
  "Power Payload On",
  "Power Payload Off",
  "Power State On",
  "Power State Off",
  "HVAC State Topic",
  "HVAC State Value Path",
  "HVAC State Values",
  "Fan Mode State Topic",
  "Fan Mode Value Path",
  "Fan Mode Command Topic",
  "Fan Mode Command Payload",
  "Fan Mode Values",
}

--- @type table
local thermostat
local subscribed = {}
local lastPayloads = {}
local lastConnected = nil

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

local function buildConfig()
  local features = {}
  for _, f in ipairs(FEATURES) do
    features[f.key] = {
      stateTopic = prop(f.state or (f.prefix .. " State Topic")),
      valuePath = prop(f.path or (f.prefix .. " Value Path")),
      commandTopic = prop(f.prefix .. " Command Topic"),
      template = prop(f.prefix .. " Command Payload"),
      values = prop(f.prefix .. " Values"),
    }
  end
  features.power = {
    stateTopic = prop("Power State Topic"),
    valuePath = prop("Power Value Path"),
    commandTopic = prop("Power Command Topic"),
    payloadOn = prop("Power Payload On"),
    payloadOff = prop("Power Payload Off"),
    stateOn = prop("Power State On"),
    stateOff = prop("Power State Off"),
  }
  features.action = {
    stateTopic = prop("HVAC State Topic"),
    valuePath = prop("HVAC State Value Path"),
    values = prop("HVAC State Values"),
  }
  return {
    scale = prop("Device Temperature Scale") == "Fahrenheit" and "F" or "C",
    multiplier = tonumber(prop("Temperature Multiplier")) or 1,
    setpointMin = tonumber(prop("Setpoint Min")),
    setpointMax = tonumber(prop("Setpoint Max")),
    setpointStep = tonumber(prop("Setpoint Step")),
    optimistic = prop("Optimistic"),
    qos = prop("QoS") ~= "" and prop("QoS") or "0",
    retain = prop("Retain") == "Yes",
    features = features,
  }
end

local function describeCapabilities()
  local c = thermostat.caps
  local parts = {}
  if c.temperature then
    parts[#parts + 1] = "Temperature"
  end
  if c.single then
    parts[#parts + 1] = "Single setpoint"
  else
    if c.heat then
      parts[#parts + 1] = "Heat"
    end
    if c.cool then
      parts[#parts + 1] = "Cool"
    end
  end
  parts[#parts + 1] = "Modes " .. c.modes
  if c.fanModes ~= "" then
    parts[#parts + 1] = "Fan " .. c.fanModes
  end
  if c.humidity then
    parts[#parts + 1] = "Humidity"
  end
  return table.concat(parts, ", ")
end

local function updateAvailabilityPropertyVisibility()
  local hasAvailabilityTopic = not IsEmpty(Properties["Availability Topic"])
  local vis = hasAvailabilityTopic and constants.SHOW_PROPERTY or constants.HIDE_PROPERTY
  for _, name in ipairs({
    "Availability Topic Value",
    "Availability Status",
    "Payload Available",
    "Payload Not Available",
    "Availability Value Path",
  }) do
    C4:SetPropertyAttribs(name, vis)
  end
  local hasAvailPath = not IsEmpty(Properties["Availability Value Path"])
  C4:SetPropertyAttribs(
    "Availability Value Path Result",
    (hasAvailabilityTopic and hasAvailPath) and constants.SHOW_PROPERTY or constants.HIDE_PROPERTY
  )
end

-----------------------------------------------------------------------
-- Subscriptions, connection, state request
-----------------------------------------------------------------------

local function syncSubscriptions()
  if not MqttDevice:isConnected() then
    return
  end
  local deviceId = tostring(C4:GetDeviceID())
  local wanted = {}
  for _, t in ipairs(thermostat:subscriptions()) do
    wanted[t] = true
  end
  for t in pairs(subscribed) do
    if not wanted[t] then
      SendToProxy(MQTT_BINDING, "UNSUBSCRIBE", { topic = t, device_id = deviceId })
      subscribed[t] = nil
      lastPayloads[t] = nil
    end
  end
  for t in pairs(wanted) do
    if not subscribed[t] then
      SendToProxy(MQTT_BINDING, "SUBSCRIBE", { topic = t, qos = thermostat.cfg.qos or "0", device_id = deviceId })
      subscribed[t] = true
    end
  end
end

--- Tell the proxy whether the thermostat is reachable.
local function updateConnection(force)
  local connected = MqttDevice:isConnected() and MqttDevice:isAvailable() ~= false
  if not MqttDevice:isConnected() then
    UpdateProperty("Driver Status", "Disconnected")
  elseif MqttDevice:isAvailable() == false then
    UpdateProperty("Driver Status", "Device offline")
  else
    UpdateProperty("Driver Status", "Connected")
  end
  if force or connected ~= lastConnected then
    lastConnected = connected
    thermostat:setConnected(connected)
  end
end

local lastStateRequest = nil

local function requestState(reason)
  local t = Properties["State Request Topic"]
  if IsEmpty(t) or not MqttDevice:isConnected() then
    return
  end
  local now = C4:GetTime()
  if lastStateRequest ~= nil and now - lastStateRequest < 2000 then
    return
  end
  lastStateRequest = now
  log:debug("Requesting device state (%s): %s", reason, t)
  SendToProxy(MQTT_BINDING, "PUBLISH", {
    topic = t,
    payload = Properties["State Request Payload"] or "",
    qos = thermostat.cfg.qos or "0",
    retain = "false",
  })
end

local function applyConfig(force)
  local changed = thermostat:configure(buildConfig())
  UpdateProperty("Capabilities", describeCapabilities())
  if changed or force then
    log:info("Thermostat capabilities: %s", describeCapabilities())
    thermostat:refreshProxy()
  end
  syncSubscriptions()
  if not IsEmpty(lastPayloads) then
    thermostat:resetState()
    for t, payload in pairs(lastPayloads) do
      thermostat:onMessage(t, payload)
    end
  end
end

-----------------------------------------------------------------------
-- Driver lifecycle
-----------------------------------------------------------------------

local function connectToBroker()
  local function try()
    local ok, err = pcall(AutoBind.connectSelf, MQTT_BINDING)
    if not ok then
      log:warn("Could not connect to the MQTT Broker driver automatically: %s", err)
    end
  end
  try()
  SetTimer("AutoBind", 15 * ONE_SECOND, try)
end

function OnDriverInit()
  C4:AllowExecute(true)
  gInitialized = false
  log:setLogName(C4:GetDeviceData(C4:GetDeviceID(), "name"))
  log:setLogLevel(Properties["Log Level"])
  log:setLogMode(Properties["Log Mode"])
  log:trace("OnDriverInit()")
  MqttDevice:init(MQTT_BINDING)
  thermostat = Thermostat.new({
    proxyBinding = THERMOSTAT_PROXY_BINDING,
    brokerBinding = MQTT_BINDING,
    onStateChanged = function(t)
      UpdateProperty("Thermostat State", t:stateText())
    end,
  })
  events:restoreEvents()
  values:restoreValues()
end

function OnDriverLateInit()
  log:trace("OnDriverLateInit()")
  if not CheckMinimumVersion("Driver Status") then
    return
  end
  UpdateProperty("Driver Status", "Initializing")
  for p, _ in pairs(Properties) do
    local status, err = pcall(OnPropertyChanged, p)
    if not status and err ~= nil then
      log:error(err)
    end
  end
  gInitialized = true
  MqttDevice:registerAvailabilityEvents(not IsEmpty(Properties["Availability Topic"]))
  updateAvailabilityPropertyVisibility()
  applyConfig(true)
  UpdateProperty("Thermostat State", thermostat:stateText())
  updateConnection(true)
  connectToBroker()
  SendToProxy(MQTT_BINDING, "GET_STATUS", {}, "NOTIFY")
end

-----------------------------------------------------------------------
-- Property change handlers
-----------------------------------------------------------------------

function OPC.Driver_Version()
  C4:UpdateProperty("Driver Version", C4:GetDriverConfigInfo("version"))
end

function OPC.Log_Mode(propertyValue)
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
  log:setLogLevel(propertyValue)
  local debug = log:getLogLevel() >= 6 and log:isPrintEnabled()
  DEBUGPRINT, DEBUG_TIMER, DEBUG_RFN, DEBUG_URL = debug, debug, debug, debug
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
  updateConnection()
end

function OPC.Payload_Available(propertyValue)
  if gInitialized then
    MqttDevice:reevaluateAvailability(availabilityConfig({ payloadAvailable = propertyValue }))
    updateConnection()
  end
end

function OPC.Payload_Not_Available(propertyValue)
  if gInitialized then
    MqttDevice:reevaluateAvailability(availabilityConfig({ payloadNotAvailable = propertyValue }))
    updateConnection()
  end
end

function OPC.Availability_Value_Path(propertyValue)
  if gInitialized then
    MqttDevice:reevaluateAvailability(availabilityConfig({ valuePath = propertyValue }))
    updateAvailabilityPropertyVisibility()
    updateConnection()
  end
end

local function handlerName(name)
  local s = string.gsub(name, "%W", "_")
  s = string.gsub(s, "[_]+", "_")
  s = string.gsub(s, "^[_| ]+", "")
  s = string.gsub(s, "[_| ]+$", "")
  return s
end

local function onConfigPropertyChanged()
  if gInitialized then
    applyConfig(false)
  end
end

for _, name in ipairs(CONFIG_PROPERTIES) do
  OPC[handlerName(name)] = onConfigPropertyChanged
end

-----------------------------------------------------------------------
-- Receive From Proxy (RFP) handlers
-----------------------------------------------------------------------

function RFP.BROKER_CONNECTED(idBinding)
  if idBinding ~= MQTT_BINDING then
    return
  end
  MqttDevice:setConnected(true)
  subscribed = {}
  syncSubscriptions()
  MqttDevice:subscribeToAvailability(Properties["Availability Topic"], tostring(C4:GetDeviceID()))
  updateConnection()
  requestState("broker connected")
end

function RFP.BROKER_DISCONNECTED(idBinding)
  if idBinding ~= MQTT_BINDING then
    return
  end
  MqttDevice:setConnected(false)
  subscribed = {}
  updateConnection()
end

--- Commands from the thermostatV2 proxy.
RFP[THERMOSTAT_PROXY_BINDING] = function(idBinding, strCommand, tParams, _args)
  log:debug("Thermostat command %s %s", strCommand, tParams)
  if not thermostat:handleProxyCommand(strCommand, tParams or {}) then
    log:debug("Unhandled thermostat command: %s", strCommand)
  end
end

OBC[MQTT_BINDING] = function(idBinding, strClass, bIsBound)
  MqttDevice:reset()
  subscribed = {}
  updateConnection()
  if bIsBound then
    SendToProxy(MQTT_BINDING, "GET_STATUS", {}, "NOTIFY")
  end
end

-----------------------------------------------------------------------
-- Execute Command (EC) handlers
-----------------------------------------------------------------------

function EC.MQTT_MESSAGE(tParams)
  local t = Select(tParams, "topic")
  local payload = Select(tParams, "payload") or ""
  if IsEmpty(t) then
    return
  end
  log:debug("Received MQTT message: topic=%s payload=%s", t, payload)
  local availabilityTopic = Properties["Availability Topic"]
  if not IsEmpty(availabilityTopic) and t == availabilityTopic then
    local wasAvailable = MqttDevice:isAvailable()
    MqttDevice:updateAvailability(payload, availabilityConfig())
    updateConnection()
    if MqttDevice:isAvailable() == true and wasAvailable ~= true then
      requestState("device online")
    end
  end
  if subscribed[t] then
    lastPayloads[t] = payload
  end
  thermostat:onMessage(t, payload)
end

function EC.RequestState()
  lastStateRequest = nil
  requestState("Request State action")
end
