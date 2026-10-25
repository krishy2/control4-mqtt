--- MQTT Shutter Driver
--- A Control4 blind driver for MQTT shutters and blinds: Tasmota shutters,
--- Shelly Gen2+ covers, or any device with MQTT position and command topics.
---
--- Connects to an MQTT broker through the MQTT Broker driver and controls one
--- shutter's position, or its slats (Control: Tilt). The Control4 side follows
--- the stock 2 Relay Blinds driver (blind proxy).

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
local Shutter = require("mqtt.shutter")
local Tasmota = require("mqtt.tasmota")
local Shelly = require("mqtt.shelly")

-- Binding IDs
local BLIND_PROXY_BINDING = 5001
local MQTT_BINDING = 5002

local LEVEL_PERSIST_KEY = "ShutterLevel"
local SELECTION_PERSIST_KEY = "DiscoveredSelection"
local MANUAL = "(Manual)"

-- Discovered device choice. Declared here because start-up uses them.
--- Dropdown label -> { mac, id }
local discoveredChoices = {}
--- The chosen device and shutter, kept across restarts: { mac, id, label }
local discoveredSelection = nil
--- Set when a shutter is picked: rename the driver once its details arrive.
local renamePending = nil
local updateDiscoveredList, setDeviceNotes

--- Properties that make up the shutter configuration.
local CONFIG_PROPERTIES = {
  "Control",
  "Payload Mode",
  "Shelly Topic Prefix",
  "Shelly Component",
  "JSON State Topic",
  "JSON Command Topic",
  "Position Key",
  "Tilt Key",
  "State Key",
  "Moving Key",
  "Optimistic",
  "QoS",
  "Retain",
  "Travel Time (Seconds)",
  "Tilt Time (Seconds)",
  "Invert Position",
  "Position State Topic",
  "Position Value Path",
  "Position Command Topic",
  "Target Value Path",
  "Movement State Topic",
  "Movement Value Path",
  "Open Command Topic",
  "Open Payload",
  "Close Command Topic",
  "Close Payload",
  "Stop Command Topic",
  "Stop Payload",
  "Tilt State Topic",
  "Tilt Value Path",
  "Tilt Command Topic",
  "Tilt Min",
  "Tilt Max",
}

--- @type table
local shutter
--- Topics currently subscribed (availability is tracked by MqttDevice).
local subscribed = {}
--- Last payload per topic, replayed when the configuration changes.
local lastPayloads = {}

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

local function orDefault(v, default)
  return v ~= "" and v or default
end

--- Build the shutter configuration from properties.
local function buildConfig()
  local json = prop("Payload Mode") == Shutter.MODE_JSON
  local positionTopic = prop("Position State Topic")
  return {
    mode = prop("Payload Mode"),
    control = prop("Control"),
    optimistic = prop("Optimistic"),
    qos = orDefault(prop("QoS"), "0"),
    retain = prop("Retain") == "Yes",
    travelTime = tonumber(prop("Travel Time (Seconds)")) or 20,
    tiltTime = tonumber(prop("Tilt Time (Seconds)")) or 2,
    invert = prop("Invert Position") == "Yes",
    tiltMin = tonumber(prop("Tilt Min")) or 0,
    tiltMax = tonumber(prop("Tilt Max")) or 100,
    payloadOpen = json and orDefault(prop("Open Payload"), "OPEN") or prop("Open Payload"),
    payloadClose = json and orDefault(prop("Close Payload"), "CLOSE") or prop("Close Payload"),
    payloadStop = json and orDefault(prop("Stop Payload"), "STOP") or prop("Stop Payload"),
    shelly = { prefix = prop("Shelly Topic Prefix"), component = prop("Shelly Component") },
    topics = {
      position = {
        stateTopic = positionTopic,
        valuePath = prop("Position Value Path"),
        commandTopic = prop("Position Command Topic"),
      },
      target = {
        stateTopic = prop("Target Value Path") ~= "" and positionTopic or "",
        valuePath = prop("Target Value Path"),
      },
      state = { stateTopic = prop("Movement State Topic"), valuePath = prop("Movement Value Path") },
      tilt = {
        stateTopic = prop("Tilt State Topic"),
        valuePath = prop("Tilt Value Path"),
        commandTopic = prop("Tilt Command Topic"),
      },
      open = { commandTopic = prop("Open Command Topic"), payload = prop("Open Payload") },
      close = { commandTopic = prop("Close Command Topic"), payload = prop("Close Payload") },
      stop = { commandTopic = prop("Stop Command Topic"), payload = prop("Stop Payload") },
    },
    json = {
      stateTopic = prop("JSON State Topic"),
      commandTopic = prop("JSON Command Topic"),
      keys = {
        position = prop("Position Key"),
        tilt = prop("Tilt Key"),
        state = prop("State Key"),
        moving = prop("Moving Key"),
      },
    },
  }
end

--- Show or hide configuration properties for the current mode.
local function updatePropertyVisibility()
  local shelly = shutter:isShelly()
  local json = shutter:isJson()
  local topics = not json and not shelly
  local tilt = shutter:isTilt()
  local rules = {
    ["Shelly Topic Prefix"] = shelly,
    ["Shelly Component"] = shelly,
    ["JSON State Topic"] = json,
    ["JSON Command Topic"] = json,
    ["Position Key"] = json and not tilt,
    ["Tilt Key"] = json and tilt,
    ["State Key"] = json,
    ["Moving Key"] = json,
    ["Invert Position"] = not tilt,
    ["Travel Time (Seconds)"] = not tilt,
    ["Tilt Time (Seconds)"] = tilt,
    ["Position"] = topics and not tilt,
    ["Position State Topic"] = topics and not tilt,
    ["Position Value Path"] = topics and not tilt,
    ["Position Command Topic"] = topics and not tilt,
    ["Target Value Path"] = topics and not tilt,
    ["Movement State Topic"] = topics,
    ["Movement Value Path"] = topics,
    ["Commands"] = not shelly,
    ["Open Command Topic"] = topics and not tilt,
    ["Open Payload"] = not shelly and not tilt,
    ["Close Command Topic"] = topics and not tilt,
    ["Close Payload"] = not shelly and not tilt,
    ["Stop Command Topic"] = topics,
    ["Stop Payload"] = not shelly,
    ["Tilt"] = not shelly and tilt,
    ["Tilt State Topic"] = topics and tilt,
    ["Tilt Value Path"] = topics and tilt,
    ["Tilt Command Topic"] = topics and tilt,
    ["Tilt Min"] = not shelly and tilt,
    ["Tilt Max"] = not shelly and tilt,
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

--- What the shutter can do, for the Capabilities property.
local function describeCapabilities()
  local c = shutter.caps
  local parts = {}
  if shutter:isTilt() then
    parts[#parts + 1] = c.hasLevel and "Slat position" or "Slats open/close"
  else
    parts[#parts + 1] = c.hasLevel and "Position" or "Open/Close"
  end
  if c.canStop then
    parts[#parts + 1] = "Stop"
  end
  if not shutter:hasStateFeedback() then
    parts[#parts + 1] = "no state feedback"
  end
  return table.concat(parts, ", ")
end

-----------------------------------------------------------------------
-- Subscriptions, state request
-----------------------------------------------------------------------

local function syncSubscriptions()
  if not MqttDevice:isConnected() then
    return
  end
  local deviceId = tostring(C4:GetDeviceID())
  local wanted = {}
  for _, t in ipairs(shutter:subscriptions()) do
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
      SendToProxy(MQTT_BINDING, "SUBSCRIBE", { topic = t, qos = shutter.cfg.qos or "0", device_id = deviceId })
      subscribed[t] = true
    end
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
    qos = shutter.cfg.qos or "0",
    retain = "false",
  })
end

local function updateStatus()
  if not MqttDevice:isConnected() then
    UpdateProperty("Driver Status", "Disconnected")
  elseif MqttDevice:isAvailable() == false then
    UpdateProperty("Driver Status", "Device offline")
  else
    UpdateProperty("Driver Status", "Connected")
  end
end

--- Re-read properties, update capabilities, subscriptions and visibility.
local function applyConfig(force)
  local changed = shutter:configure(buildConfig())
  UpdateProperty("Capabilities", describeCapabilities())
  if changed or force then
    log:info("Shutter capabilities: %s", describeCapabilities())
    shutter:refreshProxy()
  end
  updatePropertyVisibility()
  syncSubscriptions()
  if not IsEmpty(lastPayloads) then
    shutter:resetState()
    for t, payload in pairs(lastPayloads) do
      shutter:onMessage(t, payload)
    end
  end
end

-----------------------------------------------------------------------
-- Open, Close and Toggle button links (keypad buttons) and their LEDs
-----------------------------------------------------------------------

local LINKS = {
  { binding = 300, name = "Open" },
  { binding = 301, name = "Close" },
  { binding = 302, name = "Toggle" },
}
-- Holding a button this long moves the shutter until it is released.
local HOLD_DELAY_MS = 500

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
  local onDefault = link.name == "Close" and "000000" or "0000ff"
  local offDefault = link.name == "Close" and "0000ff" or "000000"
  return ledColor(Properties[link.name .. " Button LED When Open"], onDefault),
    ledColor(Properties[link.name .. " Button LED When Closed"], offDefault)
end

local function linkIsBound(link)
  return C4:GetBoundConsumerDevices(0, link.binding) ~= nil
end

local ledState = nil

local function sendLinkColors(link)
  local whenOpen, whenClosed = linkColors(link)
  SendToProxy(link.binding, "BUTTON_COLORS", { ON_COLOR = whenOpen, OFF_COLOR = whenClosed }, "NOTIFY")
  SendToProxy(link.binding, "MATCH_LED_STATE", { STATE = tostring(shutter:isOpen()) })
end

--- Keypads follow the shutter: lit (open color) while open, closed color while closed.
local function updateButtonLeds(force)
  if shutter == nil then
    return
  end
  local open = shutter:isOpen()
  if not force and open == ledState then
    return
  end
  ledState = open
  for _, link in ipairs(LINKS) do
    if linkIsBound(link) then
      if force then
        sendLinkColors(link)
      else
        SendToProxy(link.binding, "MATCH_LED_STATE", { STATE = tostring(open) })
      end
    end
  end
end

--- A tap: Open opens, Close closes, Toggle opens or closes; any tap while moving stops.
local function clickLink(link)
  if shutter.moving then
    shutter:stop()
  elseif link.name == "Open" then
    shutter:open()
  elseif link.name == "Close" then
    shutter:close()
  else
    shutter:toggle()
  end
end

local holding = {}

for _, link in ipairs(LINKS) do
  RFP[link.binding] = function(idBinding, strCommand, tParams, _args)
    log:debug("%s Button Link: %s", link.name, strCommand)
    local timer = "Hold" .. link.binding
    if strCommand == "DO_PUSH" then
      holding[link.binding] = false
      SetTimer(timer, HOLD_DELAY_MS, function()
        holding[link.binding] = true
        if link.name == "Open" then
          shutter:open()
        elseif link.name == "Close" then
          shutter:close()
        else
          shutter:toggle()
        end
      end)
    elseif strCommand == "DO_CLICK" then
      CancelTimer(timer)
      if holding[link.binding] then
        shutter:stop()
      else
        clickLink(link)
      end
      holding[link.binding] = nil
    elseif strCommand == "DO_RELEASE" then
      CancelTimer(timer)
      if holding[link.binding] then
        shutter:stop()
      elseif holding[link.binding] == false then
        clickLink(link)
      end
      holding[link.binding] = nil
    elseif strCommand == "REQUEST_BUTTON_COLORS" then
      sendLinkColors(link)
    end
  end
  OBC[link.binding] = function(idBinding, strClass, bIsBound)
    if bIsBound then
      sendLinkColors(link)
    end
  end
  for _, when in ipairs({ "Open", "Closed" }) do
    OPC[(link.name .. "_Button_LED_When_" .. when)] = function()
      if gInitialized and linkIsBound(link) then
        sendLinkColors(link)
      end
    end
  end
end

local function onShutterStateChanged()
  UpdateProperty("Shutter State", shutter:stateText())
  if shutter.level ~= nil then
    persist:set(LEVEL_PERSIST_KEY, shutter.level)
  end
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
  shutter = Shutter.new({
    proxyBinding = BLIND_PROXY_BINDING,
    brokerBinding = MQTT_BINDING,
    onStateChanged = onShutterStateChanged,
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

  applyConfig(true)
  -- Control4 shows the last known level until the device reports.
  local level = tonumber(persist:get(LEVEL_PERSIST_KEY, nil))
  if level ~= nil then
    shutter.level = level
    shutter:refreshProxy()
  end
  UpdateProperty("Shutter State", shutter:stateText())
  updateStatus()
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
-- Discovery (Tasmota and Shelly): pick a shutter, every setting follows
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

local function codecFor(dev)
  return dev.type == "shelly" and Shelly or Tasmota
end

local function renameAfterDevice(dev, id)
  local name = codecFor(dev).shutterName(dev, id)
  if IsEmpty(name) then
    return
  end
  if shutter:isTilt() then
    name = name .. " Slats"
  end
  if not C4.RenameDevice then
    log:warn("This controller cannot rename drivers; name the shutter '%s' in Composer", name)
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
  log:print("Renamed the shutter to '%s'", name)
end

--- Fill in every setting for the chosen device and shutter.
local function applyDiscoveredDevice(dev)
  local selection = discoveredSelection
  if selection == nil then
    return
  end
  local codec = codecFor(dev)
  local props, err = codec.shutterProperties(dev, selection.id)
  if props == nil then
    setDeviceNotes("This shutter no longer exists on " .. tostring(dev.topic) .. " (" .. tostring(err) .. ")")
    return
  end
  local notes = {}
  local info
  for _, s in ipairs(codec.shutters(dev)) do
    if s.id == selection.id then
      info = s
    end
  end
  if shutter:isTilt() and info and not info.tilt then
    notes[#notes + 1] = dev.type == "shelly" and "Slat control is off on this Shelly cover; turn it on in its settings."
      or "Tilt is not set up on this Tasmota shutter (ShutterTiltConfig)."
  end
  local changed = 0
  for name, value in pairs(props) do
    if Properties[name] ~= nil and Properties[name] ~= value then
      UpdateProperty(name, value)
      Properties[name] = value
      changed = changed + 1
    end
  end
  log:info("Applied %s device %s (%s): %d settings changed", dev.type or "tasmota", dev.topic, selection.id, changed)
  setDeviceNotes(table.concat(notes, " "))

  if renamePending and renamePending.mac == selection.mac and renamePending.id == selection.id then
    renamePending = nil
    local ok, renameErr = pcall(renameAfterDevice, dev, selection.id)
    if not ok then
      log:warn("Could not rename the shutter: %s", renameErr)
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
    discoveredSelection = nil
    persist:set(SELECTION_PERSIST_KEY, nil)
    setDeviceNotes("")
    return
  end
  local choice = discoveredChoices[propertyValue]
  if choice == nil then
    return
  end
  local previous = discoveredSelection
  discoveredSelection = { mac = choice.mac, id = choice.id, label = propertyValue }
  persist:set(SELECTION_PERSIST_KEY, discoveredSelection)
  if previous == nil or previous.mac ~= choice.mac or previous.id ~= choice.id then
    renamePending = { mac = choice.mac, id = choice.id }
  end
  requestDiscoveredDevice(choice.mac)
end

--- The broker's list of discovered devices: their shutters go in the dropdown.
function EC.TASMOTA_DEVICES(tParams)
  local ok, list = pcall(JSON.decode, JSON, Select(tParams, "devices") or "[]")
  if not ok or type(list) ~= "table" then
    log:warn("Could not read the discovered device list")
    return
  end
  discoveredChoices = {}
  for _, dev in ipairs(list) do
    for _, s in ipairs(dev.shutters or {}) do
      local label = string.format("%s [%s] %s", tostring(dev.name), tostring(dev.topic), tostring(s.label))
      if s.tilt then
        label = label .. " (tilt)"
      end
      label = label:gsub(",", " ")
      discoveredChoices[label] = { mac = dev.mac, id = s.id }
      if discoveredSelection and discoveredSelection.mac == dev.mac and discoveredSelection.id == s.id then
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

--- Commands from the blind proxy.
RFP[BLIND_PROXY_BINDING] = function(idBinding, strCommand, tParams, _args)
  log:debug("Blind command %s %s", strCommand, tParams)
  if not shutter:handleProxyCommand(strCommand, tParams or {}) then
    log:debug("Unhandled blind command: %s", strCommand)
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
  shutter:onMessage(t, payload)
end

function EC.RequestState()
  lastStateRequest = nil
  requestState("Request State action")
end

--- Programming commands (also for testing from Composer's Lua window).
function EC.Open()
  shutter:open()
end

function EC.Close()
  shutter:close()
end

function EC.Stop()
  shutter:stop()
end
