--- MQTT General w Webview Driver
--- A WebView driver, laid out like Control4's WebView driver (webview.c4z): a protocol
--- driver with a uibutton proxy, so it is an Experience button that can be shown in a
--- room's Comfort menu (or Listen, Watch, Security) on T4/T5 touch screens and in the
--- Control4 mobile apps. Unlike webview.c4z it does not open an outside URL: it
--- subscribes to MQTT topics through the MQTT Broker driver, keeps every value it
--- receives (JSON payloads are flattened) and shows them on a page the controller
--- serves from this driver's own c4z.
---
--- Data path: MQTT broker -> MQTT Broker driver -> this driver (EC.MQTT_MESSAGE)
---            -> C4:SendDataToUI / UIRequest -> web view JavaScript (C4 JS API).
--- Like the other drivers it binds itself to the MQTT Broker driver (mqtt.autobind).

require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

local log = require("lib.logging")
local persist = require("lib.persist")
local values = require("lib.values")
local AutoBind = require("mqtt.autobind")
local fields = require("mqtt.dashboard")

-- Binding IDs
local UI_BINDING = 5001 -- UI Button (Experience) proxy that hosts the web view
local MQTT_BINDING = 5002 -- Consumer connection to the MQTT Broker driver

-- Persistence keys
local VALUES_KEY = "DashboardValues"
local VARIABLES_KEY = "DashboardVariables"
local RECEIVED_KEY = "ReceivedFields"

-- Received Fields Action list items
local ACTION_SELECT = "(Select)"
local ACTION_COPY = "Copy All to Field Order"
local ACTION_CLEAR = "Clear"

-- Web view page inside this driver's www/ folder
local WEB_PATH = "dashboard/index.html"
local DEFAULT_DRIVER_NAME = "cp_mqtt_general_webview"

-- Like webview.c4z, wait for the uibutton proxy before sending it the URL and icon
local PROXY_READY_DELAY = 3 * ONE_SECOND

-- Variable that reports the worst graded reading (e.g. PM2.5, VOC, CO2)
local LEVEL_VARIABLE = "Air Quality"

-- Runtime state
local gConnected = false
local gSubscribed = {} -- topic -> true
local gValues = {} -- flattened key -> { value = any, ts = number, topic = string }
local gLastUpdate = nil -- epoch seconds of the last accepted message
local gLevel = nil -- current worst level
local gIconSent = nil
local gStale = false
local gWebUrl = nil
local gReceived = {} -- every field key ever received -> true

-----------------------------------------------------------------------
-- Helpers
-----------------------------------------------------------------------

--- Configured topics (comma or newline separated).
--- @return string[]
local function getTopics()
  return fields.parseList(Properties["MQTT Topics"])
end

--- Stale threshold in seconds (0 = never stale).
--- @return number
local function getStaleSeconds()
  return (tointeger(Properties["Stale After (minutes)"]) or 0) * 60
end

--- Map the Temperature Display property to a conversion mode understood by fields.build.
--- @return string
local function getTempConversion()
  local v = Properties["Temperature Display"] or ""
  if v == "As Received" then
    return "None"
  end
  return v
end

--- Display configuration read from properties.
--- @return table
local function getConfig()
  return {
    hidden = fields.parseList(Properties["Hidden Fields"]),
    order = fields.parseList(Properties["Field Order"]),
    overrides = fields.parseOverrides(Properties["Field Labels"]),
    tempConversion = getTempConversion(),
  }
end

--- Title shown at the top of the web view.
--- @return string
local function getTitle()
  local title = Properties["Title"]
  if IsEmpty(title) then
    title = C4:GetDeviceData(C4:GetDeviceID(), "name") or "MQTT"
  end
  return title
end

--- Resolve the controller:// URL of the web view from this driver's file name, so a
--- renamed .c4z keeps working (the URL must use the exact driver file name).
--- @return string
local function getWebUrl()
  local name
  local ok, filename = pcall(C4.GetDriverFileName, C4)
  if ok and type(filename) == "string" and filename ~= "" then
    name = string.gsub(filename, "%.c4z$", "")
  end
  if IsEmpty(name) then
    name = DEFAULT_DRIVER_NAME
  end
  return "controller://driver/" .. name .. "/" .. WEB_PATH
end

-----------------------------------------------------------------------
-- Persistence
-----------------------------------------------------------------------

--- Show every field ever received in the read-only Received Fields property.
local function updateReceivedProperty()
  UpdateProperty("Received Fields", table.concat(fields.catalog(gReceived), ","))
end

--- Remember field keys; returns true when a new one appeared.
--- @param keys table<string, any>
--- @return boolean
local function recordReceived(keys)
  local added = false
  for key in pairs(keys) do
    if not gReceived[key] then
      gReceived[key] = true
      added = true
    end
  end
  if added then
    persist:set(RECEIVED_KEY, gReceived)
    updateReceivedProperty()
  end
  return added
end

local function saveValues()
  persist:set(VALUES_KEY, { values = gValues, lastUpdate = gLastUpdate })
end

local function restoreValues()
  local saved = persist:get(VALUES_KEY, nil)
  if type(saved) == "table" and type(saved.values) == "table" then
    gValues = saved.values
    gLastUpdate = tonumber(saved.lastUpdate)
  end
  local received = persist:get(RECEIVED_KEY, nil)
  gReceived = type(received) == "table" and received or {}
  -- Values cached by an earlier version count as received
  for key in pairs(gValues) do
    gReceived[key] = true
  end
end

-----------------------------------------------------------------------
-- Dashboard model
-----------------------------------------------------------------------

--- Build the payload sent to the web view.
--- @return table
local function buildDashboard()
  local list = fields.build(gValues, getConfig())
  return {
    mqttDashboard = 1,
    title = getTitle(),
    theme = Properties["Theme"] or "Dark",
    connected = gConnected,
    topics = getTopics(),
    now = os.time(),
    updated = gLastUpdate,
    staleAfter = getStaleSeconds(),
    stale = gStale,
    level = fields.worstLevel(list),
    fields = list,
  }
end

--- JSON wrapped in an XML element: SendDataToUI and UIRequest both carry XML.
--- @param dashboard table|nil
--- @return string
local function dashboardXml(dashboard)
  local json = JSON:encode(dashboard or buildDashboard())
  return "<dashboard>" .. XMLEncode(json) .. "</dashboard>"
end

--- Push the dashboard to every subscribed navigator. Coalesced so a burst of MQTT
--- messages produces one update.
local function pushDashboard()
  SetTimer("PushDashboard", 250, function()
    local ok, err = pcall(function()
      C4:SendDataToUI(dashboardXml())
    end)
    if not ok then
      log:warn("SendDataToUI failed: %s", err)
    end
  end)
end

--- Update the navigator icon to reflect the worst graded reading.
--- @param level string|nil
local function sendIcon(level)
  local icon = level or "unknown"
  if icon == gIconSent then
    return
  end
  gIconSent = icon
  local description = level and ("Air quality: " .. fields.LEVEL_TEXT[level]) or "No data"
  SendToProxy(UI_BINDING, "ICON_CHANGED", { icon = icon, icon_description = description })
end

--- Create/update/delete C4 variables so values can be used in programming.
--- @param list table[] Built fields.
--- @param level string|nil Worst level.
local function syncVariables(list, level)
  local previous = persist:get(VARIABLES_KEY, {}) or {}
  local wanted = {}

  if Properties["Create Variables"] == "Yes" then
    for _, f in ipairs(list) do
      -- A Field Order entry without a value yet gets no variable
      if not f.missing then
        local v = f.value
        local varType = "STRING"
        if type(v) == "number" then
          varType = "FLOAT"
        elseif type(v) == "boolean" then
          varType = "BOOL"
        else
          v = f.display
        end
        -- values:update also writes a property of the same name, so never collide with one
        local name = f.key
        if Properties[name] ~= nil then
          name = name .. " Value"
        end
        values:update(name, v, varType)
        wanted[name] = true
      end
    end
    if level ~= nil then
      values:update(LEVEL_VARIABLE, fields.LEVEL_TEXT[level], "STRING")
      wanted[LEVEL_VARIABLE] = true
    end
  end

  for name in pairs(previous) do
    if not wanted[name] then
      values:delete(name)
    end
  end
  persist:set(VARIABLES_KEY, not IsEmpty(wanted) and wanted or nil)
end

--- Recompute everything derived from the current values (properties, variables,
--- icon, events) and refresh the web view.
--- @param fromMessage boolean|nil True when triggered by a new MQTT message.
local function refresh(fromMessage)
  local list = fields.build(gValues, getConfig())
  local level = fields.worstLevel(list)

  UpdateProperty("Current Values", fields.summary(list))
  syncVariables(list, level)
  sendIcon(level)

  if level ~= gLevel then
    local hadLevel = gLevel ~= nil
    gLevel = level
    if hadLevel then
      C4:FireEvent("Air Quality Changed")
    end
  end
  if fromMessage then
    C4:FireEvent("Values Updated")
  end

  pushDashboard()
end

--- Check whether data has gone stale and update status/events.
local function checkStale()
  local threshold = getStaleSeconds()
  local stale = threshold > 0 and gLastUpdate ~= nil and (os.time() - gLastUpdate) > threshold
  if stale == gStale then
    return
  end
  gStale = stale
  if stale then
    log:warn("No MQTT data received for more than %s seconds", threshold)
    UpdateProperty("Driver Status", "Data stale")
    C4:FireEvent("Data Stale")
  elseif gConnected then
    UpdateProperty("Driver Status", "Connected")
  end
  pushDashboard()
end

-----------------------------------------------------------------------
-- Subscriptions
-----------------------------------------------------------------------

--- Bring broker subscriptions in line with the MQTT Topics property.
--- @param force boolean|nil Re-send SUBSCRIBE for every topic (after a reconnect).
local function syncSubscriptions(force)
  local deviceId = tostring(C4:GetDeviceID())
  local wanted = {}
  for _, topic in ipairs(getTopics()) do
    wanted[topic] = true
  end

  -- Drop topics that were removed, along with their values
  local removedAny = false
  for topic in pairs(gSubscribed) do
    if not wanted[topic] then
      if gConnected then
        SendToProxy(MQTT_BINDING, "UNSUBSCRIBE", { topic = topic, device_id = deviceId })
      end
      gSubscribed[topic] = nil
    end
  end
  for key, entry in pairs(gValues) do
    if type(entry) ~= "table" or not wanted[entry.topic] then
      gValues[key] = nil
      removedAny = true
    end
  end
  if removedAny then
    saveValues()
    refresh(false)
  end

  if not gConnected then
    return
  end
  for topic in pairs(wanted) do
    if force or not gSubscribed[topic] then
      log:debug("Subscribing to %s", topic)
      SendToProxy(MQTT_BINDING, "SUBSCRIBE", {
        topic = topic,
        qos = Properties["QoS"] or "0",
        device_id = deviceId,
      })
      gSubscribed[topic] = true
    end
  end
end

local function setConnected(connected)
  gConnected = connected
  if connected then
    log:info("MQTT broker connected")
    UpdateProperty("Driver Status", gStale and "Data stale" or "Connected")
    syncSubscriptions(true)
  else
    log:warn("MQTT broker disconnected")
    UpdateProperty("Driver Status", "Broker disconnected")
    gSubscribed = {}
  end
  pushDashboard()
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

  values:restoreValues()
  -- Sensors can publish every few seconds: batch flash writes of the cached values
  persist:setWriteBehind(VALUES_KEY, 60 * ONE_SECOND)
  restoreValues()
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

  -- Point the Experience button at the page served from this driver's c4z. Sent once the
  -- proxy is up (as webview.c4z does), with the icon for the current air quality.
  gWebUrl = getWebUrl()
  UpdateProperty("Web View URL", gWebUrl)
  SetTimer("ProxyReady", PROXY_READY_DELAY, function()
    SendToProxy(UI_BINDING, "URL_CHANGED", { url = gWebUrl })
    gIconSent = nil
    sendIcon(gLevel)
  end)

  updateReceivedProperty()
  UpdateProperty("Driver Status", "Broker disconnected")
  refresh(false)
  SetTimer("StaleCheck", 30 * ONE_SECOND, checkStale, true)

  -- Bind to the broker driver if needed, then ask for its status; it answers with
  -- BROKER_CONNECTED/DISCONNECTED
  connectToBroker()
  SendToProxy(MQTT_BINDING, "GET_STATUS", {}, "NOTIFY")
end

function OnDriverDestroyed()
  persist:flush(VALUES_KEY)
end

-----------------------------------------------------------------------
-- Property change handlers
-----------------------------------------------------------------------

function OPC.Driver_Version(propertyValue)
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

function OPC.MQTT_Topics(propertyValue)
  if not gInitialized then
    return
  end
  syncSubscriptions(false)
  pushDashboard()
end

function OPC.QoS(propertyValue)
  if gInitialized then
    syncSubscriptions(true)
  end
end

--- Any display setting re-renders the dashboard and variables.
local function displayChanged()
  if gInitialized then
    refresh(false)
  end
end

OPC.Title = displayChanged
OPC.Theme = displayChanged
OPC.Field_Order = displayChanged
OPC.Hidden_Fields = displayChanged

--- Received Fields Action: run the chosen item, then return to (Select) so it can be
--- chosen again.
function OPC.Received_Fields_Action(propertyValue)
  if propertyValue == ACTION_SELECT or IsEmpty(propertyValue) then
    return
  end
  if gInitialized then
    if propertyValue == ACTION_COPY then
      -- Hidden Fields (e.g. update*) are left out; they can still be typed in by hand
      local keys = fields.catalog(gReceived, fields.parseList(Properties["Hidden Fields"]))
      log:print("Copying %d received fields to Field Order", #keys)
      UpdateProperty("Field Order", table.concat(keys, ","), true)
    elseif propertyValue == ACTION_CLEAR then
      log:print("Clearing the Received Fields list")
      gReceived = {}
      persist:set(RECEIVED_KEY, nil)
      updateReceivedProperty()
    end
  end
  UpdateProperty("Received Fields Action", ACTION_SELECT)
end
OPC.Field_Labels = displayChanged
OPC.Temperature_Display = displayChanged
OPC.Create_Variables = displayChanged

function OPC.Stale_After_minutes(propertyValue)
  if gInitialized then
    checkStale()
    pushDashboard()
  end
end

-----------------------------------------------------------------------
-- Broker (MQTT_BINDING) handlers
-----------------------------------------------------------------------

function RFP.BROKER_CONNECTED(idBinding, strCommand, tParams, args)
  if idBinding == MQTT_BINDING then
    setConnected(true)
  end
end

function RFP.BROKER_DISCONNECTED(idBinding, strCommand, tParams, args)
  if idBinding == MQTT_BINDING then
    setConnected(false)
  end
end

OBC[MQTT_BINDING] = function(idBinding, strClass, bIsBound, otherDeviceId, otherBindingId)
  log:trace("OBC[MQTT_BINDING](%s, %s, %s, %s, %s)", idBinding, strClass, bIsBound, otherDeviceId, otherBindingId)
  gSubscribed = {}
  setConnected(false)
  if bIsBound then
    SendToProxy(MQTT_BINDING, "GET_STATUS", {}, "NOTIFY")
  end
end

--- Messages are delivered by the broker driver with C4:SendToDevice.
function EC.MQTT_MESSAGE(tParams)
  local topic = Select(tParams, "topic")
  local payload = Select(tParams, "payload") or ""
  -- Ignore anything that is not (or no longer) one of our topics
  local configured = false
  for _, t in ipairs(getTopics()) do
    configured = configured or t == topic
  end
  if not configured then
    log:debug("Ignoring message for unconfigured topic %s", topic)
    return
  end
  log:debug("MQTT message %s: %s", topic, payload)

  local decoded = fields.decodePayload(topic, payload, function(s)
    return JSON:decode(s)
  end)

  -- Devices often send one field per message: merge, so each field keeps its last value
  local now = os.time()
  local count = 0
  for key, value in pairs(decoded) do
    count = count + 1
    if count > fields.MAX_FIELDS then
      log:warn("Topic %s has more than %d values; extra values ignored", topic, fields.MAX_FIELDS)
      break
    end
    gValues[key] = { value = value, ts = now, topic = topic }
  end
  gLastUpdate = now
  recordReceived(decoded)

  UpdateProperty("Last Message", topic .. " @ " .. os.date("%Y-%m-%d %H:%M:%S", now))
  UpdateProperty("Last Payload", string.sub(payload, 1, 1000))
  saveValues()
  checkStale()
  refresh(true)
end

-----------------------------------------------------------------------
-- UI Button proxy + web view handlers
-----------------------------------------------------------------------

--- Navigator selected the button (web view opened): make sure it has fresh data.
function RFP.SELECT(idBinding, strCommand, tParams, args)
  pushDashboard()
end

--- Synchronous request from the page: C4.sendCommand("GET_DASHBOARD", "{}", false, true).
--- The returned XML reaches the page's onDataToUi(); a DataToUI push follows as a fallback.
function UIR.GET_DASHBOARD(tParams)
  pushDashboard()
  return dashboardXml()
end

--- Asynchronous variant: C4.sendCommand("GET_DASHBOARD", "{}", true, true).
function EC.GET_DASHBOARD(tParams)
  pushDashboard()
end

-----------------------------------------------------------------------
-- Actions
-----------------------------------------------------------------------

function EC.Clear_Values(tParams)
  log:print("Clearing all values")
  gValues = {}
  gLastUpdate = nil
  gStale = false
  saveValues()
  persist:flush(VALUES_KEY)
  UpdateProperty("Last Message", "")
  UpdateProperty("Last Payload", "")
  refresh(false)
  -- The broker re-sends its cached message for each topic on (re)subscribe
  syncSubscriptions(true)
end

function EC.Resubscribe(tParams)
  log:print("Resubscribing to MQTT topics")
  syncSubscriptions(true)
end

function EC.Refresh_Web_View(tParams)
  pushDashboard()
end
