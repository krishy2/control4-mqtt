-- Tests for Zigbee devices behind a Tasmota Zigbee gateway
-- (src/mqtt/tasmota_zigbee.lua), the broker asking gateways for them, and the
-- MQTT Light properties they give. Payloads are real answers from a Tasmota
-- Zigbee gateway with topic "zigbee" (SetOption89 1).
--
-- Run from the repo root:
--   make test

local T = require("testlib")
require("c4_shim")
require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")
JSON = JSON or require("JSON")
local Tasmota = require("mqtt.tasmota")
local Zigbee = require("mqtt.tasmota_zigbee")

local GW_MAC = "A0B1C2D3E4F5"
local discovery = '{"ip":"10.0.0.9","dn":"Zigbee Gateway","fn":["Tasmota",null,null,null,null,null,null,null],'
  .. '"hn":"zigbee-1234","mac":"'
  .. GW_MAC
  .. '","md":"ESP32-DevKit","ty":0,"if":0,"ofln":"Offline","onln":"Online",'
  .. '"state":["OFF","ON","TOGGLE","HOLD"],"sw":"14.3.0","t":"zigbee","ft":"%prefix%/%topic%/",'
  .. '"tp":["cmnd","stat","tele"],"rl":[0,0,0,0,0,0,0,0],"so":{"4":0,"11":0,"13":0,"17":0,"20":0,"30":0,'
  .. '"68":0,"73":0,"82":0,"114":0,"117":0},"lk":0,"lt_st":0,"ver":1}'
local LIST = '{"ZbStatus1":[{"Device":"0x9AC9","Name":"Outdoor_temp"},{"Device":"0xD824","Name":"Vindstyrka1"},'
  .. '{"Device":"0xE53A","Name":"spot1"},{"Device":"0xCD3F","Name":"STARKVIND"},{"Device":"0x372D"}]}'
local SPOT1 = '{"ZbStatus3":[{"Device":"0xE53A","Name":"spot1","IEEEAddr":"0xA4C13837E8E485BF","ModelId":"TS0502B",'
  .. '"Manufacturer":"_TZ3210_a046u4au","Endpoints":[1,242],"Config":["~01.1","O01","L01"],"Power":1,"Dimmer":0,'
  .. '"Hue":0,"X":0,"CT":0,"ColorMode":2,"Reachable":true,"LastSeen":44,"LastSeenEpoch":1795100150,"LinkQuality":98}]}'
local UNNAMED = '{"ZbStatus3":[{"Device":"0x372D","IEEEAddr":"0xA4C138D18EDA3FF5","ModelId":"TS0502B",'
  .. '"Manufacturer":"_TZ3210_a046u4au","Endpoints":[1,242],"Config":["~01.1","O01","L01"],"Power":1,'
  .. '"Dimmer":254,"Hue":0,"X":0,"CT":0,"Reachable":true,"LastSeen":38,"LastSeenEpoch":1795100327,"LinkQuality":138}]}'
local STARKVIND = '{"ZbStatus3":[{"Device":"0xCD3F","Name":"STARKVIND","IEEEAddr":"0xC02CEDFFFE2BDEB3",'
  .. '"ModelId":"STARKVIND Air purifier","Manufacturer":"IKEA of Sweden","Endpoints":[1,242],"Config":[],'
  .. '"Reachable":true,"LastSeen":68,"LastSeenEpoch":1795100258,"LinkQuality":7}]}'
local VINDSTYRKA = '{"ZbStatus3":[{"Device":"0xD824","Name":"Vindstyrka1","IEEEAddr":"0x3C2EF5FFFE4715AF",'
  .. '"ModelId":"VINDSTYRKA","Manufacturer":"IKEA of Sweden","Endpoints":[1,242],"Config":["T01"],'
  .. '"Temperature":26,"Humidity":62,"Reachable":true,"LastSeen":19,"LastSeenEpoch":1795100338,"LinkQuality":7}]}'

-------------------------------------------------------------------------------
T.section("Reading the gateway's answers")
-------------------------------------------------------------------------------
local gw = Tasmota.parse(discovery)
T.eq("the list topic", Zigbee.listTopic(gw), "cmnd/zigbee/ZbStatus1")
T.eq("answers arrive on", Zigbee.resultTopic(gw), "stat/zigbee/RESULT")
local list = Zigbee.parseResult(LIST)
T.eq("ZbStatus1 is the list", { list.kind, #list.devices }, { "list", 5 })
T.eq("an unnamed device has its address only", { list.devices[5].short, list.devices[5].name }, { "0x372D", nil })
T.eq("ZbStatus3 is a detail", Zigbee.parseResult(SPOT1).kind, "detail")
T.eq("a device unknown to the gateway", Zigbee.parseResult('{"ZbStatus":"Unknown device"}'), nil)
T.eq("not a gateway", Zigbee.parseResult('{"Command":"Unknown","Input":"ZbStatus1"}'), nil)
T.eq("short addresses are written the Tasmota way", Zigbee.shortAddress("e53a"), "0xE53A")

-------------------------------------------------------------------------------
T.section("What each device is")
-------------------------------------------------------------------------------
local spot1 = Zigbee.build(gw, Zigbee.parseResult(SPOT1).devices[1])
T.eq("keyed by IEEE address", { spot1.mac, spot1.short, spot1.name }, { "0xA4C13837E8E485BF", "0xE53A", "spot1" })
local t, configured = Zigbee.lightType(spot1)
T.eq("type 1 in Tasmota, color temperature mode: a white light", { t, configured }, { 2, 1 })
local loads = Zigbee.loads(spot1)
T.eq("one light output", { #loads, loads[1].label, loads[1].dimmer, loads[1].ct }, { 1, "White light", true, true })
local notes = table.concat(Zigbee.notes(spot1), " ")
T.check("notes suggest ZbLight", notes:find("ZbLight spot1,2", 1, true) ~= nil, notes)

local unnamed = Zigbee.build(gw, Zigbee.parseResult(UNNAMED).devices[1])
T.eq("no ColorMode: the type Tasmota has", Zigbee.lightType(unnamed), 1)
T.eq("an unnamed light is named after model and address", Zigbee.loadName(unnamed, "light"), "TS0502B 0x372D")
T.check("and asked to be named", table.concat(Zigbee.notes(unnamed), " "):find("ZbName 0x372D", 1, true) ~= nil)

T.eq("STARKVIND is not a light", #Zigbee.loads(Zigbee.build(gw, Zigbee.parseResult(STARKVIND).devices[1])), 0)
T.eq("nor is a sensor", #Zigbee.loads(Zigbee.build(gw, Zigbee.parseResult(VINDSTYRKA).devices[1])), 0)
T.eq("on/off and level clusters without a light type: a dimmer", Zigbee.lightType({ clusters = { O = 1, L = 1 } }), 1)
T.eq("on/off only: a switch", Zigbee.lightType({ clusters = { O = 1 } }), 0)
local soil = Zigbee.build(gw, {
  Device = "0x0F0C",
  Name = "Fragipani",
  IEEEAddr = "0xA4C13880227E6EE9",
  ModelId = "ZG-303Z",
  Manufacturer = "HOBEIAN",
  Endpoints = { 1 },
  Config = { "~01.1", "T01" },
  Temperature = 33.6,
  Humidity = 53,
})
T.eq("a soil sensor Tasmota calls a light (~01.1, no On/Off) is not one", #Zigbee.loads(soil), 0)
T.eq("a light type alone is not enough", Zigbee.lightType({ light = { type = 2 }, clusters = {} }), nil)

-------------------------------------------------------------------------------
T.section("MQTT Light properties")
-------------------------------------------------------------------------------
local props = Zigbee.lightProperties(spot1, "light")
T.eq("state topic: one per device (SetOption89 1)", props["Power State Topic"], "tele/zigbee/E53A/SENSOR")
T.eq("power path", props["Power Value Path"], "$.ZbReceived['0xE53A'].Power")
T.eq("commands go to ZbSend", props["Brightness Command Topic"], "cmnd/zigbee/ZbSend")
T.eq(
  "the device is named by IEEE address",
  props["Brightness Command Payload"],
  '{"Device":"0xA4C13837E8E485BF","Send":{"Dimmer":{value}}}'
)
T.eq("color temperature", { props["Color Temp Value Path"], props["Color Temp Unit"] }, {
  "$.ZbReceived['0xE53A'].CT",
  "Mireds",
})
T.eq("no color", { props["Color Command Topic"], props["Color Command Payload"] }, { "", "" })
T.eq("Zigbee values", { props["Payload On"], props["State Off"], props["Brightness Scale Max"] }, { "1", "0", "254" })
T.eq("availability is the gateway's", props["Availability Topic"], "tele/zigbee/LWT")

-- What the gateway's messages show replaces the guess.
local style = Zigbee.styleFrom(gw, "tele/zigbee/SENSOR", "spot1", spot1)
T.eq("gateway topic and names as keys (SetOption83)", { style.gatewayTopic, style.nameAsKey }, { true, true })
spot1.gateway.style = style
local topic, key = Zigbee.state(spot1)
T.eq("then devices report on the gateway topic", { topic, key }, { "tele/zigbee/SENSOR", "spot1" })
style = Zigbee.styleFrom(gw, "tele/zigbee/spot1/SENSOR", "0xE53A", spot1)
T.eq("names in topics (SetOption112)", { style.nameInTopic, style.nameAsKey }, { true, nil })

-------------------------------------------------------------------------------
T.section("The broker asks Tasmotas for Zigbee devices")
-------------------------------------------------------------------------------
local deviceMsgs = {}
C4.SendToDevice = function(_, deviceId, command, params)
  deviceMsgs[#deviceMsgs + 1] = { deviceId = deviceId, command = command, params = params or {} }
end
local LIGHT_ID = 202
C4.GetDevicesByC4iName = function(_, name)
  if name == "cp_mqtt_light.c4z" then
    return { [LIGHT_ID] = "MQTT Light" }
  end
  return {}
end
C4.FireEvent = C4.FireEvent or function() end
C4.UpdateProperty = function(_, name, value)
  Properties[name] = value
end
local realGetDriverConfigInfo = C4.GetDriverConfigInfo
C4.GetDriverConfigInfo = function(c4, section)
  if section == "minimum_os_version" then
    return "3.3.0"
  end
  return realGetDriverConfigInfo(c4, section)
end

local client = { subscribed = {}, published = {} }
function client:SetUsernameAndPassword() end
function client:OnConnect(f)
  self.onConnect = f
end
function client:OnDisconnect(f)
  self.onDisconnect = f
end
function client:OnMessage(f)
  self.onMessage = f
end
function client:OnPublish() end
function client:OnSubscribe() end
function client:OnUnsubscribe() end
function client:OnLog() end
function client:OnError() end
function client:Connect()
  return 0
end
function client:Disconnect() end
function client:Subscribe(t)
  self.subscribed[t] = true
  return 0
end
function client:Unsubscribe(t)
  self.subscribed[t] = nil
  return 0
end
function client:Publish(t, p)
  self.published[#self.published + 1] = t .. "=" .. tostring(p)
  return 0
end
setmetatable(client, {
  __index = function()
    return function()
      return 0
    end
  end,
})
C4.MQTT = function()
  return client
end

local xml = assert(io.open("drivers/cp_mqtt_broker/driver.xml")):read("*a")
for block in xml:gmatch("<property>(.-)</property>") do
  Properties[block:match("<name>(.-)</name>")] = block:match("<default>(.-)</default>") or ""
end
Properties["Log Level"] = "2 - Warning"
Properties["Automatic Updates"] = "Off"
Properties["Broker Mode"] = "External"
Properties["Broker Address"] = "10.0.0.2"

local ok, err = T.capture(function()
  dofile("drivers/cp_mqtt_broker/driver.lua")
  OnDriverInit()
  OnDriverLateInit()
  client.onConnect(client, 0, 0, "")
end)
T.check("the broker connects", ok, err)

local function message(topic, payload)
  local okMsg, errMsg = T.capture(function()
    client.onMessage(client, 1, topic, payload, 0, false)
  end)
  T.check("handles " .. topic, okMsg, errMsg)
end
local function sent(prefix)
  local out = {}
  for _, p in ipairs(client.published) do
    if p:sub(1, #prefix) == prefix then
      out[#out + 1] = p
    end
  end
  return out
end

message("tasmota/discovery/" .. GW_MAC .. "/config", discovery)
T.eq("answers are listened to", client.subscribed["stat/zigbee/RESULT"], true)
ShimFireTimers()
T.eq("a Tasmota is asked for Zigbee devices", sent("cmnd/zigbee/ZbStatus1"), { "cmnd/zigbee/ZbStatus1=" })

message("stat/zigbee/RESULT", LIST)
T.eq("the gateway's sensor topics are listened to", {
  client.subscribed["tele/zigbee/SENSOR"],
  client.subscribed["tele/zigbee/+/SENSOR"],
}, { true, true })
ShimFireTimers()
T.eq("each device is asked for in full", sent("cmnd/zigbee/ZbStatus3"), {
  "cmnd/zigbee/ZbStatus3=0x9AC9",
  "cmnd/zigbee/ZbStatus3=0xD824",
  "cmnd/zigbee/ZbStatus3=0xE53A",
  "cmnd/zigbee/ZbStatus3=0xCD3F",
  "cmnd/zigbee/ZbStatus3=0x372D",
})
for _, p in ipairs({ SPOT1, UNNAMED, STARKVIND, VINDSTYRKA }) do
  message("stat/zigbee/RESULT", p)
end
T.eq("Zigbee Devices", Properties["Zigbee Devices"], "4")

local function listFor(id)
  deviceMsgs = {}
  T.capture(function()
    ReceivedFromProxy(5001, "GET_TASMOTA_DEVICES", { device_id = tostring(id) })
  end)
  local names = {}
  for _, d in ipairs(JSON:decode(deviceMsgs[#deviceMsgs].params.devices)) do
    if d.type == "zigbee" then
      names[#names + 1] = d.name .. "=" .. d.loads[1].label
    end
  end
  table.sort(names)
  return names
end
T.eq("an MQTT Light sees the Zigbee lights", listFor(LIGHT_ID), { "0x372D=Dimmer", "spot1=White light" })
T.eq("other drivers do not", listFor(303), {})

-- spot1 reports: its topic is now known.
message(
  "tele/zigbee/E53A/SENSOR",
  '{"ZbReceived":{"0xE53A":{"Device":"0xE53A","Name":"spot1","Power":1,"Dimmer":127,"Endpoint":1}}}'
)
deviceMsgs = {}
T.capture(function()
  ReceivedFromProxy(5001, "GET_TASMOTA_DEVICE", { device_id = tostring(LIGHT_ID), mac = "0xA4C13837E8E485BF" })
end)
local dev = JSON:decode(deviceMsgs[#deviceMsgs].params.device)
T.eq("the device in full, with where it reports", { dev.name, dev.stateTopic, dev.stateKey }, {
  "spot1",
  "tele/zigbee/E53A/SENSOR",
  "0xE53A",
})

-- A device that was unpaired disappears with the next list.
message("stat/zigbee/RESULT", '{"ZbStatus1":[{"Device":"0xE53A","Name":"spot1"}]}')
T.eq("unpaired devices are dropped", Properties["Zigbee Devices"], "1")

T.capture(function()
  ExecuteCommand("LUA_ACTION", { ACTION = "ForgetZigbeeDevices" })
end)
T.eq("Forget Zigbee Devices", Properties["Zigbee Devices"], "0")

T.finish()
