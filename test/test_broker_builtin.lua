-- Tests for the MQTT Broker driver's Built-in mode: the controller is the
-- broker, MQTT devices connect over TCP, and child drivers (MQTT Light,
-- MQTT General) use the same SUBSCRIBE / PUBLISH commands as in External
-- mode.
--
-- C4:CreateTCPServer is faked here so the test needs no network.
--
-- Run from the repo root:
--   make test
-- or:
--   ./test/run_test.sh test_broker_builtin.lua

local T = require("testlib")
require("c4_shim")
local Codec = require("mqtt.server.codec")

-------------------------------------------------------------------------------
-- Fakes
-------------------------------------------------------------------------------

local proxyMsgs, deviceMsgs, events, attribs = {}, {}, {}, {}
C4.SendToProxy = function(_, binding, command, params, kind)
  proxyMsgs[#proxyMsgs + 1] = { binding = binding, command = command, params = params or {}, kind = kind }
end
C4.SendToDevice = function(_, deviceId, command, params)
  deviceMsgs[#deviceMsgs + 1] = { deviceId = deviceId, command = command, params = params or {} }
end
C4.FireEvent = function(_, name)
  events[#events + 1] = name
end
C4.SetPropertyAttribs = function(_, name, value)
  attribs[name] = value
end
local propertyWrites = {}
C4.UpdateProperty = function(_, name, value)
  propertyWrites[name] = value
end
local realGetDriverConfigInfo = C4.GetDriverConfigInfo
C4.GetDriverConfigInfo = function(c4, section)
  if section == "minimum_os_version" then
    return "3.3.0"
  end
  return realGetDriverConfigInfo(c4, section)
end
local mqttClients = 0
local lastMqtt = nil
--- Fake C4:MQTT client: On* callbacks are kept, every other call is recorded.
C4.MQTT = function()
  mqttClients = mqttClients + 1
  local client = { callbacks = {}, calls = {} }
  setmetatable(client, {
    __index = function(_, name)
      return function(self, ...)
        if name:sub(1, 2) == "On" then
          self.callbacks[name] = ...
        else
          self.calls[#self.calls + 1] = { name, ... }
        end
        return 0
      end
    end,
  })
  lastMqtt = client
  return client
end

--- Fake TCP server: Listen succeeds at once, tests call accept() to connect.
local servers = {}
C4.CreateTCPServer = function()
  local srv = { closed = false }
  function srv:Option()
    return self
  end
  for _, name in ipairs({ "OnListen", "OnError", "OnAccept", "OnResolve" }) do
    srv[name] = function(self, fn)
      self[name .. "Fn"] = fn
      return self
    end
  end
  function srv:Listen(_, port)
    self.port = port
    servers[#servers + 1] = self
    self.OnListenFn(self, { ip = "0.0.0.0", port = port })
    return self
  end
  function srv:GetLocalAddress()
    return { ip = "0.0.0.0", port = self.port }
  end
  function srv:Close()
    self.closed = true
    return self
  end
  return srv
end

--- A fake device on the network: feed() sends bytes, received holds decoded packets.
local function accept(srv, name)
  local client = { received = {}, closed = false, reader = Codec.reader() }
  for _, n in ipairs({ "OnRead", "OnWrite", "OnDisconnect", "OnError" }) do
    client[n] = function(self, fn)
      self[n .. "Fn"] = fn
      return self
    end
  end
  function client:ReadUpTo()
    return self
  end
  function client:Option()
    return self
  end
  function client:GetRemoteAddress()
    return { ip = "10.0.0." .. name, port = 50000 }
  end
  function client:Write(bytes)
    for _, raw in ipairs((self.reader:feed(bytes))) do
      self.received[#self.received + 1] = Codec.decode(raw.first, raw.body)
    end
    return self
  end
  function client:Close()
    self.closed = true
    return self
  end
  function client:feed(bytes)
    self.OnReadFn(self, bytes)
  end
  function client:take()
    local out = self.received
    self.received = {}
    return out
  end
  srv.OnAcceptFn(srv, client)
  return client
end

local function last(list)
  return list[#list]
end

local function childMessages()
  local out = {}
  for _, m in ipairs(deviceMsgs) do
    if m.command == "MQTT_MESSAGE" then
      out[#out + 1] = string.format("%d %s=%s", m.deviceId, m.params.topic, m.params.payload)
    end
  end
  deviceMsgs = {}
  return out
end

local function notifies(command)
  local n = 0
  for _, m in ipairs(proxyMsgs) do
    if m.command == command then
      n = n + 1
    end
  end
  return n
end

-------------------------------------------------------------------------------
-- Load the driver
-------------------------------------------------------------------------------

local xml = assert(io.open("drivers/cp_mqtt_broker/driver.xml")):read("*a")
for block in xml:gmatch("<property>(.-)</property>") do
  Properties[block:match("<name>(.-)</name>")] = block:match("<default>(.-)</default>") or ""
end
Properties["Log Level"] = "2 - Warning"
Properties["Automatic Updates"] = "Off"

local loaded, loadErr = T.capture(function()
  dofile("drivers/cp_mqtt_broker/driver.lua")
  OnDriverInit()
  OnDriverLateInit()
end)
T.check("the driver loads and starts", loaded, loadErr)

-------------------------------------------------------------------------------
T.section("External mode stays the default")
-------------------------------------------------------------------------------
T.eq("Broker Mode defaults to External", Properties["Broker Mode"], "External")
T.eq("no server is started", #servers, 0)
T.eq("built-in properties are hidden", attribs["Listen Port"], 1)
T.eq("external properties are shown", attribs["Broker Address"], 0)

-------------------------------------------------------------------------------
T.section("Switching to Built-in")
-------------------------------------------------------------------------------
proxyMsgs = {}
Properties["Broker Mode"] = "Built-in"
local switched, switchErr = T.capture(function()
  OnPropertyChanged("Broker Mode")
end)
T.check("switching mode runs without error", switched, switchErr)
local srv = last(servers)
T.check("a server listens", srv ~= nil)
T.eq("on port 3883", srv and srv.port, 3883)
T.eq("children hear BROKER_CONNECTED", notifies("BROKER_CONNECTED"), 1)
T.eq("Broker Connected event fires", last(events), "Broker Connected")
T.eq("visibility flips", { attribs["Listen Port"], attribs["Broker Address"] }, { 0, 1 })
T.contains("Driver Status", propertyWrites["Driver Status"], "Built-in broker on port 3883")

local function connectDevice(name, will)
  local dev = accept(srv, name)
  dev:feed(Codec.connect({ clientId = "tasmota_" .. name, keepAlive = 30, will = will }))
  dev:feed(Codec.subscribe(1, { { "cmnd/tasmota_" .. name .. "/#", 0 } }))
  dev:take()
  return dev
end

-------------------------------------------------------------------------------
T.section("Device -> child driver")
-------------------------------------------------------------------------------
local LIGHT, UNIVERSAL = 101, 202
T.capture(function()
  ReceivedFromProxy(5001, "SUBSCRIBE", { topic = "stat/tasmota_1/RESULT", device_id = tostring(LIGHT) })
  ReceivedFromProxy(5001, "SUBSCRIBE", { topic = "tele/tasmota_1/LWT", device_id = tostring(LIGHT) })
end)
T.eq("nothing to hand over yet", childMessages(), {})

local dev1 = connectDevice("1", { topic = "tele/tasmota_1/LWT", payload = "Offline", retain = true })
dev1:feed(Codec.publish("tele/tasmota_1/LWT", "Online", { retain = true }))
dev1:feed(Codec.publish("stat/tasmota_1/RESULT", '{"POWER":"ON","Dimmer":40}'))
dev1:feed(Codec.publish("tele/tasmota_1/SENSOR", "{}"))
T.eq("subscribed topics reach the child, others do not", childMessages(), {
  "101 tele/tasmota_1/LWT=Online",
  '101 stat/tasmota_1/RESULT={"POWER":"ON","Dimmer":40}',
})

T.capture(function()
  ReceivedFromProxy(5001, "SUBSCRIBE", { topic = "stat/tasmota_1/RESULT", device_id = tostring(UNIVERSAL) })
end)
T.eq("a second child gets the latest message at once", childMessages(), {
  '202 stat/tasmota_1/RESULT={"POWER":"ON","Dimmer":40}',
})

-- A retained message published before any child subscribed
local dev2 = connectDevice("2")
dev2:feed(Codec.publish("tele/tasmota_2/LWT", "Online", { retain = true }))
T.eq("not subscribed yet: nothing sent", childMessages(), {})
T.capture(function()
  ReceivedFromProxy(5001, "SUBSCRIBE", { topic = "tele/tasmota_2/LWT", device_id = tostring(LIGHT) })
end)
T.eq("subscribing hands over the retained message", childMessages(), { "101 tele/tasmota_2/LWT=Online" })
local retainedFlag = nil
T.capture(function()
  ReceivedFromProxy(5001, "SUBSCRIBE", { topic = "tele/tasmota_2/LWT", device_id = "303" })
end)
retainedFlag = last(deviceMsgs) and last(deviceMsgs).params.retain
T.eq("handed-over retained message is flagged retained", retainedFlag, "true")
childMessages()

-------------------------------------------------------------------------------
T.section("Child driver -> device")
-------------------------------------------------------------------------------
T.capture(function()
  ReceivedFromProxy(5001, "PUBLISH", { topic = "cmnd/tasmota_1/POWER1", payload = "ON", qos = "0", retain = "false" })
end)
local got = dev1:take()
T.eq("the device gets the command", got[1] and (got[1].topic .. "=" .. got[1].payload), "cmnd/tasmota_1/POWER1=ON")
T.eq("the other device does not", #dev2:take(), 0)

T.capture(function()
  ReceivedFromProxy(5001, "PUBLISH", { topic = "stat/tasmota_1/RESULT", payload = "from-driver" })
end)
T.eq("a driver's publish also reaches subscribed drivers, like an external broker", #childMessages(), 2)

-------------------------------------------------------------------------------
T.section("Last Will reaches the child driver")
-------------------------------------------------------------------------------
dev1.OnDisconnectFn(dev1, 104, "connection reset")
T.eq("Offline is delivered", childMessages(), { "101 tele/tasmota_1/LWT=Offline" })

-------------------------------------------------------------------------------
T.section("Unsubscribe and unbinding")
-------------------------------------------------------------------------------
T.capture(function()
  ReceivedFromProxy(5001, "UNSUBSCRIBE", { topic = "tele/tasmota_2/LWT", device_id = tostring(LIGHT) })
  ReceivedFromProxy(5001, "UNSUBSCRIBE", { topic = "tele/tasmota_2/LWT", device_id = "303" })
end)
dev2:feed(Codec.publish("tele/tasmota_2/LWT", "Online", { retain = true }))
T.eq("no messages after unsubscribing", childMessages(), {})
T.capture(function()
  OnBindingChanged(5001, "CP_MQTT_BROKER", false, UNIVERSAL, 1)
end)
local dev3 = connectDevice("3")
dev3:feed(Codec.publish("stat/tasmota_1/RESULT", "x"))
T.eq("an unbound driver gets nothing", childMessages(), { "101 stat/tasmota_1/RESULT=x" })

-------------------------------------------------------------------------------
T.section("Status, actions, restart")
-------------------------------------------------------------------------------
proxyMsgs = {}
T.capture(function()
  ReceivedFromProxy(5001, "GET_STATUS", {})
end)
T.eq("GET_STATUS answers connected", notifies("BROKER_CONNECTED"), 1)
local _, _, out = T.capture(function()
  ExecuteCommand("LUA_ACTION", { ACTION = "PrintClients" })
end)
T.contains("Print Clients lists devices", out, "tasmota_2")
_, _, out = T.capture(function()
  ExecuteCommand("LUA_ACTION", { ACTION = "PrintReport" })
end)
T.contains("Print Report", out, "Connected Clients")

local before = #servers
proxyMsgs = {}
T.capture(function()
  ExecuteCommand("LUA_ACTION", { ACTION = "Reconnect" })
end)
T.eq("Reconnect restarts the server", #servers, before + 1)
T.eq("the old server is closed", servers[before].closed, true)
T.eq("connected devices are closed", dev2.closed, true)
T.eq(
  "children hear disconnected, then connected",
  { notifies("BROKER_DISCONNECTED"), notifies("BROKER_CONNECTED") },
  { 1, 1 }
)

-------------------------------------------------------------------------------
T.section("Tasmota discovery through the built-in broker")
-------------------------------------------------------------------------------
local function discoveryPayload(topic, name, lt, rl)
  return string.format(
    '{"ip":"10.0.0.9","dn":"%s","fn":["%s",null,null,null,null,null,null,null],"hn":"%s","mac":"%s",'
      .. '"md":"Generic","ty":0,"if":0,"cam":0,"ofln":"Offline","onln":"Online",'
      .. '"state":["OFF","ON","TOGGLE","HOLD"],"sw":"14.3.0","t":"%s","ft":"%%prefix%%/%%topic%%/",'
      .. '"tp":["cmnd","stat","tele"],"rl":[%s],"swc":[],"swn":[],"btn":[],'
      .. '"so":{"4":0,"11":0,"13":0,"17":0,"20":0,"30":0,"68":0,"73":0,"82":0,"114":0,"117":0},'
      .. '"lk":1,"lt_st":%d,"bat":0,"dslp":0,"sho":[],"sht":[],"ver":1}',
    name,
    name,
    topic,
    "MAC" .. topic,
    topic,
    rl,
    lt
  )
end

local tasDev = accept(last(servers), "9")
tasDev:feed(Codec.connect({ clientId = "DVES_9", keepAlive = 30 }))
proxyMsgs = {}
tasDev:feed(
  Codec.publish("tasmota/discovery/MACkitchen/config", discoveryPayload("kitchen", "Kitchen", 5, "2,0,0,0,0,0,0,0"), {
    retain = true,
  })
)
T.eq("Tasmota Devices property counts it", propertyWrites["Tasmota Devices"], "1")
T.eq("children hear TASMOTA_DEVICES_CHANGED", notifies("TASMOTA_DEVICES_CHANGED"), 1)
proxyMsgs = {}
tasDev:feed(
  Codec.publish("tasmota/discovery/MACkitchen/config", discoveryPayload("kitchen", "Kitchen", 5, "2,0,0,0,0,0,0,0"), {
    retain = true,
  })
)
T.eq("the same config again changes nothing", notifies("TASMOTA_DEVICES_CHANGED"), 0)
tasDev:feed(Codec.publish("tasmota/discovery/MAChall/config", discoveryPayload("hall", "Hall", 0, "1,1,0,0,0,0,0,0"), {
  retain = true,
}))

deviceMsgs = {}
T.capture(function()
  ReceivedFromProxy(5001, "GET_TASMOTA_DEVICES", { device_id = "101" })
end)
local reply = last(deviceMsgs)
T.eq(
  "the list goes to the asking driver",
  { reply and reply.deviceId, reply and reply.command },
  { 101, "TASMOTA_DEVICES" }
)
local list = JSON:decode(reply.params.devices)
T.eq("sorted by name", { list[1].name, list[2].name }, { "Hall", "Kitchen" })
T.eq("with their loads", { #list[1].loads, list[2].loads[1].label }, { 2, "RGBCCT light" })

T.capture(function()
  ReceivedFromProxy(5001, "GET_TASMOTA_DEVICE", { device_id = "101", mac = "MACkitchen" })
end)
reply = last(deviceMsgs)
local detail = JSON:decode(reply.params.device)
T.eq("one device in full", { reply.command, detail.topic, detail.lightType }, { "TASMOTA_DEVICE", "kitchen", 5 })
T.capture(function()
  ReceivedFromProxy(5001, "GET_TASMOTA_DEVICE", { device_id = "101", mac = "nope" })
end)
T.eq("an unknown device answers empty", last(deviceMsgs).params.device, "")

proxyMsgs = {}
tasDev:feed(Codec.publish("tasmota/discovery/MAChall/config", "", { retain = true }))
T.eq("an empty config removes the device", propertyWrites["Tasmota Devices"], "1")
T.eq("and children hear about it", notifies("TASMOTA_DEVICES_CHANGED"), 1)

local _, _, printed = T.capture(function()
  ExecuteCommand("LUA_ACTION", { ACTION = "PrintTasmotaDevices" })
end)
T.contains("Print Tasmota Devices", printed, "RGBCCT light (POWER)")

-------------------------------------------------------------------------------
T.section("Shelly discovery (built-in)")
-------------------------------------------------------------------------------
local SP = "shellyplusrgbwpm-a0a3b3c4d5e6"
local function shellyInfo(prefixId, name)
  return JSON:encode({
    name = name,
    id = prefixId,
    mac = "A0A3B3C4D5E6",
    slot = 0,
    model = "SNDC-0D4P10WW",
    gen = 2,
    fw_id = "20241011-114455/1.4.4-g6d2a586",
    ver = "1.4.4",
    app = "PlusRGBWPM",
    auth_en = false,
    profile = "rgbw",
  })
end
local function topicsOf(packets)
  local out = {}
  for _, p in ipairs(packets) do
    out[#out + 1] = p.topic .. "=" .. p.payload
  end
  return out
end
local function find(packets, topic)
  for _, p in ipairs(packets) do
    if p.topic == topic then
      return p
    end
  end
  return nil
end

local shellyDev = accept(last(servers), "20")
shellyDev:feed(Codec.connect({
  clientId = SP,
  keepAlive = 60,
  will = { topic = SP .. "/online", payload = "false" },
}))
-- As a Shelly does: online first, then its subscriptions
shellyDev:feed(Codec.publish(SP .. "/online", "true", { retain = true }))
shellyDev:feed(Codec.subscribe(1, {
  { SP .. "/rpc", 0 },
  { SP .. "/command", 0 },
  { SP .. "/command/#", 0 },
  { "shellies/command", 0 },
}))
shellyDev:take()
T.capture(function()
  ShimFireTimers()
end)
local announceAsk = find(shellyDev:take(), SP .. "/command")
T.eq("online: the device is asked to announce itself", announceAsk and announceAsk.payload, "announce")

shellyDev:feed(Codec.publish("shellies/announce", shellyInfo(SP, "Living RGBW")))
T.eq("the shared announce topic gives no prefix: nothing asked", #shellyDev:take(), 0)
shellyDev:feed(Codec.publish(SP .. "/announce", shellyInfo(SP, "Living RGBW")))
local ask = find(shellyDev:take(), SP .. "/rpc")
local askBody = ask and JSON:decode(ask.payload) or {}
T.eq("its configuration is asked for over RPC", { askBody.method, askBody.src }, {
  "Shelly.GetConfig",
  "control4/shelly",
})

proxyMsgs = {}
shellyDev:feed(Codec.publish(
  "control4/shelly/rpc",
  JSON:encode({
    id = askBody.id,
    src = SP,
    dst = "control4/shelly",
    result = {
      sys = { device = { name = "Living RGBW", mac = "A0A3B3C4D5E6" } },
      ["rgbw:0"] = { id = 0, name = JSON.null },
      ["input:0"] = { id = 0, name = JSON.null, type = "button" },
      mqtt = { enable = true, server = "10.0.0.2:3883" },
    },
  })
))
T.eq("Shelly Devices property counts it", propertyWrites["Shelly Devices"], "1")
T.eq("children hear about it", notifies("TASMOTA_DEVICES_CHANGED"), 1)

shellyDev:feed(Codec.publish(SP .. "/announce", shellyInfo(SP, "Living RGBW")))
T.eq("announced again soon after: not asked again", find(shellyDev:take(), SP .. "/rpc"), nil)

shellyDev:feed(
  Codec.publish(
    "shellies/announce",
    '{"id":"shellydimmer2-E8DB84D4A1B2","model":"SHDM-2","mac":"E8DB84D4A1B2","ip":"10.0.0.9","new_fw":false,"fw_ver":"x"}'
  )
)
shellyDev:feed(
  Codec.publish(
    "shellies/shellydimmer2-E8DB84D4A1B2/announce",
    '{"id":"shellydimmer2-E8DB84D4A1B2","model":"SHDM-2","mac":"E8DB84D4A1B2","ip":"10.0.0.9","new_fw":false,"fw_ver":"x"}'
  )
)
T.eq("a Gen1 announce is ignored", propertyWrites["Shelly Devices"], "1")

shellyDev:feed(Codec.publish("control4/shelly/rpc", '{"id":5,"src":"stranger","result":{}}'))
T.eq("an answer nobody asked for is ignored", propertyWrites["Shelly Devices"], "1")

deviceMsgs = {}
T.capture(function()
  ReceivedFromProxy(5001, "GET_TASMOTA_DEVICES", { device_id = "101" })
end)
local merged = JSON:decode(last(deviceMsgs).params.devices)
local shellyEntry
for _, d in ipairs(merged) do
  if d.type == "shelly" then
    shellyEntry = d
  end
end
T.eq("the light's list has the Shelly too", shellyEntry and shellyEntry.name, "Living RGBW")
T.eq("with its output", shellyEntry and shellyEntry.loads[1].id, "rgbw:0")
T.capture(function()
  ReceivedFromProxy(5001, "GET_TASMOTA_DEVICE", { device_id = "101", mac = "A0A3B3C4D5E6" })
end)
local full = JSON:decode(last(deviceMsgs).params.device)
T.eq("and in full on request", { full.type, full.topic }, { "shelly", SP })

local _, _, shellyPrinted = T.capture(function()
  ExecuteCommand("LUA_ACTION", { ACTION = "PrintShellyDevices" })
end)
T.contains("Print Shelly Devices", shellyPrinted, "RGBW light (rgbw:0)")
T.capture(function()
  ExecuteCommand("LUA_ACTION", { ACTION = "FindShellyDevices" })
end)
local broadcast = find(shellyDev:take(), "shellies/command")
T.eq("Find Shelly Devices asks every device", broadcast and broadcast.payload, "announce")
shellyDev:feed(Codec.publish(SP .. "/announce", shellyInfo(SP, "Living RGBW")))
T.check("and reads each configuration again", find(shellyDev:take(), SP .. "/rpc") ~= nil)

-------------------------------------------------------------------------------
T.section("Back to External")
-------------------------------------------------------------------------------
local srvBuiltIn = last(servers)
Properties["Broker Mode"] = "External"
Properties["Broker Address"] = "192.168.1.5"
T.capture(function()
  OnPropertyChanged("Broker Mode")
end)
T.eq("the built-in server is closed", srvBuiltIn.closed, true)
T.check("an MQTT client is created", mqttClients >= 1)
T.eq("visibility flips back", { attribs["Listen Port"], attribs["Broker Address"] }, { 1, 0 })
proxyMsgs = {}
T.capture(function()
  ReceivedFromProxy(5001, "GET_STATUS", {})
end)
T.eq("not connected until the external broker answers", notifies("BROKER_DISCONNECTED"), 1)

-------------------------------------------------------------------------------
T.section("Tasmota discovery through an external broker")
-------------------------------------------------------------------------------
local client = lastMqtt
T.capture(function()
  client.callbacks.OnConnect(client, 0, 0, "")
end)
local subscribedDiscovery = false
for _, call in ipairs(client.calls) do
  if call[1] == "Subscribe" and call[2] == "tasmota/discovery/+/config" then
    subscribedDiscovery = true
  end
end
T.check("subscribes to tasmota/discovery/+/config on connect", subscribedDiscovery)
proxyMsgs = {}
deviceMsgs = {}
T.capture(function()
  client.callbacks.OnMessage(
    client,
    1,
    "tasmota/discovery/MACporch/config",
    discoveryPayload("porch", "Porch", 1, "2,0,0,0,0,0,0,0"),
    0,
    true
  )
end)
T.eq("an external discovery message is collected", propertyWrites["Tasmota Devices"], "2")
T.eq("children hear about it", notifies("TASMOTA_DEVICES_CHANGED"), 1)
T.eq("discovery is not routed to drivers that did not subscribe", #deviceMsgs, 0)

local subscribedShelly = {}
for _, call in ipairs(client.calls) do
  if call[1] == "Subscribe" then
    subscribedShelly[call[2]] = true
  end
end
T.check("subscribes to Shelly announces", subscribedShelly["+/announce"] and subscribedShelly["+/+/announce"])
T.check("and to Shelly RPC answers", subscribedShelly["control4/shelly/rpc"])
client.calls = {}
deviceMsgs = {}
T.capture(function()
  client.callbacks.OnMessage(
    client,
    2,
    "shellypro1-30c6f7aabbcc/announce",
    JSON:encode({
      id = "shellypro1-30c6f7aabbcc",
      mac = "30C6F7AABBCC",
      model = "SPSW-201XE16EU",
      gen = 2,
      ver = "1.4.4",
      app = "Pro1",
    }),
    0,
    false
  )
end)
local rpcCall
for _, call in ipairs(client.calls) do
  if call[1] == "Publish" and call[2] == "shellypro1-30c6f7aabbcc/rpc" then
    rpcCall = call
  end
end
T.check(
  "an external announce leads to Shelly.GetConfig",
  rpcCall ~= nil and rpcCall[3]:find("Shelly.GetConfig", 1, true)
)
T.eq("announces are not routed to drivers", #deviceMsgs, 0)

T.capture(function()
  ExecuteCommand("LUA_ACTION", { ACTION = "ForgetTasmotaDevices" })
end)
T.eq("Forget Tasmota Devices clears the list", propertyWrites["Tasmota Devices"], "0")

T.finish()
