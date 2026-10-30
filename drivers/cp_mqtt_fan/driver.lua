--- MQTT Fan Driver
--- A Control4 fan driver for MQTT fans: Tasmota iFan, Zigbee2MQTT fans, or any
--- device with MQTT power, speed and direction topics.
---
--- Connects to an MQTT broker through the MQTT Broker driver and controls one
--- fan. The fan's abilities follow from the topics (or JSON keys) that are
--- filled in: On/Off always, then Speeds and Reverse. Control4 always shows 6
--- speed levels (the fan proxy's capabilities are fixed in driver.xml); the
--- model maps the device's own speeds onto them.

require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

local log = require("lib.logging")
local persist = require("lib.persist")
local events = require("lib.events")
local values = require("lib.values")
local constants = require("constants")

local AutoBind = require("mqtt.autobind")
local MqttDevice = require("mqtt.entities.device")
local Fan = require("mqtt.fan")
local Tasmota = require("mqtt.tasmota")

-- Binding IDs
local FAN_PROXY_BINDING = 5001
local MQTT_BINDING = 5002

local STATE_PERSIST_KEY = "FanState"
local SELECTION_PERSIST_KEY = "DiscoveredSelection"
local MANUAL = "(Manual)"

-- Discovered device choice. Declared here because start-up uses them.
--- Dropdown label -> { mac, id }
local discoveredChoices = {}
--- The chosen device and fan, kept across restarts: { mac, id, label }
local discoveredSelection = nil
--- Set when a fan is picked: rename the driver once its details arrive.
local renamePending = nil
local updateDiscoveredList, setDeviceNotes

--- Properties that make up the fan configuration.
local CONFIG_PROPERTIES = {
  "Payload Mode",
  "JSON State Topic",
  "JSON Command Topic",
  "Optimistic",
  "QoS",
  "Retain",
  "On Speed",
  "Power State Topic",
  "Power Value Path",
  "Power Command Topic",
  "State Key",
  "State On",
  "State Off",
  "Payload On",
  "Payload Off",
  "Speed State Topic",
  "Speed Value Path",
  "Speed Command Topic",
  "Speed Key",
  "Speed Count",
  "Speed Values",
  "Speed Off Value",
  "Speed Mapping",
  "Direction State Topic",
  "Direction Value Path",
  "Direction Command Topic",
  "Direction Key",
  "Direction Forward",
  "Direction Reverse",
}

--- @type table
local fan
--- Topics currently subscribed (availability is tracked by MqttDevice).
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

--- Build the fan configuration from properties.
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
    onSpeed = prop("On Speed"),
    stateOn = prop("State On"),
    stateOff = prop("State Off"),
    payloadOn = prop("Payload On"),
    payloadOff = prop("Payload Off"),
    speedCount = tonumber(prop("Speed Count")) or 3,
    speedValues = prop("Speed Values"),
    speedOff = prop("Speed Off Value"),
    mapping = prop("Speed Mapping"),
    directionForward = prop("Direction Forward"),
    directionReverse = prop("Direction Reverse"),
    topics = {
      power = feature("Power"),
      speed = feature("Speed"),
      direction = feature("Direction"),
    },
    json = {
      stateTopic = prop("JSON State Topic"),
      commandTopic = prop("JSON Command Topic"),
      keys = {
        power = prop("State Key"),
        speed = prop("Speed Key"),
        direction = prop("Direction Key"),
      },
    },
  }
end

--- Show or hide configuration properties for the current mode and capabilities.
local function updatePropertyVisibility()
  local json = fan:isJson()
  local topics = not json
  local caps = fan.caps
  local t = fan.cfg.topics or {}
  local function filled(feature, which)
    return not IsEmpty((t[feature] or {})[which])
  end
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
    ["Speed State Topic"] = topics,
    ["Speed Value Path"] = topics and filled("speed", "stateTopic"),
    ["Speed Command Topic"] = topics,
    ["Speed Key"] = json,
    ["Speed Count"] = caps.hasSpeed and #Fan.splitValues(fan.cfg.speedValues) == 0,
    ["Speed Values"] = caps.hasSpeed,
    ["Speed Off Value"] = caps.hasSpeed,
    ["Speed Mapping"] = caps.hasSpeed,
    ["Direction State Topic"] = topics,
    ["Direction Value Path"] = topics and filled("direction", "stateTopic"),
    ["Direction Command Topic"] = topics,
    ["Direction Key"] = json,
    ["Direction Forward"] = caps.reverse,
    ["Direction Reverse"] = caps.reverse,
  }
  for name, visible in pairs(rules) do
    C4:SetPropertyAttribs(name, visible and constants.SHOW_PROPERTY or constants.HIDE_PROPERTY)
  end
end

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
-- Subscriptions, online state, state request
-----------------------------------------------------------------------

local function syncSubscriptions()
  if not MqttDevice:isConnected() then
    return
  end
  local deviceId = tostring(C4:GetDeviceID())
  local wanted = {}
  for _, t in ipairs(fan:subscriptions()) do
    wanted[t] = true
  end
  for t in pairs(subscribed) do
    if not wanted[t] then
      log:debug("Unsubscribing from %s", t)
      SendToProxy(MQTT_BINDING, "UNSUBSCRIBE", { topic = t, device_id = deviceId })
      subscribed[t] = nil
      lastPayloads[t] = nil
    end
  end
  for t in pairs(wanted) do
    if not subscribed[t] then
      log:debug("Subscribing to %s", t)
      SendToProxy(MQTT_BINDING, "SUBSCRIBE", { topic = t, qos = fan.cfg.qos or "0", device_id = deviceId })
      subscribed[t] = true
    end
  end
end

--- Driver Status, and whether the proxy shows the fan online.
local function updateStatus(force)
  if not MqttDevice:isConnected() then
    UpdateProperty("Driver Status", "Disconnected")
  elseif MqttDevice:isAvailable() == false then
    UpdateProperty("Driver Status", "Device offline")
  else
    UpdateProperty("Driver Status", "Connected")
  end
  local online = MqttDevice:isConnected() and MqttDevice:isAvailable() ~= false
  if force or online ~= lastOnline then
    lastOnline = online
    SendToProxy(FAN_PROXY_BINDING, "ONLINE_CHANGED", { STATE = tostring(online) }, "NOTIFY")
  end
end

local lastStateRequest = nil

--- Ask the device for its state (when the broker connects or the device comes online).
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
    qos = fan.cfg.qos or "0",
    retain = "false",
  })
end

--- Re-read properties, update capabilities, subscriptions and visibility.
local function applyConfig(force)
  local changed = fan:configure(buildConfig())
  UpdateProperty("Capabilities", fan:describeCapabilities())
  if changed or force then
    log:info("Fan capabilities: %s", fan:describeCapabilities())
    fan:refreshProxy()
  end
  updatePropertyVisibility()
  syncSubscriptions()
  if not IsEmpty(lastPayloads) then
    fan:resetState()
    for t, payload in pairs(lastPayloads) do
      fan:onMessage(t, payload)
    end
  end
end

-----------------------------------------------------------------------
-- Button links (keypad buttons) and their LEDs
-----------------------------------------------------------------------

local LINKS = {
  { binding = 300, name = "On", leds = "On" },
  { binding = 301, name = "Off", leds = "Off" },
  { binding = 302, name = "Toggle", leds = "Toggle" },
  { binding = 303, name = "Speed Up", leds = "Speed" },
  { binding = 304, name = "Speed Down", leds = "Speed" },
  { binding = 305, name = "Toggle Direction", leds = "Speed" },
}

--- A color property ("r,g,b" from a color picker, or "rrggbb") as "rrggbb".
local function ledColor(value, default)
  local s = tostring(value or ""):match("^%s*(.-)%s*$")
  local r, g, b = s:match("^(%d+)%s*,%s*(%d+)%s*,%s*(%d+)$")
  if r and tonumber(r) <= 255 and tonumber(g) <= 255 and tonumber(b) <= 255 then
    return string.format("%02x%02x%02x", tonumber(r), tonumber(g), tonumber(b))
  end
  local hex = s:match("^#?(%x%x%x%x%x%x)$")
  return hex and hex:lower() or default
end

local function linkColors(link)
  local onDefault = link.leds == "Off" and "000000" or "0000ff"
  local offDefault = link.leds == "Off" and "0000ff" or "000000"
  return ledColor(Properties[link.leds .. " Button LED When On"], onDefault),
    ledColor(Properties[link.leds .. " Button LED When Off"], offDefault)
end

local function linkIsBound(link)
  return C4:GetBoundConsumerDevices(0, link.binding) ~= nil
end

local ledState = nil

local function sendLinkColors(link)
  local whenOn, whenOff = linkColors(link)
  SendToProxy(link.binding, "BUTTON_COLORS", { ON_COLOR = whenOn, OFF_COLOR = whenOff }, "NOTIFY")
  SendToProxy(link.binding, "MATCH_LED_STATE", { STATE = tostring(fan:isOn()) })
end

--- Keypads follow the fan: the On color while it runs, the Off color while not.
local function updateButtonLeds(force)
  if fan == nil then
    return
  end
  local on = fan:isOn()
  if not force and on == ledState then
    return
  end
  ledState = on
  for _, link in ipairs(LINKS) do
    if linkIsBound(link) then
      if force then
        sendLinkColors(link)
      else
        SendToProxy(link.binding, "MATCH_LED_STATE", { STATE = tostring(on) })
      end
    end
  end
end

local function clickLink(link)
  if link.name == "On" then
    fan:on()
  elseif link.name == "Off" then
    fan:off()
  elseif link.name == "Toggle" then
    fan:toggle()
  elseif link.name == "Speed Up" then
    fan:speedUp()
  elseif link.name == "Speed Down" then
    fan:speedDown()
  else
    fan:toggleDirection()
  end
end

--- Bindings with a press that has not been acted on yet.
local pressed = {}

for _, link in ipairs(LINKS) do
  --- Keypads send DO_PUSH, then DO_CLICK; act once per press.
  RFP[link.binding] = function(idBinding, strCommand, tParams, _args)
    log:debug("%s Button Link: %s", link.name, strCommand)
    if strCommand == "DO_PUSH" then
      pressed[link.binding] = true
    elseif strCommand == "DO_CLICK" then
      pressed[link.binding] = nil
      clickLink(link)
    elseif strCommand == "DO_RELEASE" then
      if pressed[link.binding] then
        clickLink(link)
      end
      pressed[link.binding] = nil
    elseif strCommand == "REQUEST_BUTTON_COLORS" then
      sendLinkColors(link)
    end
  end
  OBC[link.binding] = function(idBinding, strClass, bIsBound)
    if bIsBound then
      sendLinkColors(link)
    end
  end
end

for _, leds in ipairs({ "On", "Off", "Toggle", "Speed" }) do
  for _, when in ipairs({ "On", "Off" }) do
    OPC[leds .. "_Button_LED_When_" .. when] = function()
      if not gInitialized then
        return
      end
      for _, link in ipairs(LINKS) do
        if link.leds == leds and linkIsBound(link) then
          sendLinkColors(link)
        end
      end
    end
  end
end

local function onFanStateChanged()
  UpdateProperty("Fan State", fan:stateText())
  persist:set(STATE_PERSIST_KEY, { level = fan.level, preset = fan.preset, lastSpeed = fan.lastSpeed })
  updateButtonLeds()
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
  fan = Fan.new({
    proxyBinding = FAN_PROXY_BINDING,
    brokerBinding = MQTT_BINDING,
    onStateChanged = onFanStateChanged,
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

  local hasAvailabilityTopic = not IsEmpty(Properties["Availability Topic"])
  MqttDevice:registerAvailabilityEvents(hasAvailabilityTopic)
  updateAvailabilityPropertyVisibility()

  -- Control4 shows the last known state until the device reports.
  local saved = persist:get(STATE_PERSIST_KEY, nil)
  if type(saved) == "table" then
    fan.preset = tonumber(saved.preset)
    fan.lastSpeed = tonumber(saved.lastSpeed)
    fan.level = tonumber(saved.level)
  end
  applyConfig(true)
  UpdateProperty("Fan State", fan:stateText())
  updateStatus(true)
  updateButtonLeds(true)

  discoveredSelection = persist:get(SELECTION_PERSIST_KEY, nil)
  updateDiscoveredList()
  setDeviceNotes("")

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
  updateStatus()
end

function OPC.Payload_Available(propertyValue)
  if gInitialized then
    MqttDevice:reevaluateAvailability(availabilityConfig({ payloadAvailable = propertyValue }))
    updateStatus()
  end
end

function OPC.Payload_Not_Available(propertyValue)
  if gInitialized then
    MqttDevice:reevaluateAvailability(availabilityConfig({ payloadNotAvailable = propertyValue }))
    updateStatus()
  end
end

function OPC.Availability_Value_Path(propertyValue)
  if gInitialized then
    MqttDevice:reevaluateAvailability(availabilityConfig({ valuePath = propertyValue }))
    updateAvailabilityPropertyVisibility()
    updateStatus()
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
-- Discovery (Tasmota iFan): pick a fan, every setting follows
-----------------------------------------------------------------------

local function deviceId()
  return tostring(C4:GetDeviceID())
end

local function requestDiscoveredList()
  SendToProxy(MQTT_BINDING, "GET_TASMOTA_DEVICES", { device_id = deviceId() })
end

local function requestDiscoveredDevice(mac)
  SendToProxy(MQTT_BINDING, "GET_TASMOTA_DEVICE", { device_id = deviceId(), mac = mac })
end

setDeviceNotes = function(text)
  UpdateProperty("Device Notes", text or "")
  C4:SetPropertyAttribs("Device Notes", IsEmpty(text) and constants.HIDE_PROPERTY or constants.SHOW_PROPERTY)
end

updateDiscoveredList = function()
  local labels = {}
  for label in pairs(discoveredChoices) do
    labels[#labels + 1] = label
  end
  table.sort(labels, function(a, b)
    return a:lower() < b:lower()
  end)
  local current = MANUAL
  if discoveredSelection ~= nil then
    current = discoveredSelection.label
    if discoveredChoices[current] == nil then
      labels[#labels + 1] = current
    end
  end
  table.insert(labels, 1, MANUAL)
  C4:UpdatePropertyList("Discovered Device", table.concat(labels, ","), current)
end

local function renameAfterDevice(dev, id)
  local name = Tasmota.fanName(dev, id)
  if IsEmpty(name) then
    return
  end
  if not C4.RenameDevice then
    log:warn("This controller cannot rename drivers; name the fan '%s' in Composer", name)
    return
  end
  local ids = { tonumber(C4:GetDeviceID()) }
  local proxies = C4.GetProxyDevices and C4:GetProxyDevices() or nil
  if type(proxies) == "table" then
    for pid in pairs(proxies) do
      ids[#ids + 1] = tonumber(pid)
    end
  elseif proxies ~= nil then
    for pid in tostring(proxies):gmatch("%d+") do
      ids[#ids + 1] = tonumber(pid)
    end
  end
  local seen = {}
  for _, did in ipairs(ids) do
    if did and not seen[did] then
      seen[did] = true
      if C4:GetDeviceDisplayName(did) ~= name then
        C4:RenameDevice(did, name)
      end
    end
  end
  log:setLogName(name)
  log:print("Renamed the fan to '%s'", name)
end

--- Fill in every setting for the chosen device's fan.
local function applyDiscoveredDevice(dev)
  local selection = discoveredSelection
  if selection == nil then
    return
  end
  local props, err = Tasmota.fanProperties(dev, selection.id)
  if props == nil then
    setDeviceNotes("This fan no longer exists on " .. tostring(dev.topic) .. " (" .. tostring(err) .. ")")
    return
  end
  local changed = 0
  for name, value in pairs(props) do
    if Properties[name] ~= nil and Properties[name] ~= value then
      UpdateProperty(name, value)
      Properties[name] = value
      changed = changed + 1
    end
  end
  log:info("Applied Tasmota device %s (%s): %d settings changed", dev.topic, selection.id, changed)
  setDeviceNotes(table.concat(Tasmota.notes(dev), " "))

  if renamePending and renamePending.mac == selection.mac and renamePending.id == selection.id then
    renamePending = nil
    local ok, renameErr = pcall(renameAfterDevice, dev, selection.id)
    if not ok then
      log:warn("Could not rename the fan: %s", renameErr)
    end
  end

  OnPropertyChanged("Availability Topic")
  OnPropertyChanged("Availability Value Path")
  applyConfig(false)
  requestState("discovered device applied")
end

function OPC.Discovered_Device(propertyValue)
  if not gInitialized then
    return
  end
  if IsEmpty(propertyValue) or propertyValue == MANUAL then
    if discoveredSelection ~= nil then
      log:info("Discovered device cleared; settings stay as they are")
    end
    discoveredSelection = nil
    persist:set(SELECTION_PERSIST_KEY, nil)
    setDeviceNotes("")
    return
  end
  local choice = discoveredChoices[propertyValue]
  if choice == nil then
    return -- the stored selection, shown before the list arrived
  end
  local previous = discoveredSelection
  discoveredSelection = { mac = choice.mac, id = choice.id, label = propertyValue }
  persist:set(SELECTION_PERSIST_KEY, discoveredSelection)
  if previous == nil or previous.mac ~= choice.mac or previous.id ~= choice.id then
    renamePending = { mac = choice.mac, id = choice.id }
  end
  requestDiscoveredDevice(choice.mac)
end

--- The broker's list of discovered devices: their fans go in the dropdown.
function EC.TASMOTA_DEVICES(tParams)
  local ok, list = pcall(JSON.decode, JSON, Select(tParams, "devices") or "[]")
  if not ok or type(list) ~= "table" then
    log:warn("Could not read the discovered device list")
    return
  end
  discoveredChoices = {}
  for _, dev in ipairs(list) do
    for _, f in ipairs(dev.fans or {}) do
      local label = string.format("%s [%s] %s", tostring(dev.name), tostring(dev.topic), tostring(f.label))
      label = label:gsub(",", " ")
      discoveredChoices[label] = { mac = dev.mac, id = f.id }
      if discoveredSelection and discoveredSelection.mac == dev.mac and discoveredSelection.id == f.id then
        if discoveredSelection.label ~= label then
          discoveredSelection.label = label
          persist:set(SELECTION_PERSIST_KEY, discoveredSelection)
        end
      end
    end
  end
  updateDiscoveredList()
end

function EC.TASMOTA_DEVICE(tParams)
  local mac = Select(tParams, "mac")
  if discoveredSelection == nil or mac ~= discoveredSelection.mac then
    return
  end
  local payload = Select(tParams, "device") or ""
  if payload == "" then
    setDeviceNotes("The broker does not know this device any more. Check that it is connected.")
    return
  end
  local ok, dev = pcall(JSON.decode, JSON, payload)
  if not ok or type(dev) ~= "table" then
    log:warn("Could not read discovered device %s", mac)
    return
  end
  applyDiscoveredDevice(dev)
end

function RFP.TASMOTA_DEVICES_CHANGED(idBinding, strCommand, tParams, args)
  if idBinding ~= MQTT_BINDING then
    return
  end
  local mac = Select(tParams, "mac")
  requestDiscoveredList()
  if discoveredSelection ~= nil and (IsEmpty(mac) or mac == discoveredSelection.mac) then
    requestDiscoveredDevice(discoveredSelection.mac)
  end
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
  updateStatus()
  requestState("broker connected")
  requestDiscoveredList()
end

function RFP.BROKER_DISCONNECTED(idBinding)
  if idBinding ~= MQTT_BINDING then
    return
  end
  MqttDevice:setConnected(false)
  subscribed = {}
  updateStatus()
end

--- Commands from the fan proxy.
RFP[FAN_PROXY_BINDING] = function(idBinding, strCommand, tParams, _args)
  log:debug("Fan command %s %s", strCommand, tParams)
  local presetBefore = fan.preset
  if not fan:handleProxyCommand(strCommand, tParams or {}) then
    log:debug("Unhandled fan command: %s", strCommand)
  end
  if fan.preset ~= presetBefore then
    onFanStateChanged()
  end
end

OBC[MQTT_BINDING] = function(idBinding, strClass, bIsBound)
  MqttDevice:reset()
  subscribed = {}
  updateStatus()
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
    updateStatus()
    if MqttDevice:isAvailable() == true and wasAvailable ~= true then
      requestState("device online")
    end
  end
  if subscribed[t] then
    lastPayloads[t] = payload
  end
  fan:onMessage(t, payload)
end

function EC.RequestState()
  lastStateRequest = nil
  requestState("Request State action")
end

--- Lua commands (also for testing from Composer's Lua window).
function EC.On()
  fan:on()
end

function EC.Off()
  fan:off()
end
