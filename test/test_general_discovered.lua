-- Tests for MQTT General's Discovered Device list: picking a Tasmota or Shelly
-- creates an Event for each of its buttons, with the MQTT settings filled in,
-- and a button press then triggers the Event.
--
-- Run from the repo root:
--   make test
-- or:
--   ./test/run_test.sh test_general_discovered.lua

local T = require("testlib")
require("c4_shim")
require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")
JSON = JSON or require("JSON")
local stateParser = require("mqtt.state_parser")
local Tasmota = require("mqtt.tasmota")
local Shelly = require("mqtt.shelly")

T.section("JSONPath filters")
local event = JSON:decode(
  '{"src":"shellyplusi4-c4d8d5a1b2c3","dst":"shellyplusi4-c4d8d5a1b2c3/events","method":"NotifyEvent",'
    .. '"params":{"ts":1.7,"events":[{"component":"input:1","id":1,"event":"single_push","ts":1.7}]}}'
)
T.eq(
  "the event of one input",
  stateParser.extractJsonPath(event, "$.params.events[?(@.component=='input:1')].event"),
  "single_push"
)
T.eq(
  "another input: nothing",
  stateParser.extractJsonPath(event, "$.params.events[?(@.component=='input:0')].event"),
  nil
)
T.eq("double quotes", stateParser.extractJsonPath(event, '$.params.events[?(@.component=="input:1")].id'), 1)
T.eq("a number", stateParser.extractJsonPath(event, "$.params.events[?(@.id==1)].event"), "single_push")
T.eq(
  "on a message without events",
  stateParser.extractJsonPath({ params = {} }, "$.params.events[?(@.id==1)].event"),
  nil
)
local t = { state = { power = "ON" }, sensors = { { temp = 72 } }, ["a b"] = 1 }
T.eq("dot paths as before", stateParser.extractJsonPath(t, "$.state.power"), "ON")
T.eq("indexes as before", stateParser.extractJsonPath(t, "$.sensors[0].temp"), 72)
T.eq("quoted keys", stateParser.extractJsonPath(t, "$['a b']"), 1)
T.eq("root", stateParser.extractJsonPath(t, "$"), t)
T.eq("missing", stateParser.extractJsonPath(t, "$.missing.deeper"), nil)
T.eq("not a path", stateParser.extractJsonPath(t, "state.power"), nil)
T.eq("a broken filter", stateParser.extractJsonPath(event, "$.params.events[?(@.id"), nil)

-------------------------------------------------------------------------------
-- Devices as the broker keeps them
-------------------------------------------------------------------------------
local function tasmota(so73, so114)
  return Tasmota.parse(
    string.format(
      '{"ip":"10.0.0.7","dn":"Hall","fn":["Hall",null,null,null,null,null,null,null],"hn":"h","mac":"84F3EBA1B2C4",'
        .. '"md":"Sonoff","ofln":"Offline","onln":"Online","state":["OFF","ON","TOGGLE","HOLD"],"sw":"14.3.0",'
        .. '"t":"hall","ft":"%%prefix%%/%%topic%%/","tp":["cmnd","stat","tele"],"rl":[1,1,0,0,0,0,0,0],'
        .. '"swc":[-1,4,-1,-1,-1,-1,-1,-1],"swn":[null,"Door",null,null,null,null,null,null],'
        .. '"btn":[1,1,0,0,0,0,0,0],'
        .. '"so":{"4":0,"11":0,"13":0,"17":0,"20":0,"30":0,"68":0,"73":%d,"82":0,"114":%d,"117":0},'
        .. '"lk":1,"lt_st":0,"ver":1}',
      so73,
      so114
    )
  )
end
local I4 = "shellyplusi4-c4d8d5a1b2c3"
local i4 = Shelly.build(
  { id = I4, mac = "C4D8D5A1B2C3", model = "SNSN-0024X", gen = 2, ver = "1.4.4", app = "PlusI4" },
  I4,
  {
    sys = { device = { name = "Hall Panel" } },
    ["input:0"] = { id = 0, type = "button", name = "Scene" },
    ["input:1"] = { id = 1, type = "button", name = JSON.null },
    ["input:2"] = { id = 2, type = "switch", name = JSON.null },
  }
)

T.section("Buttons on a Tasmota")
local hall = tasmota(1, 1)
local tb = Tasmota.buttons(hall)
T.eq("two buttons and the named switch", { tb[1].id, tb[2].id, tb[3].id, tb[3].label }, {
  "button1",
  "button2",
  "switch2",
  "Door",
})
T.eq("from RESULT", { tb[1].stateTopic, tb[1].valuePath }, { "stat/hall/RESULT", "$.Button1.Action" })
T.eq("press actions only", tb[1].eventTypeFilter, "SINGLE,DOUBLE,TRIPLE,QUAD,PENTA,HOLD")
T.eq("in the summary", Tasmota.summary(hall).buttons, 3)
local coupled = tasmota(0, 0)
T.eq("buttons controlling relays are not events", #Tasmota.buttons(coupled), 0)
T.contains("with a note to run SetOption73 1", table.concat(Tasmota.buttonNotes(coupled), " "), "SetOption73 1")
T.contains("and SetOption114 1", table.concat(Tasmota.buttonNotes(coupled), " "), "SetOption114 1")

T.section("Buttons on a Shelly")
local sb = Shelly.buttons(i4)
T.eq("button inputs only", { #sb, sb[1].label, sb[2].label }, { 2, "Scene", "Input 2" })
T.eq("from NotifyEvent", { sb[2].stateTopic, sb[2].valuePath }, {
  I4 .. "/events/rpc",
  "$.params.events[?(@.component=='input:1')].event",
})
T.eq("press events, not btn_down/btn_up", sb[1].eventTypeFilter, "single_push,double_push,triple_push,long_push")
T.contains("a note for the switch input", table.concat(Shelly.buttonNotes(i4), " "), "set them to Button")
T.contains(
  "a device read before inputs were kept",
  table.concat(Shelly.buttonNotes({ name = "Old" }), " "),
  "Find Shelly"
)
T.eq("in the summary", Shelly.summary(i4).buttons, 2)

-------------------------------------------------------------------------------
-- The MQTT General driver
-------------------------------------------------------------------------------
local sent, fired, lists, printed = {}, {}, {}, {}
C4.SendToProxy = function(_, binding, command, params)
  sent[#sent + 1] = { binding = binding, command = command, params = params or {} }
end
C4.FireEventByID = function(_, id)
  fired[#fired + 1] = id
end
C4.UpdatePropertyList = function(_, name, items, current)
  lists[name] = { items = items, current = current }
end
local realGetDriverConfigInfo = C4.GetDriverConfigInfo
C4.GetDriverConfigInfo = function(c4, section)
  if section == "minimum_os_version" then
    return "3.3.0"
  end
  return realGetDriverConfigInfo(c4, section)
end
local xml = assert(io.open("drivers/cp_mqtt_general/driver.xml")):read("*a")
for block in xml:gmatch("<property>(.-)</property>") do
  Properties[block:match("<name>(.-)</name>")] = block:match("<default>(.-)</default>") or ""
end
Properties["Log Level"] = "2 - Warning"

local function messages(command, binding)
  local out = {}
  for _, m in ipairs(sent) do
    if m.command == command and (binding == nil or m.binding == binding) then
      out[#out + 1] = m.params
    end
  end
  return out
end
local function capture(fn)
  local ok, err, out = T.capture(fn)
  printed[#printed + 1] = out
  return ok, err, out
end

T.section("MQTT General: the Discovered Device list")
local ok, err = capture(function()
  dofile("drivers/cp_mqtt_general/driver.lua")
  OnDriverInit()
  OnDriverLateInit()
end)
T.check("the driver starts", ok, err)
T.eq("the list starts with (Select)", lists["Discovered Device"] and lists["Discovered Device"].current, "(Select)")
sent = {}
capture(function()
  ReceivedFromProxy(5001, "BROKER_CONNECTED", {})
end)
T.eq("broker connected: the list is asked for", #messages("GET_TASMOTA_DEVICES"), 1)
capture(function()
  ExecuteCommand("TASMOTA_DEVICES", {
    devices = JSON:encode({ Tasmota.summary(hall), Shelly.summary(i4) }),
  })
end)
T.contains("a Tasmota with its buttons", lists["Discovered Device"].items, "Hall [hall] 3 buttons")
T.contains("a Shelly with its buttons", lists["Discovered Device"].items, "Hall Panel [" .. I4 .. "] 2 buttons")

T.section("Picking a Shelly creates its Events")
sent = {}
Properties["Discovered Device"] = "Hall Panel [" .. I4 .. "] 2 buttons"
capture(function()
  OnPropertyChanged("Discovered Device")
end)
T.eq("the device is asked for", messages("GET_TASMOTA_DEVICE")[1].mac, "C4D8D5A1B2C3")
local _, createErr, out = capture(function()
  ExecuteCommand("TASMOTA_DEVICE", { mac = "C4D8D5A1B2C3", device = JSON:encode(i4) })
end)
T.check("runs without error", createErr == nil, createErr)
T.contains("says what it created", out, "Created event 'Hall Panel Scene'")
T.contains("and the second", out, "Created event 'Hall Panel Input 2'")
T.contains("and why the switch input is left out", out, "set them to Button")
local subscribed = {}
for _, m in ipairs(messages("SUBSCRIBE")) do
  subscribed[m.topic] = true
end
T.check("the Events subscribe to NotifyEvent", subscribed[I4 .. "/events/rpc"])

local function deliver(topic, payload)
  sent, fired = {}, {}
  capture(function()
    ExecuteCommand("MQTT_MESSAGE", { topic = topic, payload = payload })
  end)
end
deliver(
  I4 .. "/events/rpc",
  '{"method":"NotifyEvent","params":{"ts":2,"events":[{"component":"input:0","id":0,"event":"btn_down","ts":2}]}}'
)
T.eq("btn_down does not trigger", #fired, 0)
deliver(
  I4 .. "/events/rpc",
  '{"method":"NotifyEvent","params":{"ts":3,"events":[{"component":"input:0","id":0,"event":"single_push","ts":3}]}}'
)
T.eq("a single push triggers one Event", #fired, 1)
T.eq("and presses its button link", #messages("DO_PUSH"), 1)
deliver(I4 .. "/events/rpc", '{"method":"NotifyStatus","params":{"ts":4,"input:0":{"id":0,"state":null}}}')
T.eq("status messages on the same topic do not", #fired, 0)

T.section("Picking it again updates instead of duplicating")
Properties["Discovered Device"] = "Hall Panel [" .. I4 .. "] 2 buttons"
capture(function()
  OnPropertyChanged("Discovered Device")
end)
local _, _, again = capture(function()
  ExecuteCommand("TASMOTA_DEVICE", { mac = "C4D8D5A1B2C3", device = JSON:encode(i4) })
end)
T.contains("updated", again, "Updated event 'Hall Panel Scene'")
T.excludes("not created twice", again, "Created event")

T.section("Tasmota")
Properties["Discovered Device"] = "Hall [hall] 3 buttons"
capture(function()
  OnPropertyChanged("Discovered Device")
end)
local _, _, tout = capture(function()
  ExecuteCommand("TASMOTA_DEVICE", { mac = "84F3EBA1B2C4", device = JSON:encode(hall) })
end)
T.contains("Tasmota buttons become Events", tout, "Created event 'Hall Button 1'")
T.contains("and the switch", tout, "Created event 'Hall Door'")
deliver("stat/hall/RESULT", '{"Button1":{"Action":"SINGLE"}}')
T.eq("a press triggers it", #fired, 1)
deliver("stat/hall/RESULT", '{"POWER1":"ON"}')
T.eq("other RESULT messages do not", #fired, 0)

capture(function()
  ExecuteCommand("TASMOTA_DEVICES", { devices = JSON:encode({ Tasmota.summary(coupled) }) })
end)
Properties["Discovered Device"] = "Hall [hall] 0 buttons"
capture(function()
  OnPropertyChanged("Discovered Device")
end)
local _, _, none = capture(function()
  ExecuteCommand("TASMOTA_DEVICE", { mac = "84F3EBA1B2C4", device = JSON:encode(coupled) })
end)
T.contains("no buttons: says why", none, "No buttons found on Hall")
T.contains("and what to change", none, "SetOption73 1")
local _, _, stray = capture(function()
  ExecuteCommand("TASMOTA_DEVICE", { mac = "84F3EBA1B2C4", device = JSON:encode(hall) })
end)
T.excludes("a device nobody picked is ignored", stray, "event")

sent = {}
capture(function()
  ReceivedFromProxy(5001, "TASMOTA_DEVICES_CHANGED", { mac = "x" })
end)
T.eq("a device change refreshes the list", #messages("GET_TASMOTA_DEVICES"), 1)

T.finish()
