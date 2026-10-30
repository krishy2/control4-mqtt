-- Tests for the MQTT Fan: the model (src/mqtt/fan.lua) with Tasmota iFan,
-- Zigbee2MQTT and power + speed + direction topic devices, iFan discovery, and
-- the driver (fan proxy, Discovered Device list, button links).
--
-- Run from the repo root:
--   make test
-- or:
--   ./test/run_test.sh test_mqtt_fan.lua

local T = require("testlib")
require("c4_shim")
require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")
JSON = JSON or require("JSON")
local Fan = require("mqtt.fan")
local Tasmota = require("mqtt.tasmota")

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
local function speeds()
  local out = {}
  for _, p in ipairs(take("CURRENT_SPEED", 5001)) do
    out[#out + 1] = p.SPEED
  end
  return out
end
local function newFan(cfg)
  local f = Fan.new({ proxyBinding = 5001, brokerBinding = 5002 })
  f:configure(cfg)
  sent = {}
  return f
end

-- A Sonoff iFan03 as Tasmota discovery describes it
local function ifan()
  return Tasmota.parse(
    '{"ip":"10.0.0.30","dn":"Bedroom","fn":["Bedroom Light",null,null,null,null,null,null,null],'
      .. '"hn":"h","mac":"A4CF12B3C4D6","md":"Sonoff iFan03","ofln":"Offline","onln":"Online",'
      .. '"state":["OFF","ON","TOGGLE","HOLD"],"sw":"15.3.0","t":"bedroom_fan","ft":"%prefix%/%topic%/",'
      .. '"tp":["cmnd","stat","tele"],"rl":[1,0,0,0,0,0,0,0],"swc":[-1,-1,-1,-1,-1,-1,-1,-1],'
      .. '"swn":[null,null,null,null,null,null,null,null],"btn":[0,0,0,0,0,0,0,0],'
      .. '"so":{"4":0,"11":0,"13":0,"17":0,"20":0,"30":0,"68":0,"73":0,"82":0,"114":0,"117":0},'
      .. '"lk":0,"lt_st":0,"bat":0,"dslp":0,"sho":[0,0,0,0],"sht":[[0,0,0],[0,0,0],[0,0,0],[0,0,0]],'
      .. '"if":1,"ver":1}'
  )
end

T.section("Tasmota iFan discovery")
local dev = ifan()
T.eq("the fan", Tasmota.fans(dev), { { id = "fan", label = "Fan" } })
T.eq("in the summary", Tasmota.summary(dev).fans[1].id, "fan")
local plain = Tasmota.parse('{"t":"plug","mac":"AA","rl":[1]}')
T.eq("no fan without if", #Tasmota.fans(plain), 0)
local props = Tasmota.fanProperties(dev, "fan")
T.eq("settings", {
  props["Speed State Topic"],
  props["Speed Value Path"],
  props["Speed Command Topic"],
  props["Speed Values"],
  props["Speed Off Value"],
  props["State Request Topic"],
  props["Availability Topic"],
}, {
  "stat/bedroom_fan/RESULT",
  "$.FanSpeed",
  "cmnd/bedroom_fan/FanSpeed",
  "1,2,3",
  "0",
  "cmnd/bedroom_fan/STATE",
  "tele/bedroom_fan/LWT",
})
T.eq("name", Tasmota.fanName(dev, "fan"), "Bedroom Fan")
T.eq("no fan on a plug", Tasmota.fanProperties(plain, "fan"), nil)

-------------------------------------------------------------------------------
-- The model
-------------------------------------------------------------------------------
local function ifanCfg(extra)
  local cfg = {
    mode = "Separate Topics",
    speedValues = "1,2,3",
    speedOff = "0",
    topics = {
      speed = { stateTopic = "stat/f/RESULT", valuePath = "$.FanSpeed", commandTopic = "cmnd/f/FanSpeed" },
    },
  }
  for k, v in pairs(extra or {}) do
    cfg[k] = v
  end
  return cfg
end

T.section("Speed mapping")
local f = newFan(ifanCfg())
T.eq("3 speeds", { f.caps.speeds, f.caps.hasSpeed, f.caps.power, f.caps.reverse }, { 3, true, false, false })
local levels = { f:levelForSpeed(1), f:levelForSpeed(2), f:levelForSpeed(3) }
T.eq("spread: speeds 1-3 are levels 2, 4, 6", levels, { 2, 4, 6 })
local back = {}
for level = 0, 6 do
  back[#back + 1] = f:speedForLevel(level)
end
T.eq("levels 0-6 to speeds", back, { 0, 1, 1, 2, 2, 3, 3 })
local roundTrip = true
for n = 1, 6 do
  local g = newFan(ifanCfg({ speedValues = "", speedCount = n }))
  for s = 1, n do
    roundTrip = roundTrip and g:speedForLevel(g:levelForSpeed(s)) == s
  end
end
T.check("every speed count round-trips", roundTrip)
f = newFan(ifanCfg({ mapping = Fan.MAPPING_DIRECT }))
local direct = { f:speedForLevel(1), f:speedForLevel(3), f:speedForLevel(5), f:levelForSpeed(3) }
T.eq("direct: levels 1 to 3 are speeds 1 to 3, above runs speed 3", direct, { 1, 3, 3, 3 })

T.section("Speed values")
f = newFan(ifanCfg({ speedValues = "low, medium, high", speedOff = "off" }))
local parsed = { f:parseSpeed("LOW"), f:parseSpeed("high"), f:parseSpeed("off"), f:parseSpeed("auto") }
T.eq("names", parsed, { 1, 3, 0, nil })
f = newFan(ifanCfg({ speedValues = "33,66,100", speedOff = "" }))
T.eq("percentages go to the nearest", { f:parseSpeed("40"), f:parseSpeed("90"), f:parseSpeed("0") }, { 1, 3, 0 })
f = newFan(ifanCfg({ speedValues = "", speedCount = 4 }))
T.eq("Speed Count without values", { f.caps.speeds, f:speedValues()[4] }, { 4, "4" })
f = newFan(ifanCfg({ speedValues = "1,2,3,4,5,6,7,8" }))
T.eq("at most 6 speeds", f.caps.speeds, 6)

T.section("Tasmota iFan: state")
f = newFan(ifanCfg())
f:onMessage("stat/f/RESULT", '{"FanSpeed":2}')
T.eq("speed 2 is on at level 4", { #take("ON", 5001), speeds() }, { 1, { "4" } })
sent = {}
f:onMessage("stat/f/RESULT", '{"POWER1":"ON"}')
T.eq("a light-only message changes nothing", #sent, 0)
f:onMessage("stat/f/RESULT", '{"FanSpeed":0}')
T.eq("FanSpeed 0 is off", { #take("OFF", 5001), speeds() }, { 1, { "0" } })
T.eq("state text", f:stateText(), "Off")

T.section("Tasmota iFan: commands")
sent = {}
f:handleProxyCommand("SET_SPEED", { SPEED = "5" })
T.eq("level 5 runs speed 3", published(), { "cmnd/f/FanSpeed=3" })
T.eq("not optimistic with a state topic", #take("CURRENT_SPEED"), 0)
f:onMessage("stat/f/RESULT", '{"FanSpeed":3}')
sent = {}
f:handleProxyCommand("OFF")
T.eq("off sends the off value", published(), { "cmnd/f/FanSpeed=0" })
f:onMessage("stat/f/RESULT", '{"FanSpeed":0}')
sent = {}
f:handleProxyCommand("ON")
T.eq("on, no preset: the top speed", published(), { "cmnd/f/FanSpeed=3" })
sent = {}
f:handleProxyCommand("DESIGNATE_PRESET", { PRESET = "2" })
T.eq("preset told to the proxy", last(take("PRESET_SPEED", 5001)).SPEED, "2")
f:handleProxyCommand("TOGGLE")
T.eq("toggle from off goes to the preset", published(), { "cmnd/f/FanSpeed=1" })
f:onMessage("stat/f/RESULT", '{"FanSpeed":1}')
sent = {}
f:handleProxyCommand("CYCLE_SPEED_UP")
T.eq("speed up", published(), { "cmnd/f/FanSpeed=2" })
f:onMessage("stat/f/RESULT", '{"FanSpeed":3}')
sent = {}
f:handleProxyCommand("CYCLE_SPEED_UP")
T.eq("stays at the top", published(), { "cmnd/f/FanSpeed=3" })
f:onMessage("stat/f/RESULT", '{"FanSpeed":1}')
sent = {}
f:handleProxyCommand("CYCLE_SPEED_DOWN")
T.eq("down from the lowest: off", published(), { "cmnd/f/FanSpeed=0" })

T.section("On Speed: Last Speed")
f = newFan(ifanCfg({ onSpeed = Fan.ON_LAST }))
f:onMessage("stat/f/RESULT", '{"FanSpeed":2}')
f:onMessage("stat/f/RESULT", '{"FanSpeed":0}')
sent = {}
f:on()
T.eq("back to speed 2", published(), { "cmnd/f/FanSpeed=2" })

T.section("Power, speed and direction topics")
local function fullCfg(extra)
  local cfg = {
    mode = "Separate Topics",
    stateOn = "ON",
    stateOff = "OFF",
    payloadOn = "ON",
    payloadOff = "OFF",
    speedValues = "low,medium,high",
    directionForward = "forward",
    directionReverse = "reverse",
    topics = {
      power = { stateTopic = "fan/state", commandTopic = "fan/set" },
      speed = { stateTopic = "fan/speed", commandTopic = "fan/speed/set" },
      direction = { stateTopic = "fan/dir", commandTopic = "fan/dir/set" },
    },
  }
  for k, v in pairs(extra or {}) do
    cfg[k] = v
  end
  return cfg
end
f = newFan(fullCfg())
T.eq("capabilities", f:describeCapabilities(), "On/Off, 3 Speeds, Reverse")
f:onMessage("fan/speed", "medium")
f:onMessage("fan/state", "OFF")
T.eq("off while a speed is known", f.level, 0)
sent = {}
f:handleProxyCommand("SET_SPEED", { SPEED = "6" })
T.eq("from off: power on, then the speed", published(), { "fan/set=ON", "fan/speed/set=high" })
f:onMessage("fan/state", "ON")
f:onMessage("fan/speed", "high")
T.eq("on at level 6", f.level, 6)
sent = {}
f:handleProxyCommand("SET_SPEED", { SPEED = "1" })
T.eq("while on: only the speed", published(), { "fan/speed/set=low" })
sent = {}
f:handleProxyCommand("OFF")
T.eq("off uses the power topic", published(), { "fan/set=OFF" })
sent = {}
f:handleProxyCommand("SET_DIRECTION", { DIRECTION = "REVERSE" })
T.eq("direction", published(), { "fan/dir/set=reverse" })
f:onMessage("fan/dir", "reverse")
T.eq("reported to the proxy", last(take("DIRECTION", 5001)).DIRECTION, "REVERSE")
sent = {}
f:handleProxyCommand("TOGGLE_DIRECTION")
T.eq("toggle direction", published(), { "fan/dir/set=forward" })

T.section("A one-speed fan (relay)")
f = newFan({
  mode = "Separate Topics",
  payloadOn = "on",
  payloadOff = "off",
  topics = { power = { commandTopic = "shellyplus1-x/command/switch:0" } },
})
T.eq("on/off only, optimistic", { f:describeCapabilities(), f:isOptimistic() }, { "On/Off, no state feedback", true })
f:handleProxyCommand("SET_SPEED", { SPEED = "2" })
T.eq("any speed turns it on", published(), { "shellyplus1-x/command/switch:0=on" })
T.eq("optimistic: on at the top level", speeds(), { "6" })
f = newFan({
  mode = "Separate Topics",
  topics = { power = { stateTopic = "shellyplus1-x/status/switch:0", valuePath = "$.output" } },
})
f:onMessage("shellyplus1-x/status/switch:0", '{"id":0,"output":true}')
T.eq("Shelly status output true is on", f.level, 6)

T.section("Zigbee2MQTT (JSON)")
local function z2mCfg()
  return {
    mode = "JSON",
    payloadOn = "ON",
    payloadOff = "OFF",
    speedValues = "low,medium,high",
    speedOff = "off",
    json = {
      stateTopic = "zigbee2mqtt/fan",
      commandTopic = "zigbee2mqtt/fan/set",
      keys = { power = "fan_state", speed = "fan_mode" },
    },
  }
end
f = newFan(z2mCfg())
f:onMessage("zigbee2mqtt/fan", '{"fan_state":"ON","fan_mode":"medium","linkquality":80}')
T.eq("medium is level 4", f.level, 4)
sent = {}
f:handleProxyCommand("SET_SPEED", { SPEED = "2" })
local cmd = JSON:decode(last(take("PUBLISH", 5002)).payload)
T.eq("state and mode in one message", { cmd.fan_state, cmd.fan_mode }, { "ON", "low" })
sent = {}
f:handleProxyCommand("OFF")
T.eq("off", JSON:decode(last(take("PUBLISH", 5002)).payload), { fan_state = "OFF" })
local noState = z2mCfg()
noState.json.keys.power = ""
f = newFan(noState)
f:handleProxyCommand("OFF")
T.eq("off through the speed key", JSON:decode(last(take("PUBLISH", 5002)).payload), { fan_mode = "off" })

T.section("GET_CURRENT_STATE")
f = newFan(fullCfg())
f:onMessage("fan/state", "ON")
f:onMessage("fan/speed", "low")
f:designatePreset(3)
sent = {}
f:handleProxyCommand("GET_CURRENT_STATE")
T.eq("resends speed and preset", { #take("ON"), speeds(), last(take("PRESET_SPEED")).SPEED }, { 1, { "2" }, "3" })

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
local propertyWrites = {}
C4.UpdateProperty = function(_, name, value)
  propertyWrites[name] = value
end
local lists = {}
C4.UpdatePropertyList = function(_, name, items, current)
  lists[name] = { items = items, current = current }
end
local xml = assert(io.open("drivers/cp_mqtt_fan/driver.xml")):read("*a")
for block in xml:gmatch("<property>(.-)</property>") do
  Properties[block:match("<name>(.-)</name>")] = block:match("<default>(.-)</default>") or ""
end
Properties["Log Level"] = "2 - Warning"
ShimSetDevices({
  [900] = { deviceName = "MQTT Broker", driverFileName = "cp_mqtt_broker.c4z" },
  [12345] = { deviceName = "MQTT Fan", driverFileName = "cp_mqtt_fan.c4z" },
  [12346] = { deviceName = "MQTT Fan", driverFileName = "fan.c4i" },
})
ShimSetProxyDevices(12346)

T.section("Driver: driver.xml")
T.contains("fan proxy", xml, '<proxy proxybindingid="5001" name="MQTT Fan">fan</proxy>')
T.contains("6 levels", xml, "<discrete_levels>6</discrete_levels>")
T.contains("reversible", xml, "<can_reverse>True</can_reverse>")
for id = 300, 305 do
  T.contains("Button Link " .. id .. " declared", xml, "<id>" .. id .. "</id>")
end
T.contains("broker binding", xml, "<classname>CP_MQTT_BROKER</classname>")

T.section("Driver: start-up")
local ok, err = T.capture(function()
  dofile("drivers/cp_mqtt_fan/driver.lua")
  OnDriverInit()
  OnDriverLateInit()
end)
T.check("the driver starts", ok, err)
T.eq("it connects itself to the broker", C4:GetBoundProviderDevice(12345, 5002), 900)
T.eq("offline until the broker connects", last(take("ONLINE_CHANGED", 5001)).STATE, "false")
T.eq("On/Off only with no topics", propertyWrites["Capabilities"], "On/Off, no state feedback")

T.section("Driver: pick a Tasmota iFan")
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
  ExecuteCommand("TASMOTA_DEVICES", { devices = JSON:encode({ Tasmota.summary(dev), Tasmota.summary(plain) }) })
end)
T.eq("lists only the fan", lists["Discovered Device"].items, "(Manual),Bedroom [bedroom_fan] Fan")
Properties["Discovered Device"] = "Bedroom [bedroom_fan] Fan"
T.capture(function()
  OnPropertyChanged("Discovered Device")
end)
clockNow = clockNow + 10000
sent = {}
local applied, applyErr = T.capture(function()
  ExecuteCommand("TASMOTA_DEVICE", { mac = "A4CF12B3C4D6", device = JSON:encode(dev) })
end)
T.check("applies without error", applied, applyErr)
T.eq("settings filled in", { Properties["Speed Command Topic"], Properties["Speed Off Value"] }, {
  "cmnd/bedroom_fan/FanSpeed",
  "0",
})
T.eq("capabilities", propertyWrites["Capabilities"], "On/Off, 3 Speeds")
T.eq("renamed after the device", last(ShimRenames()).name, "Bedroom Fan")
local subs = {}
for _, m in ipairs(take("SUBSCRIBE")) do
  subs[m.topic] = true
end
T.check("subscribes to RESULT", subs["stat/bedroom_fan/RESULT"])
T.eq("asks for its state", published(), { "cmnd/bedroom_fan/STATE=" })

sent = {}
T.capture(function()
  ReceivedFromProxy(5001, "SET_SPEED", { SPEED = "4" })
end)
T.eq("Control4 sets a speed", published(), { "cmnd/bedroom_fan/FanSpeed=2" })
sent = {}
T.capture(function()
  ExecuteCommand("MQTT_MESSAGE", { topic = "stat/bedroom_fan/RESULT", payload = '{"FanSpeed":2}' })
end)
T.eq("and hears it", speeds(), { "4" })
T.eq("Fan State", propertyWrites["Fan State"], "Speed 2 of 3 (2, level 4)")

T.section("Driver: button links")
C4:Bind(12345, 301, 701, 1, "BUTTON_LINK")
C4:Bind(12345, 303, 703, 1, "BUTTON_LINK")
sent = {}
T.capture(function()
  ReceivedFromProxy(303, "DO_PUSH", {})
  ReceivedFromProxy(303, "DO_CLICK", {})
  ReceivedFromProxy(303, "DO_RELEASE", {})
end)
T.eq("Speed Up once per press", published(), { "cmnd/bedroom_fan/FanSpeed=3" })
sent = {}
T.capture(function()
  ReceivedFromProxy(301, "DO_PUSH", {})
  ReceivedFromProxy(301, "DO_CLICK", {})
end)
T.eq("Off", published(), { "cmnd/bedroom_fan/FanSpeed=0" })
sent = {}
T.capture(function()
  ExecuteCommand("MQTT_MESSAGE", { topic = "stat/bedroom_fan/RESULT", payload = '{"FanSpeed":0}' })
end)
T.eq("off: LEDs follow", last(take("MATCH_LED_STATE", 301)).STATE, "false")
sent = {}
T.capture(function()
  ReceivedFromProxy(301, "REQUEST_BUTTON_COLORS", {})
end)
local colors = last(take("BUTTON_COLORS", 301))
T.eq("Off link colors from the color pickers", { colors.ON_COLOR, colors.OFF_COLOR }, { "000000", "0000ff" })
Properties["Speed Button LED When On"] = "0,255,0"
sent = {}
T.capture(function()
  OnPropertyChanged("Speed Button LED When On")
end)
T.eq("a new color goes out at once", last(take("BUTTON_COLORS", 303)).ON_COLOR, "00ff00")

T.section("Driver: preset is kept")
T.capture(function()
  ReceivedFromProxy(5001, "DESIGNATE_PRESET", { PRESET = "2" })
end)
sent = {}
T.capture(function()
  ReceivedFromProxy(5001, "ON", {})
end)
T.eq("ON goes to the preset", published(), { "cmnd/bedroom_fan/FanSpeed=1" })

T.finish()
