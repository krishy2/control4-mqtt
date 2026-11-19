--- MQTT Broker driver
---
--- Gives the MQTT child drivers (MQTT Light, MQTT General) their MQTT
--- connection. Two modes:
---   External  connects to an MQTT broker on the network (Mosquitto, ...)
---   Built-in  is the broker: devices such as Tasmota connect to the
---             controller itself, on Listen Port (default 3883)
--- Child drivers see no difference: they bind to CP_MQTT_BROKER and use the same
--- SUBSCRIBE / PUBLISH / UNSUBSCRIBE / GET_STATUS commands in both modes.

DRIVER_GITHUB_REPO = "krishy2/control4-mqtt"
DRIVER_FILENAMES = {
  "cp_mqtt_broker.c4z",
  "cp_mqtt_general.c4z",
  "cp_mqtt_light.c4z",
  "cp_mqtt_shutter.c4z",
  "cp_mqtt_fan.c4z",
  "cp_mqtt_thermostat.c4z",
  "cp_mqtt_general_webview.c4z",
}

require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

local log = require("lib.logging")
local persist = require("lib.persist")
local githubUpdater = require("lib.github-updater")
local AutoBind = require("mqtt.autobind")
local Tasmota = require("mqtt.tasmota")
local Shelly = require("mqtt.shelly")
local Zigbee = require("mqtt.tasmota_zigbee")
local Broker = require("mqtt.server.broker")
local C4Server = require("mqtt.server.c4_server")

local UPDATE_PERSIST_KEY = "PendingUpdate"
local MODE_EXTERNAL = "External"
local MODE_BUILTIN = "Built-in"

-- External mode: MQTT client instance
local MQTT = nil
-- Whether child drivers can use MQTT (external: connected; built-in: listening)
local MQTT_CONNECTED = false

-- Track subscriptions: topic -> {deviceId -> true}
local subscriptions = {}

-- Cache last message per topic for new subscribers
local lastMessages = {}

-- Built-in mode: broker core and its TCP server (created on first use)
local builtin = { broker = nil, server = nil }

-- Binding ID for the MQTT_BROKER connection
local MQTT_BROKER_BINDING = 5001

-- Tasmota devices seen through discovery: MAC -> device (see mqtt.tasmota)
local TASMOTA_PERSIST_KEY = "TasmotaDevices"
local tasmotaDevices = {}
--- The raw discovery message of each device, by MAC: read again at start-up so
--- a driver update that reads more from it applies without waiting for the
--- device to announce itself again.
local TASMOTA_RAW_PERSIST_KEY = "TasmotaDiscovery"
local tasmotaRaw = {}
local SHELLY_PERSIST_KEY = "ShellyDevices"
--- Shelly Gen2+ devices by MAC
local shellyDevices = {}
--- Shelly.GetConfig requests waiting for an answer, by device ID
local shellyPending = {}
--- When each device's configuration was last read (ms), by MAC; not persisted
local shellyFetched = {}
local shellyRpcId = 0
--- A device's configuration is read again after this long, or when it changes.
local SHELLY_REFRESH_MS = 60 * 60 * 1000
--- Defined in the Shelly discovery section; used when the broker connects.
local findShellies
local ZIGBEE_PERSIST_KEY = "ZigbeeDevices"
--- Zigbee devices behind Tasmota Zigbee gateways, by IEEE address
local zigbeeDevices = {}
--- Gateways (Tasmota MAC) -> { topic, style, lastList, lastAsked }; not persisted
local zigbeeGateways = {}
--- External mode: topics this driver subscribed to for itself
local ownSubscriptions = {}
--- Defined in the Zigbee section; used when the broker connects.
local findZigbee

local EXTERNAL_PROPERTIES = { "Broker Settings", "Broker Address", "Port", "Username", "Password", "Keep Alive" }
local BUILTIN_PROPERTIES = {
  "Built-in Broker",
  "Listen Port",
  "Max Clients",
  "Connected Devices",
  "Messages per Second",
  "Broker Errors",
  "Timer Lag",
}

local function isBuiltIn()
  return Properties["Broker Mode"] == MODE_BUILTIN
end

--- Get all MQTT driver instances sorted by device ID
--- @return integer[] deviceIds Sorted list of device IDs
local function getMQTTDriverIds()
  local drivers = C4:GetDevicesByC4iName(C4:GetDriverFileName()) or {}
  --- @type integer[]
  local ids = {}
  for id, _ in pairs(drivers) do
    table.insert(ids, tointeger(id))
  end
  table.sort(ids)
  return ids
end

--- Sync a property value to all other MQTT driver instances
--- Only syncs if the other instance has a different value (avoids infinite loops)
--- @param propertyName string The property name to sync
--- @param propertyValue string The property value to sync
local function syncPropertyToOtherInstances(propertyName, propertyValue)
  local ids = getMQTTDriverIds()
  local myId = C4:GetDeviceID()
  for _, deviceId in ipairs(ids) do
    if deviceId ~= myId then
      log:info("Syncing property '%s' = '%s' to device %d", propertyName, propertyValue, deviceId)
      SetDeviceProperties(deviceId, { [propertyName] = propertyValue }, true)
    end
  end
end

local function updateStatus(status)
  log:trace("updateStatus(%s)", status)
  UpdateProperty("Driver Status", not IsEmpty(status) and status or "Unknown")
end

--- Notify all connected child drivers of an event
--- @param command string The command to send
--- @param params table The parameters to send
local function notifyChildDrivers(command, params)
  log:trace("notifyChildDrivers(%s, %s)", command, params)
  -- SendToProxy broadcasts to all devices connected to this binding
  SendToProxy(MQTT_BROKER_BINDING, command, params or {}, "NOTIFY")
end

--- Mark MQTT available or unavailable to child drivers, firing events on change.
--- @param connected boolean
local function setConnected(connected)
  if connected == MQTT_CONNECTED then
    return
  end
  MQTT_CONNECTED = connected
  if connected then
    C4:FireEvent("Broker Connected")
    notifyChildDrivers("BROKER_CONNECTED", {})
    -- Shellies already connected announce themselves; the rest do when they connect.
    SetTimer("FindShellies", 2 * ONE_SECOND, function()
      findShellies()
    end)
    -- Tasmotas known from before are asked for Zigbee devices too.
    SetTimer("FindZigbee", 5 * ONE_SECOND, function()
      findZigbee(false)
    end)
  else
    C4:FireEvent("Broker Disconnected")
    notifyChildDrivers("BROKER_DISCONNECTED", {})
  end
end

--- Send a message to one child driver.
local function sendToChild(deviceId, topic, payload, qos, retain)
  SendToDevice(deviceId, "MQTT_MESSAGE", {
    topic = topic,
    payload = payload,
    qos = tostring(qos or 0),
    retain = retain and "true" or "false",
  })
end

--- Route incoming MQTT messages to subscribed child drivers
--- @param topic string The topic the message was received on
--- @param payload string The message payload
--- @param qos number The QoS level
--- @param retain boolean Whether the message was retained
local function routeMessageToSubscribers(topic, payload, qos, retain)
  log:trace("routeMessageToSubscribers('%s', '%s', %s, %s)", topic, payload, qos, retain)

  -- Check for exact topic match
  local devices = subscriptions[topic]
  if not IsEmpty(devices) then
    for deviceId, _ in pairs(devices) do
      log:debug("Routing message to device %s", deviceId)
      sendToChild(deviceId, topic, payload, qos, retain)
    end
  end
end

-----------------------------------------------------------------------
-- Tasmota discovery
-----------------------------------------------------------------------

local function sameValue(a, b)
  if type(a) ~= type(b) then
    return false
  end
  if type(a) ~= "table" then
    return a == b
  end
  for k, v in pairs(a) do
    if not sameValue(v, b[k]) then
      return false
    end
  end
  for k in pairs(b) do
    if a[k] == nil then
      return false
    end
  end
  return true
end

local function tasmotaCount()
  local n = 0
  for _ in pairs(tasmotaDevices) do
    n = n + 1
  end
  return n
end

local function updateTasmotaProperty()
  UpdateProperty("Tasmota Devices", tostring(tasmotaCount()))
end

--- Defined in the Zigbee section.
local askZigbee

--- A device's discovery message arrived (an empty payload removes it).
--- @param mac string
--- @param payload string
local function onTasmotaDiscovery(mac, payload)
  local dev = Tasmota.parse(payload)
  local old = tasmotaDevices[mac]
  if dev == nil then
    if old == nil then
      return
    end
    log:info("Tasmota device %s (%s) removed itself from discovery", old.name, old.topic)
    tasmotaDevices[mac] = nil
    tasmotaRaw[mac] = nil
  else
    if tasmotaRaw[mac] ~= payload then
      tasmotaRaw[mac] = payload
      persist:defer(function()
        persist:set(TASMOTA_RAW_PERSIST_KEY, tasmotaRaw)
      end)
    end
    -- Any Tasmota may be a Zigbee gateway: ask (at most once a minute).
    askZigbee(mac, dev, false)
    if sameValue(old, dev) then
      return
    end
    log:info("Tasmota device %s (%s, %s) %s", dev.name, dev.topic, dev.ip, old and "changed" or "discovered")
    tasmotaDevices[mac] = dev
  end
  -- Many devices announce themselves at once after a restart: save at most every 10s.
  persist:defer(function()
    persist:set(TASMOTA_PERSIST_KEY, tasmotaDevices)
    persist:set(TASMOTA_RAW_PERSIST_KEY, tasmotaRaw)
  end)
  updateTasmotaProperty()
  notifyChildDrivers("TASMOTA_DEVICES_CHANGED", { mac = mac })
end

--- Handle a message if it is a Tasmota discovery config.
--- @return boolean handled
local function handleDiscovery(topic, payload)
  local mac = Tasmota.discoveryMac(topic)
  if mac == nil then
    return false
  end
  local ok, err = pcall(onTasmotaDiscovery, mac, payload)
  if not ok then
    log:error("Tasmota discovery from %s failed: %s", topic, err)
  end
  return true
end

-----------------------------------------------------------------------
-- Shelly discovery (Gen2+)
-----------------------------------------------------------------------

local function shellyCount()
  local n = 0
  for _ in pairs(shellyDevices) do
    n = n + 1
  end
  return n
end

local function updateShellyProperty()
  UpdateProperty("Shelly Devices", tostring(shellyCount()))
end

--- Publish a message from this driver, in either mode.
--- @return boolean sent
local function publishOwn(topic, payload)
  if isBuiltIn() then
    return builtin.broker ~= nil and MQTT_CONNECTED and builtin.broker:publish(topic, payload, false) and true or false
  end
  if MQTT_CONNECTED and MQTT then
    return MQTT:Publish(topic, payload, 0, false) == 0
  end
  return false
end

--- Ask every Shelly on the broker to announce itself.
findShellies = function()
  if publishOwn(Shelly.BROADCAST_TOPIC, "announce") then
    log:debug("Asked Shelly devices to announce themselves")
  end
end

--- A Gen2+ device announced itself: read its configuration unless it is fresh.
local function onShellyAnnounce(prefix, info)
  local known = shellyDevices[info.mac]
  local fetched = shellyFetched[info.mac]
  if
    known ~= nil
    and known.topic == prefix
    and known.version == info.ver
    and fetched ~= nil
    and C4:GetTime() - fetched < SHELLY_REFRESH_MS
  then
    return
  end
  shellyRpcId = shellyRpcId % 1000000 + 1
  shellyPending[info.id] = { info = info, prefix = prefix, rpcId = shellyRpcId }
  log:debug("Reading the configuration of Shelly %s (%s)", info.id, prefix)
  publishOwn(prefix .. "/rpc", Shelly.configRequest(shellyRpcId))
end

--- A device answered Shelly.GetConfig.
local function onShellyReply(payload)
  local reply = Shelly.parseReply(payload)
  if reply == nil then
    return
  end
  local pending = shellyPending[reply.src]
  if pending == nil then
    return
  end
  shellyPending[reply.src] = nil
  if reply.error ~= nil or type(reply.result) ~= "table" then
    log:warn("Shelly %s did not return its configuration: %s", reply.src, reply.error)
    return
  end
  local dev = Shelly.build(pending.info, pending.prefix, reply.result)
  local mac = dev.mac
  shellyFetched[mac] = C4:GetTime()
  local old = shellyDevices[mac]
  if sameValue(old, dev) then
    return
  end
  log:info(
    "Shelly %s (%s, %s) %s: %d outputs",
    dev.name,
    dev.topic,
    dev.model,
    old and "changed" or "discovered",
    #dev.components
  )
  shellyDevices[mac] = dev
  persist:defer(function()
    persist:set(SHELLY_PERSIST_KEY, shellyDevices)
  end)
  updateShellyProperty()
  notifyChildDrivers("TASMOTA_DEVICES_CHANGED", { mac = mac })
end

--- Handle a message if it belongs to Shelly discovery.
--- @return boolean handled true for discovery topics
local function handleShelly(topic, payload)
  local ok, handled = pcall(function()
    if topic == Shelly.DISCOVERY_REPLY_TOPIC then
      onShellyReply(payload)
      return true
    end
    local prefix = Shelly.prefixFrom(topic, "announce")
    if prefix ~= nil then
      local info = Shelly.parseAnnounce(payload)
      if info ~= nil then
        onShellyAnnounce(prefix, info)
      end
      return true
    end
    prefix = Shelly.prefixFrom(topic, "online")
    if prefix ~= nil then
      -- A Shelly connected: ask it (and only it) to announce itself.
      -- It subscribes to its command topics just after saying so: wait a moment.
      if payload == "true" then
        SetTimer("ShellyAnnounce " .. prefix, 3 * ONE_SECOND, function()
          publishOwn(prefix .. "/command", "announce")
        end)
      end
      return true
    end
    return false
  end)
  if not ok then
    log:error("Shelly discovery from %s failed: %s", topic, handled)
    return true
  end
  return handled
end

-----------------------------------------------------------------------
-- Zigbee devices behind Tasmota Zigbee gateways
-----------------------------------------------------------------------

--- A gateway is asked for its device list at most this often.
local ZIGBEE_ASK_MS = 60 * ONE_SECOND
--- Answers to ZbStatus1 are waited for this long before a Tasmota counts as no gateway.
local ZIGBEE_ANSWER_MS = 15 * ONE_SECOND
--- Devices' details are asked one after the other, this far apart.
local ZIGBEE_DETAIL_GAP_MS = 300

local function zigbeeCount()
  local n = 0
  for _ in pairs(zigbeeDevices) do
    n = n + 1
  end
  return n
end

local function updateZigbeeProperty()
  UpdateProperty("Zigbee Devices", tostring(zigbeeCount()))
end

local function saveZigbee()
  persist:defer(function()
    persist:set(ZIGBEE_PERSIST_KEY, zigbeeDevices)
  end)
end

--- External mode: subscribe for this driver's own use.
local function subscribeOwn(topic)
  if isBuiltIn() or ownSubscriptions[topic] then
    return
  end
  ownSubscriptions[topic] = true
  if MQTT_CONNECTED and MQTT and IsEmpty(subscriptions[topic]) then
    MQTT:Subscribe(topic)
  end
end

local function unsubscribeOwn(topic)
  if not ownSubscriptions[topic] then
    return
  end
  ownSubscriptions[topic] = nil
  if not isBuiltIn() and MQTT_CONNECTED and MQTT and IsEmpty(subscriptions[topic]) then
    MQTT:Unsubscribe(topic)
  end
end

--- The gateway record for a Tasmota, made on first use.
local function gatewayFor(mac, dev)
  local gw = zigbeeGateways[mac]
  if gw == nil then
    gw = { mac = mac }
    -- What earlier messages showed about its topics is kept with its devices.
    for _, z in pairs(zigbeeDevices) do
      if z.gateway and z.gateway.mac == mac and z.gateway.style then
        gw.style = z.gateway.style
        break
      end
    end
    zigbeeGateways[mac] = gw
  end
  gw.dev = dev
  return gw
end

--- Ask a Tasmota for its Zigbee devices.
--- @param mac string the Tasmota's MAC
--- @param dev table the parsed Tasmota device
--- @param force boolean ask even if asked within the last minute
askZigbee = function(mac, dev, force)
  if not MQTT_CONNECTED then
    return
  end
  local gw = gatewayFor(mac, dev)
  local now = C4:GetTime()
  if not force and gw.lastAsked ~= nil and now - gw.lastAsked < ZIGBEE_ASK_MS then
    return
  end
  gw.lastAsked = now
  local result = Zigbee.resultTopic(dev)
  subscribeOwn(result)
  -- The subscription needs a moment before the answer can arrive.
  SetTimer("ZigbeeAsk " .. mac, ONE_SECOND, function()
    publishOwn(Zigbee.listTopic(dev), "")
  end)
  if not gw.isGateway then
    SetTimer("ZigbeeAnswer " .. mac, ZIGBEE_ANSWER_MS, function()
      if not gw.isGateway then
        -- Not a Zigbee gateway: stop listening to its answers.
        unsubscribeOwn(result)
      end
    end)
  end
end

--- Ask every known Tasmota (gateways included) for its Zigbee devices.
findZigbee = function(force)
  for mac, dev in pairs(tasmotaDevices) do
    askZigbee(mac, dev, force)
  end
end

--- Tell child drivers a Zigbee device appeared, changed or went away.
local function zigbeeChanged(ieee)
  saveZigbee()
  updateZigbeeProperty()
  notifyChildDrivers("TASMOTA_DEVICES_CHANGED", { mac = ieee })
end

--- Put what the gateway's messages showed into every device behind it.
local function applyStyle(gw)
  for ieee, z in pairs(zigbeeDevices) do
    if z.gateway and z.gateway.mac == gw.mac and not sameValue(z.gateway.style, gw.style) then
      z.gateway.style = gw.style
      if z.stateTopic == nil then
        zigbeeChanged(ieee)
      end
    end
  end
end

--- The gateway listed its devices (ZbStatus1).
local function onZigbeeList(gw, list)
  local dev = gw.dev
  if not gw.isGateway then
    gw.isGateway = true
    log:info("Tasmota %s (%s) is a Zigbee gateway with %d devices", dev.name, dev.topic, #list)
    subscribeOwn(Zigbee.resultTopic(dev))
    subscribeOwn(Zigbee.sensorTopic(dev))
    subscribeOwn(Zigbee.deviceSensorFilter(dev))
  end
  gw.lastList = C4:GetTime()
  local listed = {}
  for i, d in ipairs(list) do
    listed[d.short] = true
    SetTimer("ZigbeeDetail " .. gw.mac .. " " .. d.short, i * ZIGBEE_DETAIL_GAP_MS, function()
      publishOwn(Zigbee.detailTopic(dev), d.short)
    end)
  end
  -- Devices no longer paired to this gateway
  for ieee, z in pairs(zigbeeDevices) do
    if z.gateway and z.gateway.mac == gw.mac and not listed[z.short] then
      log:info("Zigbee device %s (%s) is no longer paired to %s", z.name, z.short, dev.topic)
      zigbeeDevices[ieee] = nil
      zigbeeChanged(ieee)
    end
  end
end

--- The gateway described devices (ZbStatus3).
local function onZigbeeDetail(gw, entries)
  for _, d in ipairs(entries) do
    local ieee = d.IEEEAddr and ("0x" .. tostring(d.IEEEAddr):sub(3):upper()) or nil
    local old = ieee and zigbeeDevices[ieee] or nil
    local z = Zigbee.build(gw.dev, d, old)
    if z ~= nil then
      z.gateway.style = gw.style
      if not sameValue(old, z) then
        local loads = Zigbee.loads(z)
        log:info(
          "Zigbee device %s (%s, %s) on %s %s: %s",
          z.name,
          z.short,
          z.model or "unknown model",
          gw.dev.topic,
          old and "changed" or "discovered",
          loads[1] and loads[1].label or "not a light"
        )
        zigbeeDevices[z.ieee] = z
        zigbeeChanged(z.ieee)
      end
    end
  end
end

--- A gateway reported device values (ZbReceived): learn where each device reports.
local function onZigbeeReceived(gw, topic, entries)
  local unknown = false
  for key, entry in pairs(entries) do
    if type(entry) == "table" then
      local short = Zigbee.shortAddress(entry.Device)
      local found
      for ieee, z in pairs(zigbeeDevices) do
        if z.gateway and z.gateway.mac == gw.mac and (z.short == short or z.name == key) then
          found = ieee
          break
        end
      end
      if found == nil then
        unknown = true
      else
        local z = zigbeeDevices[found]
        local style = Zigbee.styleFrom(gw.dev, topic, key, z)
        if not sameValue(gw.style, style) then
          gw.style = style
          applyStyle(gw)
        end
        if z.stateTopic ~= topic or z.stateKey ~= key then
          z.stateTopic, z.stateKey = topic, key
          log:debug("Zigbee device %s reports on %s as '%s'", z.name, topic, key)
          zigbeeChanged(found)
        end
      end
    end
  end
  if unknown then
    -- A device newly paired, or renamed: read the list again (once a minute at most).
    askZigbee(gw.mac, gw.dev, false)
  end
end

--- A ZbLight answer: the light type of a device changed (or was shown).
local function onZigbeeLight(gw, lights)
  for ieee, z in pairs(zigbeeDevices) do
    local lt = z.gateway and z.gateway.mac == gw.mac and lights[z.short] or nil
    if lt ~= nil and lt >= 0 and (z.light == nil or z.light.type ~= lt) then
      z.light = { endpoint = (z.clusters or {}).L or 1, type = lt }
      log:info("Zigbee device %s is now light type %d", z.name, lt)
      zigbeeChanged(ieee)
    end
  end
end

--- Handle a message if it belongs to a Zigbee gateway.
--- @return boolean handled true for this driver's own topics
local function handleZigbee(topic, payload)
  if next(zigbeeGateways) == nil then
    return false
  end
  local ok, handled = pcall(function()
    for _, gw in pairs(zigbeeGateways) do
      local dev = gw.dev
      if dev ~= nil then
        if topic == Zigbee.resultTopic(dev) then
          local r = Zigbee.parseResult(payload)
          if r ~= nil and r.kind == "list" then
            onZigbeeList(gw, r.devices)
          elseif r ~= nil and r.kind == "detail" and gw.isGateway then
            onZigbeeDetail(gw, r.devices)
          end
          return ownSubscriptions[topic] == true
        end
        if gw.isGateway then
          local sensor = Zigbee.sensorTopic(dev)
          local prefix = sensor:sub(1, -#"SENSOR" - 1)
          if topic == sensor or (topic:sub(1, #prefix) == prefix and topic:match("^[^/]+/SENSOR$", #prefix + 1)) then
            local entries = Zigbee.parseReceived(payload)
            if entries ~= nil then
              onZigbeeReceived(gw, topic, entries)
            end
            local lights = Zigbee.parseLight(payload)
            if lights ~= nil then
              onZigbeeLight(gw, lights)
            end
            return true
          end
        end
      end
    end
    return false
  end)
  if not ok then
    log:error("Zigbee discovery from %s failed: %s", topic, handled)
    return true
  end
  return handled
end

-----------------------------------------------------------------------
-- Built-in mode
-----------------------------------------------------------------------

local function builtInPort()
  return tonumber(Properties["Listen Port"]) or 3883
end

local function updateBuiltInProperties()
  local server = builtin.server
  if server == nil or not isBuiltIn() then
    return
  end
  local broker = builtin.broker
  UpdateProperty("Connected Devices", tostring(broker:clientCount()))
  UpdateProperty("Messages per Second", string.format("%.1f", server.rate.perSecond))
  local problems = server:problemCount()
  local last = broker.lastError or server.stats.lastInternalError
  if IsEmpty(last) then
    last = server.stats.lastSocketError
  end
  UpdateProperty("Broker Errors", problems == 0 and "0" or string.format("%d (last: %s)", problems, last or ""))
  UpdateProperty("Timer Lag", string.format("%d ms now, %d ms max", server.lag.recentMax, server.lag.max))
  if server.listening then
    updateStatus(string.format("Built-in broker on port %d: %d devices", server.port, broker:clientCount()))
  end
end

local function ensureBuiltIn()
  if builtin.broker ~= nil then
    return
  end
  builtin.broker = Broker.new({
    now = function()
      return C4:GetTime()
    end,
    log = log,
    onPublish = function(topic, payload, _retain, clientId)
      log:trace("Built-in broker: %s -> %s", tostring(clientId or "driver"), topic)
      handleDiscovery(topic, payload)
      handleShelly(topic, payload)
      handleZigbee(topic, payload)
      local devices = subscriptions[topic]
      if IsEmpty(devices) then
        return
      end
      lastMessages[topic] = { payload = payload, qos = 0, retain = false }
      routeMessageToSubscribers(topic, payload, 0, false)
    end,
  })
  builtin.server = C4Server.new({
    broker = builtin.broker,
    log = log,
    maxClients = function()
      return tonumber(Properties["Max Clients"]) or 250
    end,
    onStatus = function(server)
      if not isBuiltIn() then
        return
      end
      if server.listening then
        updateStatus(string.format("Built-in broker on port %d: %d devices", server.port, builtin.broker:clientCount()))
      elseif server.status ~= "Stopped" then
        updateStatus("Built-in broker: " .. server.status)
      end
      setConnected(server.listening)
    end,
  })
end

local function startBuiltIn()
  ensureBuiltIn()
  builtin.server:resetStats()
  SetTimer("BuiltInHousekeeping", ONE_SECOND, function()
    local ok, err = xpcall(function()
      if builtin.server:tick(5) then
        updateBuiltInProperties()
        builtin.server:clearRecentLag()
      end
    end, debug.traceback)
    if not ok then
      log:error("Built-in broker housekeeping failed: %s", err)
    end
  end, true)
  builtin.server:start(builtInPort())
end

local function stopBuiltIn(reason)
  CancelTimer("BuiltInHousekeeping")
  if builtin.server ~= nil then
    builtin.server:stop(reason)
  end
  -- Built-in caches only messages for subscribed topics; they belong to that session.
  lastMessages = {}
end

-----------------------------------------------------------------------
-- External mode
-----------------------------------------------------------------------

local function stopExternal()
  if MQTT then
    log:debug("Disconnecting existing MQTT connection")
    local old = MQTT
    MQTT = nil
    old:Disconnect()
  end
end

local function connectExternal()
  local brokerAddress = Properties["Broker Address"]
  local port = tonumber(Properties["Port"]) or 1883

  if IsEmpty(brokerAddress) then
    updateStatus("Not configured")
    return
  end

  local clientId = "control4-mqtt-device-" .. C4:GetDeviceID()
  log:info("Creating MQTT client with clientId: %s", clientId)
  MQTT = C4:MQTT(clientId)

  -- Set credentials if provided
  local username = Properties["Username"]
  local password = Properties["Password"]
  if not IsEmpty(username) then
    log:debug("Setting MQTT credentials for user: %s", username)
    MQTT:SetUsernameAndPassword(username, password or "")
  end

  -- Set up callbacks
  MQTT:OnConnect(function(obj, reasonCode, flags, message)
    -- Ignore callbacks from a prior client that was replaced mid-flight by a
    -- subsequent Connect(). Acting on stale events would poison the new
    -- session's state (MQTT_CONNECTED / status / child notifications).
    if obj ~= MQTT then
      log:debug("Ignoring stale OnConnect from replaced client")
      return
    end
    log:info("MQTT:OnConnect reasonCode=%s message=%s", reasonCode, message or "")
    if reasonCode == 0 then
      -- Drop any pending reconnect armed by a prior OnDisconnect (e.g., the
      -- OLD client's async OnDisconnect from the intentional Disconnect()
      -- during this Connect cycle). Without this, a stale 30s timer would
      -- fire after the session was up and tear the working connection down.
      CancelTimer("reconnect")

      updateStatus("Connected")

      -- Re-subscribe to all tracked topics
      for topic, bindings in pairs(subscriptions) do
        if next(bindings) then
          log:debug("Re-subscribing to topic: %s", topic)
          MQTT:Subscribe(topic)
        end
      end
      -- This driver's own topics (Zigbee gateways)
      for topic in pairs(ownSubscriptions) do
        if IsEmpty(subscriptions[topic]) then
          MQTT:Subscribe(topic)
        end
      end
      -- Tasmota discovery (retained, so the broker sends what it has)
      MQTT:Subscribe(Tasmota.DISCOVERY_FILTER)
      -- Shelly discovery: announces, online messages and RPC answers
      for _, filter in ipairs(Shelly.EXTERNAL_FILTERS) do
        MQTT:Subscribe(filter)
      end

      -- Notify child drivers
      setConnected(true)
    else
      local errorMessage = message or MQTT:ReasonCodeToString(reasonCode) or "unknown"
      updateStatus("Connect failed: " .. errorMessage)
      log:error("MQTT connection failed: %s", errorMessage)

      -- Schedule reconnect
      SetTimer("reconnect", 30 * ONE_SECOND, function()
        Connect()
      end)
    end
  end)

  MQTT:OnDisconnect(function(obj, reasonCode)
    -- Ignore callbacks from a prior client that was replaced mid-flight by a
    -- subsequent Connect(). The OLD client's Disconnect() fires this callback
    -- asynchronously; without this guard it would overwrite connection state
    -- and emit a spurious BROKER_DISCONNECTED to children after the new
    -- session is already live.
    if obj ~= MQTT then
      log:debug("Ignoring stale OnDisconnect from replaced client")
      return
    end
    local reasonString = MQTT and MQTT:ReasonCodeToString(reasonCode) or "unknown"
    log:warn("MQTT:OnDisconnect reasonCode=%s - %s", reasonCode, reasonString)
    updateStatus("Disconnected")
    setConnected(false)

    -- Only auto-reconnect on unclean disconnects. The stale-client guard
    -- above filters out our own Disconnect() calls (they fire on the
    -- replaced client); the reasonCode gate additionally filters server-
    -- initiated clean shutdowns (reasonCode == 0) so we don't hammer a
    -- broker that's deliberately closing the connection.
    if reasonCode ~= 0 then
      SetTimer("reconnect", 30 * ONE_SECOND, function()
        Connect()
      end)
    end
  end)

  MQTT:OnMessage(function(obj, msgId, topic, payload, qos, retain)
    log:debug("MQTT:OnMessage msgId=%s topic=%s payload=%s qos=%s retain=%s", msgId, topic, payload, qos, retain)
    local discovery = handleDiscovery(topic, payload)
    discovery = handleShelly(topic, payload) or discovery
    discovery = handleZigbee(topic, payload) or discovery
    if discovery and IsEmpty(subscriptions[topic]) then
      return
    end
    -- Cache the last message for new subscribers
    lastMessages[topic] = {
      payload = payload,
      qos = qos,
      retain = retain,
    }
    routeMessageToSubscribers(topic, payload, qos, retain)
  end)

  MQTT:OnPublish(function(obj, msgId, reasonCode)
    if reasonCode ~= 0 then
      local errorString = MQTT and MQTT:ErrorCodeToString(reasonCode) or "unknown"
      log:error("MQTT:Publish error msgId=%s: %s - %s", msgId, reasonCode, errorString)
    else
      log:trace("MQTT:Publish success msgId=%s", msgId)
    end
  end)

  MQTT:OnSubscribe(function(obj, msgId, grantedQos)
    log:debug("MQTT:OnSubscribe msgId=%s grantedQos=%s", msgId, grantedQos)
  end)

  updateStatus("Connecting...")
  local keepAlive = tonumber(Properties["Keep Alive"]) or 60
  log:info("Connecting to MQTT broker at %s:%s (keepAlive=%s)", brokerAddress, port, keepAlive)
  MQTT:Connect(brokerAddress, port, keepAlive)
end

--- (Re)start MQTT in the selected mode.
function Connect()
  log:trace("Connect()")
  if not gInitialized then
    updateStatus("Initializing...")
    return
  end

  -- Cancel any pending reconnect
  CancelTimer("reconnect")

  -- Children hear about the restart before anything is torn down. As before,
  -- a deliberate restart does not fire the Broker Disconnected event.
  MQTT_CONNECTED = false
  notifyChildDrivers("BROKER_DISCONNECTED", {})

  stopExternal()
  stopBuiltIn("broker restarting")

  if isBuiltIn() then
    startBuiltIn()
  else
    connectExternal()
  end
end

local function updateModeVisibility()
  local builtIn = isBuiltIn()
  for _, name in ipairs(EXTERNAL_PROPERTIES) do
    C4:SetPropertyAttribs(name, builtIn and 1 or 0)
  end
  for _, name in ipairs(BUILTIN_PROPERTIES) do
    C4:SetPropertyAttribs(name, builtIn and 0 or 1)
  end
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
  persist:setWriteBehind(TASMOTA_PERSIST_KEY, 10 * ONE_SECOND)
  tasmotaDevices = persist:get(TASMOTA_PERSIST_KEY, {}) or {}
  persist:setWriteBehind(TASMOTA_RAW_PERSIST_KEY, 10 * ONE_SECOND)
  tasmotaRaw = persist:get(TASMOTA_RAW_PERSIST_KEY, {}) or {}
  -- Read every kept discovery message again with this version's parser.
  for mac, payload in pairs(tasmotaRaw) do
    local ok, dev = pcall(Tasmota.parse, payload)
    if ok and dev ~= nil then
      tasmotaDevices[mac] = dev
    end
  end
  persist:setWriteBehind(SHELLY_PERSIST_KEY, 10 * ONE_SECOND)
  shellyDevices = persist:get(SHELLY_PERSIST_KEY, {}) or {}
  persist:setWriteBehind(ZIGBEE_PERSIST_KEY, 2 * ONE_SECOND)
  zigbeeDevices = persist:get(ZIGBEE_PERSIST_KEY, {}) or {}
end

function OnDriverLateInit()
  log:trace("OnDriverLateInit()")
  if not CheckMinimumVersion("Driver Status") then
    return
  end

  -- Fire OnPropertyChanged to set the initial Headers and other Property
  -- global sets, they'll change if Property is changed.
  for p, _ in pairs(Properties) do
    local status, err = pcall(OnPropertyChanged, p)
    if not status and err then
      log:error("Error in OnPropertyChanged for property '%s': %s", p, err or "unknown error")
    end
  end
  -- Periodic update check (every 30 minutes, leader instance only)
  SetTimer("UpdateCheck", 30 * 60 * 1000, function()
    -- Recompute leader each cycle in case the previous leader was removed
    local isLeaderInstance = Select(getMQTTDriverIds(), 1) == C4:GetDeviceID()
    if isLeaderInstance and toboolean(Properties["Automatic Updates"]) then
      log:info("Checking for driver update (leader instance)")
      UpdateDrivers()
    end
  end, true)

  gInitialized = true
  updateModeVisibility()
  updateTasmotaProperty()
  updateShellyProperty()
  updateZigbeeProperty()
  Connect()
  -- Catch devices whose online message was missed (e.g. deeper topic prefixes).
  SetTimer("FindShelliesPeriodic", 15 * ONE_MINUTE, function()
    findShellies()
    -- Newly paired or renamed Zigbee devices
    for mac, gw in pairs(zigbeeGateways) do
      if gw.isGateway then
        askZigbee(mac, gw.dev, false)
      end
    end
  end, true)

  -- After an update: say whether every driver got the new version, once the
  -- other drivers have had time to restart.
  if persist:get(UPDATE_PERSIST_KEY, nil) ~= nil then
    SetTimer("UpdateVerify", 30 * ONE_SECOND, VerifyDriverUpdate)
  end

  -- Bind MQTT Light and MQTT General drivers that are not connected yet
  local ok, err = pcall(AutoBind.connectAll)
  if not ok then
    log:warn("Could not connect drivers to this broker automatically: %s", err)
  end
end

function OnDriverDestroyed()
  CancelTimer("FindShelliesPeriodic")
  persist:flush()
  stopBuiltIn("driver removed")
  stopExternal()
end

-----------------------------------------------------------------------
-- Property change handlers
-----------------------------------------------------------------------

function OPC.Automatic_Updates(propertyValue)
  log:trace("OPC.Automatic_Updates('%s')", propertyValue)
  if not gInitialized then
    return
  end
  syncPropertyToOtherInstances("Automatic Updates", propertyValue)
end

function OPC.Update_Channel(propertyValue)
  log:trace("OPC.Update_Channel('%s')", propertyValue)
  if not gInitialized then
    return
  end
  syncPropertyToOtherInstances("Update Channel", propertyValue)
end

function OPC.Driver_Version(propertyValue)
  log:trace("OPC.Driver_Version('%s')", propertyValue)
  C4:UpdateProperty("Driver Version", C4:GetDriverConfigInfo("version"))
end

function OPC.Log_Mode(propertyValue)
  log:trace("OPC.Log_Mode('%s')", propertyValue)
  log:setLogMode(propertyValue)
  CancelTimer("LogMode")
  if not log:isEnabled() then
    UpdateProperty("Log Level", "3 - Info", true)
    return
  end
  log:warn("Log mode '%s' will expire in 3 hours", propertyValue)
  SetTimer("LogMode", 3 * ONE_HOUR, function()
    log:warn("Setting log mode to 'Off' (timer expired)")
    UpdateProperty("Log Mode", "Off", true)
  end)
  OnPropertyChanged("Log Level")
end

function OPC.Log_Level(propertyValue)
  log:trace("OPC.Log_Level('%s')", propertyValue)
  log:setLogLevel(propertyValue)
  if log:getLogLevel() >= 6 and log:isPrintEnabled() then
    DEBUGPRINT = true
    DEBUG_TIMER = true
    DEBUG_RFN = true
    DEBUG_URL = true
    DEBUG_WEBSOCKET = true
  else
    DEBUGPRINT = false
    DEBUG_TIMER = false
    DEBUG_RFN = false
    DEBUG_URL = false
    DEBUG_WEBSOCKET = false
  end
end

function OPC.Broker_Mode(propertyValue)
  log:trace("OPC.Broker_Mode('%s')", propertyValue)
  if not gInitialized then
    return
  end
  updateModeVisibility()
  Connect()
end

-- Settings of the active mode reconnect; the other mode's settings wait.
local function externalSetting(name)
  return function(propertyValue)
    log:trace("OPC.%s('%s')", name, name == "Password" and "****" or propertyValue)
    if not isBuiltIn() then
      Connect()
    end
  end
end

OPC.Broker_Address = externalSetting("Broker_Address")
OPC.Port = externalSetting("Port")
OPC.Username = externalSetting("Username")
OPC.Password = externalSetting("Password")
OPC.Keep_Alive = externalSetting("Keep_Alive")

function OPC.Listen_Port(propertyValue)
  log:trace("OPC.Listen_Port('%s')", propertyValue)
  if gInitialized and isBuiltIn() then
    Connect()
  end
end

-----------------------------------------------------------------------
-- Conditionals
-----------------------------------------------------------------------

--- Test condition for MQTT broker connection status
--- @param strConditionName string The name of the condition
--- @param tParams table Parameters for the condition test
--- @return boolean result True if the condition is met
function TC.BROKER_CONNECTED(strConditionName, tParams)
  log:trace("TC.BROKER_CONNECTED(%s, %s)", strConditionName, tParams)
  local test = Select(tParams, "VALUE") == "Connected"
  if Select(tParams, "LOGIC") == "NOT_EQUAL" then
    return test ~= MQTT_CONNECTED
  else
    return test == MQTT_CONNECTED
  end
end

-----------------------------------------------------------------------
-- Child driver commands
-----------------------------------------------------------------------

-- Handle SUBSCRIBE command from child drivers
function RFP.SUBSCRIBE(idBinding, strCommand, tParams, args)
  log:trace("RFP.SUBSCRIBE(%s, %s, %s, %s)", idBinding, strCommand, tParams, args)
  local topic = Select(tParams, "topic")
  local deviceId = tonumber(Select(tParams, "device_id"))
  local qos = tonumber(Select(tParams, "qos")) or 0

  if IsEmpty(topic) then
    log:warn("SUBSCRIBE called with empty topic")
    return
  end

  if not deviceId then
    log:warn("SUBSCRIBE called without device_id")
    return
  end

  -- Track subscription by device ID
  subscriptions[topic] = subscriptions[topic] or {}
  local isNewTopicSubscription = not next(subscriptions[topic])
  subscriptions[topic][deviceId] = true

  log:debug("Registered subscription: device=%s topic=%s", deviceId, topic)

  if isBuiltIn() then
    -- The broker is local: hand over the latest message, else the retained one.
    local cached = lastMessages[topic]
    local retained = builtin.broker and builtin.broker.retained[topic]
    if cached then
      log:debug("Sending cached message to new subscriber: device=%s topic=%s", deviceId, topic)
      sendToChild(deviceId, topic, cached.payload, cached.qos, cached.retain)
    elseif retained then
      log:debug("Sending retained message to new subscriber: device=%s topic=%s", deviceId, topic)
      lastMessages[topic] = { payload = retained.payload, qos = 0, retain = true }
      sendToChild(deviceId, topic, retained.payload, 0, true)
    end
    return
  end

  -- Subscribe to MQTT broker if this is a new topic
  if MQTT_CONNECTED and MQTT and isNewTopicSubscription then
    log:debug("Subscribing to topic: %s (qos=%s)", topic, qos)
    MQTT:Subscribe(topic, qos)
  elseif not isNewTopicSubscription then
    -- Send cached message to new subscriber (broker won't re-send retained messages)
    local cached = lastMessages[topic]
    if cached then
      log:debug("Sending cached message to new subscriber: device=%s topic=%s", deviceId, topic)
      sendToChild(deviceId, topic, cached.payload, cached.qos, cached.retain)
    end
  end
end

-- Handle PUBLISH command from child drivers
function RFP.PUBLISH(idBinding, strCommand, tParams, args)
  log:trace("RFP.PUBLISH(%s, %s, %s, %s)", idBinding, strCommand, tParams, args)

  local topic = Select(tParams, "topic")
  local payload = Select(tParams, "payload") or ""
  local qos = tonumber(Select(tParams, "qos")) or 0
  local retain = toboolean(Select(tParams, "retain"))

  if IsEmpty(topic) then
    log:warn("PUBLISH called with empty topic")
    return
  end

  if isBuiltIn() then
    if not MQTT_CONNECTED or builtin.broker == nil then
      log:warn("Cannot publish - built-in broker is not running")
      return
    end
    log:debug("Publishing to topic=%s payload=%s retain=%s", topic, payload, retain)
    if not builtin.broker:publish(topic, payload, retain) then
      log:error("Publish failed: invalid topic '%s'", topic)
    end
    return
  end

  if not MQTT_CONNECTED or not MQTT then
    log:warn("Cannot publish - not connected to MQTT broker")
    return
  end

  log:debug("Publishing to topic=%s payload=%s qos=%s retain=%s", topic, payload, qos, retain)
  local errCode = MQTT:Publish(topic, payload, qos, retain)
  if errCode ~= 0 then
    local errorString = MQTT:ErrorCodeToString(errCode) or "unknown"
    log:error("Publish failed: %s - %s", errCode, errorString)
  end
end

--- Forget a topic nobody subscribes to any more.
local function dropTopic(topic)
  subscriptions[topic] = nil
  if isBuiltIn() then
    lastMessages[topic] = nil
  elseif MQTT_CONNECTED and MQTT and not ownSubscriptions[topic] then
    log:debug("Unsubscribing from topic: %s", topic)
    MQTT:Unsubscribe(topic)
  end
end

-- Handle UNSUBSCRIBE command from child drivers
function RFP.UNSUBSCRIBE(idBinding, strCommand, tParams, args)
  log:trace("RFP.UNSUBSCRIBE(%s, %s, %s, %s)", idBinding, strCommand, tParams, args)
  local topic = Select(tParams, "topic")
  local deviceId = tonumber(Select(tParams, "device_id"))

  if IsEmpty(topic) then
    log:warn("UNSUBSCRIBE called with empty topic")
    return
  end

  if not deviceId then
    log:warn("UNSUBSCRIBE called without device_id")
    return
  end

  if subscriptions[topic] then
    subscriptions[topic][deviceId] = nil
    log:debug("Unregistered subscription: device=%s topic=%s", deviceId, topic)

    -- Only unsubscribe from broker if no other devices need this topic
    if not next(subscriptions[topic]) then
      dropTopic(topic)
    end
  end
end

-- Handle GET_STATUS command from child drivers
function RFP.GET_STATUS(idBinding, strCommand, tParams, args)
  log:trace("RFP.GET_STATUS(%s, %s, %s, %s)", idBinding, strCommand, tParams, args)
  SendToProxy(idBinding, MQTT_CONNECTED and "BROKER_CONNECTED" or "BROKER_DISCONNECTED", {}, "NOTIFY")
end

-- Track binding connections
OBC[MQTT_BROKER_BINDING] = function(idBinding, strClass, bIsBound, otherDeviceId, otherBindingId)
  log:trace(
    "OBC[MQTT_BROKER_BINDING](%s, %s, %s, %s, %s)",
    idBinding,
    strClass,
    bIsBound,
    otherDeviceId,
    otherBindingId
  )

  if bIsBound then
    -- Send current status to newly connected driver via broadcast on our binding
    SendToProxy(idBinding, MQTT_CONNECTED and "BROKER_CONNECTED" or "BROKER_DISCONNECTED", {}, "NOTIFY")
  else
    -- Clean up subscriptions for this device
    for topic, devices in pairs(subscriptions) do
      devices[otherDeviceId] = nil
      if IsEmpty(devices) then
        dropTopic(topic)
      end
    end
  end
end

-- Tasmota devices for child drivers: the list, then one device on request
function RFP.GET_TASMOTA_DEVICES(idBinding, strCommand, tParams, args)
  log:trace("RFP.GET_TASMOTA_DEVICES(%s, %s, %s, %s)", idBinding, strCommand, tParams, args)
  local deviceId = tonumber(Select(tParams, "device_id"))
  if not deviceId then
    log:warn("GET_TASMOTA_DEVICES called without device_id")
    return
  end
  local list = {}
  for _, dev in pairs(tasmotaDevices) do
    list[#list + 1] = Tasmota.summary(dev)
  end
  for _, dev in pairs(shellyDevices) do
    if #(dev.components or {}) > 0 or #(dev.inputs or {}) > 0 or #(dev.covers or {}) > 0 then
      list[#list + 1] = Shelly.summary(dev)
    end
  end
  -- Zigbee lights go to MQTT Light drivers only (the others have nothing to use them for yet).
  local isLight = false
  for _, id in ipairs(AutoBind.devices("cp_mqtt_light.c4z")) do
    if id == deviceId then
      isLight = true
    end
  end
  if isLight then
    for _, dev in pairs(zigbeeDevices) do
      if #Zigbee.loads(dev) > 0 then
        list[#list + 1] = Zigbee.summary(dev)
      end
    end
  end
  table.sort(list, function(a, b)
    return a.name:lower() .. a.topic < b.name:lower() .. b.topic
  end)
  SendToDevice(deviceId, "TASMOTA_DEVICES", { devices = JSON:encode(list) })
end

function RFP.GET_TASMOTA_DEVICE(idBinding, strCommand, tParams, args)
  log:trace("RFP.GET_TASMOTA_DEVICE(%s, %s, %s, %s)", idBinding, strCommand, tParams, args)
  local deviceId = tonumber(Select(tParams, "device_id"))
  local mac = Select(tParams, "mac")
  if not deviceId or IsEmpty(mac) then
    log:warn("GET_TASMOTA_DEVICE needs device_id and mac")
    return
  end
  local dev = tasmotaDevices[mac] or shellyDevices[mac] or zigbeeDevices[mac]
  SendToDevice(deviceId, "TASMOTA_DEVICE", { mac = mac, device = dev and JSON:encode(dev) or "" })
end

-----------------------------------------------------------------------
-- Actions
-----------------------------------------------------------------------

function EC.PrintTasmotaDevices()
  local list = {}
  for _, dev in pairs(tasmotaDevices) do
    list[#list + 1] = dev
  end
  table.sort(list, function(a, b)
    return a.name:lower() < b.name:lower()
  end)
  local lines = { string.format("==== %d Tasmota devices ====", #list) }
  for _, dev in ipairs(list) do
    local loads = {}
    for _, l in ipairs(Tasmota.loads(dev)) do
      loads[#loads + 1] = l.label .. " (" .. l.power .. ")"
    end
    lines[#lines + 1] = string.format(
      "%-24s %-24s %-15s %-20s %s",
      dev.name:sub(1, 24),
      dev.topic:sub(1, 24),
      dev.ip,
      dev.model:sub(1, 20),
      table.concat(loads, ", ")
    )
    for _, note in ipairs(Tasmota.notes(dev)) do
      lines[#lines + 1] = "    ! " .. note
    end
  end
  print(table.concat(lines, "\n"))
end

function EC.ForgetTasmotaDevices()
  tasmotaDevices = {}
  tasmotaRaw = {}
  persist:set(TASMOTA_PERSIST_KEY, nil)
  persist:set(TASMOTA_RAW_PERSIST_KEY, nil)
  updateTasmotaProperty()
  notifyChildDrivers("TASMOTA_DEVICES_CHANGED", {})
  log:print("Forgot all Tasmota devices; connected devices are listed again when they next connect")
end

function EC.PrintShellyDevices()
  local list = {}
  for _, dev in pairs(shellyDevices) do
    list[#list + 1] = dev
  end
  table.sort(list, function(a, b)
    return a.name:lower() < b.name:lower()
  end)
  local lines = { string.format("==== %d Shelly devices ====", #list) }
  for _, dev in ipairs(list) do
    local loads = {}
    for _, l in ipairs(Shelly.loads(dev)) do
      loads[#loads + 1] = l.label .. " (" .. l.id .. ")"
    end
    lines[#lines + 1] = string.format(
      "%-24s %-32s %-14s %s",
      dev.name:sub(1, 24),
      dev.topic:sub(1, 32),
      (dev.model or ""):sub(1, 14),
      IsEmpty(loads) and "no light or relay outputs" or table.concat(loads, ", ")
    )
  end
  print(table.concat(lines, "\n"))
end

function EC.FindShellyDevices()
  shellyFetched = {}
  if publishOwn(Shelly.BROADCAST_TOPIC, "announce") then
    log:print("Asked every Shelly to announce itself; run Print Shelly Devices in a few seconds")
  else
    log:print("Not connected to a broker; Shelly devices cannot be asked now")
  end
end

function EC.ForgetShellyDevices()
  shellyDevices = {}
  shellyFetched = {}
  persist:set(SHELLY_PERSIST_KEY, nil)
  updateShellyProperty()
  notifyChildDrivers("TASMOTA_DEVICES_CHANGED", {})
  log:print("Forgot all Shelly devices; connected ones are listed again when they next announce")
end

function EC.PrintZigbeeDevices()
  local list = {}
  for _, dev in pairs(zigbeeDevices) do
    list[#list + 1] = dev
  end
  table.sort(list, function(a, b)
    return (a.topic .. a.name):lower() < (b.topic .. b.name):lower()
  end)
  local lines = { string.format("==== %d Zigbee devices ====", #list) }
  for _, dev in ipairs(list) do
    local loads = Zigbee.loads(dev)
    local stateTopic = Zigbee.state(dev)
    lines[#lines + 1] = string.format(
      "%-20s %-7s %-12s %-24s %-20s %s",
      dev.name:sub(1, 20),
      dev.short,
      tostring(dev.topic):sub(1, 12),
      (dev.model or ""):sub(1, 24),
      loads[1] and loads[1].label or "not a light",
      dev.stateTopic and stateTopic or (stateTopic .. " (not seen yet)")
    )
  end
  print(table.concat(lines, "\n"))
end

function EC.FindZigbeeDevices()
  if not MQTT_CONNECTED then
    log:print("Not connected to a broker; Zigbee gateways cannot be asked now")
    return
  end
  findZigbee(true)
  log:print("Asked every Tasmota for its Zigbee devices; run Print Zigbee Devices in a few seconds")
end

function EC.ForgetZigbeeDevices()
  zigbeeDevices = {}
  for _, gw in pairs(zigbeeGateways) do
    gw.style = nil
    gw.lastAsked = nil
  end
  persist:set(ZIGBEE_PERSIST_KEY, nil)
  updateZigbeeProperty()
  notifyChildDrivers("TASMOTA_DEVICES_CHANGED", {})
  log:print("Forgot all Zigbee devices; run Find Zigbee Devices to read them again")
end

-- Action: Reconnect (External) / Restart (Built-in)
function EC.Reconnect()
  log:trace("EC.Reconnect()")
  log:print(isBuiltIn() and "Restarting the built-in broker" or "Reconnecting to MQTT broker")
  Connect()
end

local function requireBuiltIn()
  if not isBuiltIn() or builtin.server == nil then
    print("This action is only available in Built-in broker mode")
    return false
  end
  return true
end

function EC.PrintReport()
  if not requireBuiltIn() then
    return
  end
  local lines = { "==== Built-in MQTT broker ====" }
  for _, row in ipairs(builtin.server:report()) do
    lines[#lines + 1] = string.format("%-22s %s", row[1] .. ":", row[2])
  end
  local childTopics = 0
  for _ in pairs(subscriptions) do
    childTopics = childTopics + 1
  end
  lines[#lines + 1] = string.format("%-22s %d", "Driver Topics:", childTopics)
  lines[#lines + 1] = "=============================="
  print(table.concat(lines, "\n"))
end

function EC.PrintClients()
  if requireBuiltIn() then
    print(builtin.server:clientsText())
  end
end

function EC.PrintRetained()
  if requireBuiltIn() then
    print(builtin.server:retainedText())
  end
end

function EC.ResetStatistics()
  if requireBuiltIn() then
    builtin.broker:resetStats()
    builtin.server:resetStats()
    updateBuiltInProperties()
    log:print("Statistics reset")
  end
end

-- Action: Update Drivers
function EC.UpdateDrivers()
  log:trace("EC.UpdateDrivers()")
  UpdateDrivers(true, true)
end

--- Installed MQTT drivers and their versions, as "cp_mqtt_broker.c4z 2026102502, ...".
--- @return string[] filenames, table<string, string> versions
local function installedDrivers()
  local files, versions = {}, {}
  for _, filename in ipairs(DRIVER_FILENAMES) do
    if not IsEmpty(C4:GetDevicesByC4iName(filename) or {}) then
      files[#files + 1] = filename
      local ok, v = pcall(GetDriverVersion, filename)
      versions[filename] = ok and v or nil
    end
  end
  return files, versions
end

--- After an update was sent: check that every driver now has the release's
--- version, and say so. Runs on the next start of this driver (the update
--- restarts it) or, when this driver was not part of the update, after a delay.
function VerifyDriverUpdate()
  local pending = persist:get(UPDATE_PERSIST_KEY, nil)
  if type(pending) ~= "table" then
    return
  end
  persist:delete(UPDATE_PERSIST_KEY)
  CancelTimer("UpdateVerify")
  local _, versions = installedDrivers()
  local ok, failed = {}, {}
  for _, filename in ipairs(pending.drivers or {}) do
    local v = versions[filename]
    if v == pending.version then
      ok[#ok + 1] = filename
    else
      failed[#failed + 1] = string.format("%s is on %s", filename, tostring(v or "unknown"))
    end
  end
  if IsEmpty(failed) then
    log:print("Update to %s succeeded: %s on version %s", pending.tag, table.concat(ok, ", "), pending.version)
  else
    log:print(
      "Update to %s FAILED: %s (expected %s). Run Update Drivers again or install the .c4z files from GitHub.",
      pending.tag,
      table.concat(failed, ", "),
      pending.version
    )
  end
end

local function errorText(err)
  if type(err) == "table" then
    local parts = {}
    for _, e in pairs(err) do
      parts[#parts + 1] = tostring(e)
    end
    return table.concat(parts, "; ")
  end
  return tostring(err)
end

--- Update the drivers from the GitHub repository.
--- @param forceUpdate? boolean Reinstall even if the drivers are up to date (optional).
--- @param manual? boolean Asked for by the user: every step goes to the log (optional).
function UpdateDrivers(forceUpdate, manual)
  log:trace("UpdateDrivers(%s, %s)", forceUpdate, manual)
  local say = function(...)
    if manual then
      log:print(...)
    else
      log:info(...)
    end
  end
  local files, versions = installedDrivers()
  local current = {}
  for _, filename in ipairs(files) do
    current[#current + 1] = string.format("%s %s", filename, tostring(versions[filename] or "?"))
  end
  say(
    "Update started: checking %s for the latest release (installed: %s)",
    DRIVER_GITHUB_REPO,
    table.concat(current, ", ")
  )
  githubUpdater
    :updateAll(DRIVER_GITHUB_REPO, DRIVER_FILENAMES, Properties["Update Channel"] == "Prerelease", forceUpdate)
    :next(function(updatedDrivers)
      local release = githubUpdater.lastRelease or {}
      local tag = tostring(release.tag_name or "?")
      if IsEmpty(updatedDrivers) then
        say("Update finished: already on the latest release %s, nothing to install", tag)
        return
      end
      local version = tag:gsub("^[vV]", "")
      persist:set(UPDATE_PERSIST_KEY, { tag = tag, version = version, drivers = updatedDrivers })
      log:print(
        "Update: %s downloaded and sent to the controller (%s); the drivers restart now",
        tag,
        table.concat(updatedDrivers, ", ")
      )
      -- If this driver is not restarted by the update, check once the others had time.
      SetTimer("UpdateVerify", 2 * ONE_MINUTE, VerifyDriverUpdate)
    end, function(error)
      local text = errorText(error)
      if manual then
        log:print("Update FAILED: %s", text)
      end
      log:error("An error occurred updating drivers: %s", text)
    end)
end
