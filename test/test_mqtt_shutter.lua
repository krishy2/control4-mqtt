-- Tests for the MQTT Shutter: the model (src/mqtt/shutter.lua) with Tasmota,
-- Shelly and Zigbee2MQTT style devices, shutter discovery, and the driver
-- (blind proxy, Discovered Device list, button links).
--
-- Run from the repo root:
--   make test
-- or:
--   ./test/run_test.sh test_mqtt_shutter.lua

local T = require("testlib")
require("c4_shim")
require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")
JSON = JSON or require("JSON")
local Shutter = require("mqtt.shutter")
local Tasmota = require("mqtt.tasmota")
local Shelly = require("mqtt.shelly")

local sent = {}
C4.SendToProxy = function(_, binding, command, params)
  sent[#sent + 1] = { binding = binding, command = command, params = params or {} }
end
local function take(command, binding)
  local out = {}
  for _, m in ipairs(sent) do
    if m.command == command and (binding == nil or m.binding == binding) then
      out[#out + 1] = m.params
    end
  end
  return out
end
local function last(list)
  return list[#list]
end
local function published()
  local out = {}
  for _, p in ipairs(take("PUBLISH", 5002)) do
    out[#out + 1] = p.topic .. "=" .. p.payload
  end
  return out
end
local clock = 1000000
local function newShutter(cfg)
  local s = Shutter.new({
    proxyBinding = 5001,
    brokerBinding = 5002,
    now = function()
      return clock
    end,
  })
  s:configure(cfg)
  sent = {}
  return s
end

-- A Tasmota shutter as discovery describes it
local function tasmotaShutter(tilt)
  return Tasmota.parse(
    '{"ip":"10.0.0.20","dn":"Living Shutter","fn":["Living Shutter",null,null,null,null,null,null,null],'
      .. '"hn":"h","mac":"A4CF12B3C4D5","md":"Shelly 2.5","ofln":"Offline","onln":"Online",'
      .. '"state":["OFF","ON","TOGGLE","HOLD"],"sw":"15.3.0","t":"living_shutter","ft":"%prefix%/%topic%/",'
      .. '"tp":["cmnd","stat","tele"],"rl":[3,3,0,0,0,0,0,0],"swc":[-1,-1,-1,-1,-1,-1,-1,-1],'
      .. '"swn":[null,null,null,null,null,null,null,null],"btn":[0,0,0,0,0,0,0,0],'
      .. '"so":{"4":0,"11":0,"13":0,"17":0,"20":0,"30":0,"68":0,"73":0,"82":0,"114":0,"117":0},'
      .. '"lk":0,"lt_st":0,"bat":0,"dslp":0,'
      .. (tilt and '"sho":[0,0,0,0],"sht":[[-90,90,20],[0,0,0],[0,0,0],[0,0,0]],' or '"sho":[0,0,0,0],"sht":[[0,0,0],[0,0,0],[0,0,0],[0,0,0]],')
      .. '"ver":1}'
  )
end

T.section("Tasmota shutter discovery")
local dev = tasmotaShutter(true)
local shutters = Tasmota.shutters(dev)
T.eq("one shutter on two relays", { #shutters, shutters[1].id, shutters[1].label }, { 1, "shutter1", "Shutter" })
T.eq("tilt from sht", { shutters[1].tilt, shutters[1].tiltMin, shutters[1].tiltMax }, { true, -90, 90 })
T.eq("no tilt when sht is all zero", Tasmota.shutters(tasmotaShutter(false))[1].tilt, false)
T.eq("in the summary", Tasmota.summary(dev).shutters[1].id, "shutter1")
T.eq("not a light or relay for the light driver", #Tasmota.loads(dev), 0)
local props = Tasmota.shutterProperties(dev, "shutter1")
T.eq("settings", {
  props["Position State Topic"],
  props["Position Value Path"],
  props["Position Command Topic"],
  props["Movement Value Path"],
  props["Open Command Topic"],
  props["Stop Command Topic"],
  props["Tilt Command Topic"],
  props["Availability Topic"],
}, {
  "stat/living_shutter/RESULT",
  "$.Shutter1.Position",
  "cmnd/living_shutter/ShutterPosition1",
  "$.Shutter1.Direction",
  "cmnd/living_shutter/ShutterOpen1",
  "cmnd/living_shutter/ShutterStop1",
  "cmnd/living_shutter/ShutterTilt1",
  "tele/living_shutter/LWT",
})
T.eq("name", Tasmota.shutterName(dev, "shutter1"), "Living Shutter")
T.eq("unknown shutter", Tasmota.shutterProperties(dev, "shutter2"), nil)

T.section("Shelly cover discovery")
local SP = "shellyplus2pm-a8032ab12345"
local shelly = Shelly.build(
  { id = SP, mac = "A8032AB12345", model = "SNSW-102P16EU", gen = 2, ver = "1.4.4", app = "Plus2PM", profile = "cover" },
  SP,
  {
    sys = { device = { name = "Bedroom" } },
    ["cover:0"] = { id = 0, name = "Bedroom Blind", slat = { enable = true } },
    ["input:0"] = { id = 0, type = "switch" },
  }
)
local covers = Shelly.shutters(shelly)
T.eq("the cover, with slats", { #covers, covers[1].id, covers[1].label, covers[1].tilt }, {
  1,
  "cover:0",
  "Bedroom Blind",
  true,
})
local sprops = Shelly.shutterProperties(shelly, "cover:0")
T.eq("settings", { sprops["Payload Mode"], sprops["Shelly Topic Prefix"], sprops["Shelly Component"] }, {
  "Shelly (Gen2+)",
  SP,
  "cover:0",
})
T.contains("state request is Cover.GetStatus", sprops["State Request Payload"], "Cover.GetStatus")
T.eq("name from the cover", Shelly.shutterName(shelly, "cover:0"), "Bedroom Blind")
T.eq("in the summary", Shelly.summary(shelly).shutters[1].id, "cover:0")

-------------------------------------------------------------------------------
-- The model
-------------------------------------------------------------------------------
local function tasmotaCfg(extra)
  local cfg = {
    mode = "Separate Topics",
    control = "Position",
    travelTime = 20,
    topics = {
      position = {
        stateTopic = "stat/ls/RESULT",
        valuePath = "$.Shutter1.Position",
        commandTopic = "cmnd/ls/ShutterPosition1",
      },
      target = { stateTopic = "stat/ls/RESULT", valuePath = "$.Shutter1.Target" },
      state = { stateTopic = "stat/ls/RESULT", valuePath = "$.Shutter1.Direction" },
      open = { commandTopic = "cmnd/ls/ShutterOpen1", payload = "" },
      close = { commandTopic = "cmnd/ls/ShutterClose1", payload = "" },
      stop = { commandTopic = "cmnd/ls/ShutterStop1", payload = "" },
      tilt = { stateTopic = "stat/ls/RESULT", valuePath = "$.Shutter1.Tilt", commandTopic = "cmnd/ls/ShutterTilt1" },
    },
    tiltMin = -90,
    tiltMax = 90,
  }
  for k, v in pairs(extra or {}) do
    cfg[k] = v
  end
  return cfg
end

T.section("Tasmota-style shutter")
local s = newShutter(tasmotaCfg())
T.eq("position and stop", { s.caps.hasLevel, s.caps.canStop }, { true, true })
s:refreshProxy()
local hl = last(take("SET_HAS_LEVEL"))
T.eq("proxy levels 0-100", { hl.LEVEL_OPEN, hl.LEVEL_CLOSED, hl.LEVEL_DISCRETE_CONTROL }, { 100, 0, true })
T.eq("can stop", last(take("SET_CAN_STOP")).CAN_STOP, true)
sent = {}
s:onMessage("stat/ls/RESULT", '{"Shutter1":{"Position":0,"Direction":0,"Target":0,"Tilt":0}}')
T.eq("closed: STOPPED 0", last(take("STOPPED")).LEVEL, 0)
sent = {}
s:handleProxyCommand("SET_LEVEL_TARGET", { LEVEL_TARGET = "40" })
T.eq("a level goes to ShutterPosition1", published(), { "cmnd/ls/ShutterPosition1=40" })
local mv = last(take("MOVING"))
T.eq("Control4 hears MOVING with the time", { mv.LEVEL_TARGET, mv.RAMP_RATE }, { 40, 8000 })
sent = {}
s:onMessage("stat/ls/RESULT", '{"Shutter1":{"Position":10,"Direction":1,"Target":40,"Tilt":0}}')
T.eq("the device moving: no second MOVING", #take("MOVING"), 0)
s:onMessage("stat/ls/RESULT", '{"Shutter1":{"Position":40,"Direction":0,"Target":40,"Tilt":0}}')
T.eq("stopped at 40", last(take("STOPPED")).LEVEL, 40)
T.eq("state text", s:stateText(), "40%")
sent = {}
s:handleProxyCommand("SET_LEVEL_TARGET", { LEVEL_TARGET = "100" })
T.eq("fully open uses ShutterOpen1 (end stop)", published(), { "cmnd/ls/ShutterOpen1=" })
sent = {}
s:handleProxyCommand("STOP", {})
T.eq("stop", published(), { "cmnd/ls/ShutterStop1=" })
sent = {}
s:onMessage("stat/ls/RESULT", '{"Shutter1":{"Position":70,"Direction":0,"Target":100,"Tilt":0}}')
T.eq("where it stopped", last(take("STOPPED")).LEVEL, 70)
sent = {}
s:onMessage("stat/ls/RESULT", '{"Shutter1":{"Position":70,"Direction":-1,"Target":0,"Tilt":0}}')
T.eq("moved from the wall switch: MOVING to its target", last(take("MOVING")).LEVEL_TARGET, 0)
s:onMessage("stat/ls/RESULT", '{"POWER1":"ON"}')
T.eq("other RESULT messages change nothing", #take("STOPPED"), 0)
T.eq("isOpen", s:isOpen(), true)

local inv = newShutter(tasmotaCfg({ invert = true }))
inv:onMessage("stat/ls/RESULT", '{"Shutter1":{"Position":100,"Direction":0,"Target":100,"Tilt":0}}')
T.eq("inverted: device 100 is closed", last(take("STOPPED")).LEVEL, 0)
sent = {}
inv:setLevel(30)
T.eq("and 30 is sent as 70", published(), { "cmnd/ls/ShutterPosition1=70" })

T.section("Tasmota tilt (second driver)")
local tilt = newShutter(tasmotaCfg({ control = "Tilt", tiltTime = 2 }))
T.eq("slat position", tilt.caps.hasLevel, true)
tilt:onMessage("stat/ls/RESULT", '{"Shutter1":{"Position":40,"Direction":0,"Target":40,"Tilt":0}}')
T.eq("tilt 0 of -90..90 is 50%", last(take("STOPPED")).LEVEL, 50)
sent = {}
tilt:setLevel(75)
T.eq("75% is 45 degrees", published(), { "cmnd/ls/ShutterTilt1=45" })
sent = {}
tilt:handleProxyCommand("SET_LEVEL_TARGET", { LEVEL_TARGET = "0" })
T.eq("closing the slats", published(), { "cmnd/ls/ShutterTilt1=-90" })

T.section("Open/close only (no position topic)")
local oc = newShutter({
  mode = "Separate Topics",
  control = "Position",
  topics = {
    state = { stateTopic = "home/blind/state" },
    open = { commandTopic = "home/blind/set", payload = "OPEN" },
    close = { commandTopic = "home/blind/set", payload = "CLOSE" },
    stop = { commandTopic = "home/blind/set", payload = "STOP" },
  },
})
oc:refreshProxy()
local ochl = last(take("SET_HAS_LEVEL"))
T.eq("discrete levels like the stock driver", { ochl.LEVEL_OPEN, ochl.LEVEL_CLOSED, ochl.LEVEL_DISCRETE_CONTROL }, {
  2,
  0,
  false,
})
sent = {}
oc:handleProxyCommand("SET_LEVEL_TARGET", { LEVEL_TARGET = "2" })
T.eq("2 opens", published(), { "home/blind/set=OPEN" })
oc:onMessage("home/blind/state", "opening")
oc:onMessage("home/blind/state", "open")
T.eq("open: STOPPED 2", last(take("STOPPED")).LEVEL, 2)
sent = {}
oc:handleProxyCommand("SET_LEVEL_TARGET", { LEVEL_TARGET = "0" })
T.eq("0 closes", published(), { "home/blind/set=CLOSE" })

T.section("No state feedback: optimistic")
local opt = newShutter({
  mode = "Separate Topics",
  control = "Position",
  travelTime = 10,
  topics = { position = { commandTopic = "cmnd/x/pos" } },
})
T.eq("optimistic", opt:isOptimistic(), true)
opt.level = 0
opt:setLevel(50)
T.eq("MOVING for half the travel time", last(take("MOVING")).RAMP_RATE, 5000)
ShimFireTimers()
T.eq("STOPPED at the target when the time is up", last(take("STOPPED")).LEVEL, 50)

T.section("Zigbee2MQTT-style JSON")
local z = newShutter({
  mode = "JSON",
  control = "Position",
  json = {
    stateTopic = "zigbee2mqtt/Blind",
    commandTopic = "zigbee2mqtt/Blind/set",
    keys = { position = "position", state = "state", moving = "moving" },
  },
  payloadOpen = "OPEN",
  payloadClose = "CLOSE",
  payloadStop = "STOP",
})
T.eq("position and stop", { z.caps.hasLevel, z.caps.canStop }, { true, true })
z:onMessage("zigbee2mqtt/Blind", '{"position":30,"state":"OPEN","moving":"STOP"}')
T.eq("STOPPED 30", last(take("STOPPED")).LEVEL, 30)
sent = {}
z:setLevel(60)
T.eq("position command", published(), { 'zigbee2mqtt/Blind/set={"position":60}' })
sent = {}
z:setLevel(0)
T.eq("close command", published(), { 'zigbee2mqtt/Blind/set={"state":"CLOSE"}' })
sent = {}
z:stop()
T.eq("stop command", published(), { 'zigbee2mqtt/Blind/set={"state":"STOP"}' })

T.section("Shelly cover")
local sc =
  newShutter({ mode = "Shelly (Gen2+)", control = "Position", shelly = { prefix = SP, component = "cover:0" } })
T.eq("subscriptions", sc:subscriptions(), {
  "control4/" .. SP .. "/cover_0/rpc",
  SP .. "/events/rpc",
  SP .. "/status/cover:0",
})
sc:onMessage(SP .. "/status/cover:0", '{"id":0,"state":"stopped","current_pos":20,"pos_control":true,"slat_pos":50}')
T.eq("STOPPED at current_pos", last(take("STOPPED")).LEVEL, 20)
sent = {}
sc:setLevel(55)
local rpc = JSON:decode(take("PUBLISH")[1].payload)
T.eq("Cover.GoToPosition", { rpc.method, rpc.params.id, rpc.params.pos }, { "Cover.GoToPosition", 0, 55 })
sent = {}
sc:onMessage(
  SP .. "/events/rpc",
  '{"method":"NotifyStatus","params":{"cover:0":{"id":0,"state":"opening","target_pos":55}}}'
)
sc:onMessage(
  SP .. "/events/rpc",
  '{"method":"NotifyStatus","params":{"cover:0":{"id":0,"state":"stopped","current_pos":55,"target_pos":null}}}'
)
T.eq("arrives", last(take("STOPPED")).LEVEL, 55)
sent = {}
sc:open()
T.eq("Cover.Open", JSON:decode(take("PUBLISH")[1].payload).method, "Cover.Open")
sent = {}
sc:onMessage(SP .. "/status/cover:0", '{"id":0,"state":"stopped","pos_control":false}')
local nohl = last(take("SET_HAS_LEVEL"))
T.eq("not calibrated: open/close only", nohl and nohl.LEVEL_OPEN, 2)
sc:onMessage(SP .. "/status/cover:0", '{"id":0,"state":"open","pos_control":false}')
T.eq("open end position", last(take("STOPPED")).LEVEL, 2)

local slats = newShutter({ mode = "Shelly (Gen2+)", control = "Tilt", shelly = { prefix = SP, component = "cover:0" } })
slats:onMessage(SP .. "/status/cover:0", '{"id":0,"state":"stopped","current_pos":20,"pos_control":true,"slat_pos":30}')
T.eq("slats level", last(take("STOPPED")).LEVEL, 30)
sent = {}
slats:setLevel(80)
T.eq("slat_pos", JSON:decode(take("PUBLISH")[1].payload).params.slat_pos, 80)

-------------------------------------------------------------------------------
-- The driver
-------------------------------------------------------------------------------
local realGetDriverConfigInfo = C4.GetDriverConfigInfo
C4.GetDriverConfigInfo = function(c4, section)
  if section == "minimum_os_version" then
    return "3.3.0"
  end
  return realGetDriverConfigInfo(c4, section)
end
local lists = {}
C4.UpdatePropertyList = function(_, name, items, current)
  lists[name] = { items = items, current = current }
end
local xml = assert(io.open("drivers/cp_mqtt_shutter/driver.xml")):read("*a")
for block in xml:gmatch("<property>(.-)</property>") do
  Properties[block:match("<name>(.-)</name>")] = block:match("<default>(.-)</default>") or ""
end
Properties["Log Level"] = "2 - Warning"
ShimSetDevices({
  [900] = { deviceName = "MQTT Broker", driverFileName = "cp_mqtt_broker.c4z" },
  [12345] = { deviceName = "MQTT Shutter", driverFileName = "cp_mqtt_shutter.c4z" },
  [12346] = { deviceName = "MQTT Shutter", driverFileName = "blind.c4i" },
})
ShimSetProxyDevices(12346)

T.section("Driver: start-up")
T.contains("blind proxy", xml, '<proxy proxybindingid="5001" name="MQTT Shutter">blind</proxy>')
for id, name in pairs({ [300] = "Open", [301] = "Close", [302] = "Toggle" }) do
  T.contains(name .. " Button Link declared", xml, "<id>" .. id .. "</id>")
end
local ok, err = T.capture(function()
  dofile("drivers/cp_mqtt_shutter/driver.lua")
  OnDriverInit()
  OnDriverLateInit()
end)
T.check("the driver starts", ok, err)
T.eq("it connects itself to the broker", C4:GetBoundProviderDevice(12345, 5002), 900)
T.check("capabilities sent at start-up", #take("SET_HAS_LEVEL", 5001) > 0)

T.section("Driver: pick a Tasmota shutter")
local clockNow = os.time() * 1000 + 10000000
C4.GetTime = function()
  return clockNow
end
sent = {}
T.capture(function()
  ReceivedFromProxy(5002, "BROKER_CONNECTED", {})
end)
T.eq("asks for the device list", #take("GET_TASMOTA_DEVICES"), 1)
T.capture(function()
  ExecuteCommand("TASMOTA_DEVICES", { devices = JSON:encode({ Tasmota.summary(dev), Shelly.summary(shelly) }) })
end)
T.contains(
  "lists the Tasmota shutter",
  lists["Discovered Device"].items,
  "Living Shutter [living_shutter] Shutter (tilt)"
)
T.contains("and the Shelly cover", lists["Discovered Device"].items, "Bedroom [" .. SP .. "] Bedroom Blind (tilt)")
Properties["Discovered Device"] = "Living Shutter [living_shutter] Shutter (tilt)"
T.capture(function()
  OnPropertyChanged("Discovered Device")
end)
clockNow = clockNow + 10000
sent = {}
local applied, applyErr = T.capture(function()
  ExecuteCommand("TASMOTA_DEVICE", { mac = "A4CF12B3C4D5", device = JSON:encode(dev) })
end)
T.check("applies without error", applied, applyErr)
T.eq("settings filled in", { Properties["Position Command Topic"], Properties["Tilt Min"] }, {
  "cmnd/living_shutter/ShutterPosition1",
  "-90",
})
T.eq("renamed after the device", last(ShimRenames()).name, "Living Shutter")
local subs = {}
for _, m in ipairs(take("SUBSCRIBE")) do
  subs[m.topic] = true
end
T.check("subscribes to RESULT", subs["stat/living_shutter/RESULT"])
T.eq("asks for its state", #take("PUBLISH"), 1)

sent = {}
T.capture(function()
  ReceivedFromProxy(5001, "SET_LEVEL_TARGET", { LEVEL_TARGET = "25" })
end)
T.eq("Control4 moves it", published(), { "cmnd/living_shutter/ShutterPosition1=25" })
sent = {}
T.capture(function()
  ExecuteCommand("MQTT_MESSAGE", {
    topic = "stat/living_shutter/RESULT",
    payload = '{"Shutter1":{"Position":25,"Direction":0,"Target":25,"Tilt":0}}',
  })
end)
T.eq("and hears where it stopped", last(take("STOPPED", 5001)).LEVEL, 25)

T.section("Driver: button links")
C4:Bind(12345, 300, 700, 1, "BUTTON_LINK")
C4:Bind(12345, 301, 701, 1, "BUTTON_LINK")
sent = {}
T.capture(function()
  ReceivedFromProxy(301, "DO_PUSH", {})
  ReceivedFromProxy(301, "DO_CLICK", {})
end)
T.eq("Close tap closes", published(), { "cmnd/living_shutter/ShutterClose1=" })
sent = {}
T.capture(function()
  ReceivedFromProxy(300, "DO_PUSH", {})
  ReceivedFromProxy(300, "DO_CLICK", {})
end)
T.eq("a tap while moving stops", published(), { "cmnd/living_shutter/ShutterStop1=" })
sent = {}
T.capture(function()
  ExecuteCommand("MQTT_MESSAGE", {
    topic = "stat/living_shutter/RESULT",
    payload = '{"Shutter1":{"Position":0,"Direction":0,"Target":0,"Tilt":0}}',
  })
end)
T.eq("closed: LEDs show closed", last(take("MATCH_LED_STATE", 300)).STATE, "false")
sent = {}
T.capture(function()
  ReceivedFromProxy(300, "DO_PUSH", {})
  ShimFireTimers()
end)
T.eq("holding Open opens", published(), { "cmnd/living_shutter/ShutterOpen1=" })
sent = {}
T.capture(function()
  ReceivedFromProxy(300, "DO_RELEASE", {})
end)
T.eq("releasing stops", published(), { "cmnd/living_shutter/ShutterStop1=" })
sent = {}
T.capture(function()
  ReceivedFromProxy(300, "REQUEST_BUTTON_COLORS", {})
end)
local colors = last(take("BUTTON_COLORS", 300))
T.eq("Open link colors from the color pickers", { colors.ON_COLOR, colors.OFF_COLOR }, { "0000ff", "000000" })
Properties["Open Button LED When Open"] = "0,255,0"
sent = {}
T.capture(function()
  OnPropertyChanged("Open Button LED When Open")
end)
T.eq("a new color goes out at once", last(take("BUTTON_COLORS", 300)).ON_COLOR, "00ff00")

T.finish()
