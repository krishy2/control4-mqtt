-- Tests for the MQTT Thermostat: the model (src/mqtt/thermostat.lua) and the
-- driver (thermostatV2 proxy). Abilities follow the topics filled in.
--
-- Run from the repo root:
--   make test
-- or:
--   ./test/run_test.sh test_mqtt_thermostat.lua

local T = require("testlib")
require("c4_shim")
require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")
JSON = JSON or require("JSON")
local Thermostat = require("mqtt.thermostat")

local sent = {}
C4.SendToProxy = function(_, binding, command, params)
  sent[#sent + 1] = { binding = binding, command = command, params = params or {} }
end
local function take(command)
  local out = {}
  for _, m in ipairs(sent) do
    if m.command == command then
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
  for _, p in ipairs(take("PUBLISH")) do
    out[#out + 1] = p.topic .. "=" .. p.payload
  end
  return out
end
local function newThermostat(cfg)
  local t = Thermostat.new({ proxyBinding = 5001, brokerBinding = 5002 })
  t:configure(cfg)
  sent = {}
  return t
end

T.section("Value maps")
local map, order = Thermostat.parseValueMap("off=0, Heat=1,auto=2,bogus=9", Thermostat.HVAC_MODES)
T.eq("names matched to Control4 names", { map.Off, map.Heat, map.Auto, map.bogus }, { "0", "1", "2" })
T.eq("in order", order, { "Off", "Heat", "Auto" })
T.eq("empty", Thermostat.parseValueMap("", Thermostat.HVAC_MODES), nil)
T.eq("C from CELSIUS", Thermostat.celsiusFromParams({ CELSIUS = "21.5" }), 21.5)
T.eq("C from FAHRENHEIT", Thermostat.celsiusFromParams({ FAHRENHEIT = "68" }), 20)
T.eq("C from VALUE and SCALE", Thermostat.celsiusFromParams({ VALUE = "50", SCALE = "FAHRENHEIT" }), 10)

-------------------------------------------------------------------------------
T.section("Heat only (Tasmota Thermostat driver style)")
-------------------------------------------------------------------------------
local heat = newThermostat({
  scale = "C",
  features = {
    temperature = { stateTopic = "tele/th/SENSOR", valuePath = "$.DS18B20.Temperature" },
    heat = {
      stateTopic = "tele/th/SENSOR",
      valuePath = "$.Thermostat0.TempTargetSet",
      commandTopic = "cmnd/th/TempTargetSet1",
    },
    mode = {
      stateTopic = "tele/th/SENSOR",
      valuePath = "$.Thermostat0.ThermostatModeSet",
      commandTopic = "cmnd/th/ThermostatModeSet1",
      values = "Off=0,Heat=1",
    },
    action = { stateTopic = "stat/th/RESULT", valuePath = "$.POWER1" },
  },
})
T.eq("heat, no cool, no single", { heat.caps.heat, heat.caps.cool, heat.caps.single }, { true, false, false })
T.eq("modes from the value map", heat.caps.modes, "Off,Heat")
heat:refreshProxy()
local dyn = take("DYNAMIC_CAPABILITIES_CHANGED")[1]
T.eq("capabilities", { dyn.CAN_HEAT, dyn.CAN_COOL, dyn.HAS_SINGLE_SETPOINT, dyn.HAS_HUMIDITY }, {
  true,
  false,
  false,
  false,
})
T.eq("allowed modes", last(take("ALLOWED_HVAC_MODES_CHANGED")).MODES, "Off,Heat")
T.eq("no fan modes", #take("ALLOWED_FAN_MODES_CHANGED"), 0)
T.eq("scale", last(take("SCALE_CHANGED")).SCALE, "C")
sent = {}
heat:onMessage(
  "tele/th/SENSOR",
  '{"DS18B20":{"Temperature":20.7},"Thermostat0":{"ThermostatModeSet":1,"TempTargetSet":21.5},"TempUnit":"C"}'
)
T.eq("temperature", last(take("TEMPERATURE_CHANGED")), { TEMPERATURE = "20.7", SCALE = "C" })
T.eq("heat setpoint", last(take("HEAT_SETPOINT_CHANGED")), { SETPOINT = "21.5", SCALE = "C" })
T.eq("mode", last(take("HVAC_MODE_CHANGED")).MODE, "Heat")
sent = {}
heat:onMessage("stat/th/RESULT", '{"POWER1":"ON"}')
T.eq("relay on: heating", last(take("HVAC_STATE_CHANGED")).STATE, "Heating")
heat:onMessage("stat/th/RESULT", '{"POWER1":"OFF"}')
T.eq("relay off: idle", last(take("HVAC_STATE_CHANGED")).STATE, "Idle")
sent = {}
heat:onMessage(
  "tele/th/SENSOR",
  '{"DS18B20":{"Temperature":20.7},"Thermostat0":{"ThermostatModeSet":1,"TempTargetSet":21.5}}'
)
T.eq("unchanged values are not resent", #sent, 0)
heat:handleProxyCommand("SET_SETPOINT_HEAT", { CELSIUS = "22.3", FAHRENHEIT = "72" })
T.eq("setpoint sent, rounded to the step", published(), { "cmnd/th/TempTargetSet1=22.5" })
sent = {}
heat:handleProxyCommand("SET_MODE_HVAC", { MODE = "Off" })
T.eq("mode Off sent as its value", published(), { "cmnd/th/ThermostatModeSet1=0" })
sent = {}
heat:handleProxyCommand("SET_SETPOINT_HEAT", { CELSIUS = "50" })
T.eq("clamped to Setpoint Max", published(), { "cmnd/th/TempTargetSet1=35" })
sent = {}
heat:handleProxyCommand("INC_SETPOINT_HEAT", {})
T.eq("one step up from the reported setpoint", published(), { "cmnd/th/TempTargetSet1=22" })

-------------------------------------------------------------------------------
T.section("TuyaMCU style: templates, multiplier, power")
-------------------------------------------------------------------------------
local tuya = newThermostat({
  scale = "C",
  multiplier = 10,
  features = {
    temperature = { stateTopic = "tele/moes/RESULT", valuePath = "$.TuyaReceived.DpType2Id24" },
    heat = {
      stateTopic = "tele/moes/RESULT",
      valuePath = "$.TuyaReceived.DpType2Id16",
      commandTopic = "cmnd/moes/TuyaSend2",
      template = "16,{value}",
    },
    power = {
      stateTopic = "tele/moes/RESULT",
      valuePath = "$.TuyaReceived.DpType1Id1",
      commandTopic = "cmnd/moes/TuyaSend1",
      payloadOn = "1,1",
      payloadOff = "1,0",
      stateOn = "1",
      stateOff = "0",
    },
    action = { stateTopic = "tele/moes/RESULT", valuePath = "$.TuyaReceived.DpType4Id102", values = "Heating=0,Idle=1" },
  },
})
T.eq("power adds Off", tuya.caps.modes, "Off,Heat")
tuya:onMessage("tele/moes/RESULT", '{"TuyaReceived":{"DpType2Id24":215}}')
T.eq("215 is 21.5", last(take("TEMPERATURE_CHANGED")).TEMPERATURE, "21.5")
tuya:onMessage("tele/moes/RESULT", '{"TuyaReceived":{"DpType1Id1":1}}')
T.eq("powered on: Heat", last(take("HVAC_MODE_CHANGED")).MODE, "Heat")
tuya:onMessage("tele/moes/RESULT", '{"TuyaReceived":{"DpType4Id102":0}}')
T.eq("mapped action", last(take("HVAC_STATE_CHANGED")).STATE, "Heating")
sent = {}
tuya:handleProxyCommand("SET_SETPOINT_HEAT", { CELSIUS = "23" })
T.eq("template and multiplier", published(), { "cmnd/moes/TuyaSend2=16,230" })
sent = {}
tuya:handleProxyCommand("SET_MODE_HVAC", { MODE = "Off" })
T.eq("Off switches it off", published(), { "cmnd/moes/TuyaSend1=1,0" })
tuya:onMessage("tele/moes/RESULT", '{"TuyaReceived":{"DpType1Id1":0}}')
T.eq("reported off: mode Off", last(take("HVAC_MODE_CHANGED")).MODE, "Off")
T.eq("and state Off", last(take("HVAC_STATE_CHANGED")).STATE, "Off")
sent = {}
tuya:handleProxyCommand("SET_MODE_HEAT", {})
T.eq("Heat switches it on", published(), { "cmnd/moes/TuyaSend1=1,1" })

-------------------------------------------------------------------------------
T.section("Heat and cool, fan, humidity, Fahrenheit")
-------------------------------------------------------------------------------
local hc = newThermostat({
  scale = "F",
  features = {
    temperature = { stateTopic = "hvac/state", valuePath = "$.temp" },
    humidity = { stateTopic = "hvac/state", valuePath = "$.rh" },
    heat = { stateTopic = "hvac/state", valuePath = "$.heat", commandTopic = "hvac/heat/set" },
    cool = { stateTopic = "hvac/state", valuePath = "$.cool", commandTopic = "hvac/cool/set" },
    mode = { stateTopic = "hvac/state", valuePath = "$.mode", commandTopic = "hvac/mode/set" },
    fan = { stateTopic = "hvac/state", valuePath = "$.fan", commandTopic = "hvac/fan/set" },
    action = { stateTopic = "hvac/state", valuePath = "$.action" },
  },
})
T.eq("heat, cool and auto", { hc.caps.heat, hc.caps.cool, hc.caps.auto, hc.caps.single }, { true, true, true, false })
T.eq("default modes", hc.caps.modes, "Off,Heat,Cool,Auto")
T.eq("default fan modes", hc.caps.fanModes, "Auto,Low,Medium,High")
hc:refreshProxy()
local caps = take("DYNAMIC_CAPABILITIES_CHANGED")
T.eq("humidity", caps[1].HAS_HUMIDITY, true)
T.eq(
  "limits in both scales",
  { caps[2].HEAT_SETPOINT_MIN_F, caps[2].HEAT_SETPOINT_MAX_F, caps[2].HEAT_SETPOINT_MIN_C },
  {
    40,
    95,
    4,
  }
)
T.eq("fan modes offered", last(take("ALLOWED_FAN_MODES_CHANGED")).MODES, "Auto,Low,Medium,High")
sent = {}
hc:onMessage("hvac/state", '{"temp":72.4,"rh":45.6,"heat":68,"cool":76,"mode":"cool","fan":"low","action":"cooling"}')
T.eq("temperature in F", last(take("TEMPERATURE_CHANGED")), { TEMPERATURE = "72.4", SCALE = "F" })
T.eq("humidity", last(take("HUMIDITY_CHANGED")).HUMIDITY, "46")
T.eq("cool setpoint", last(take("COOL_SETPOINT_CHANGED")).SETPOINT, "76")
T.eq("mode", last(take("HVAC_MODE_CHANGED")).MODE, "Cool")
T.eq("fan", last(take("FAN_MODE_CHANGED")).MODE, "Low")
T.eq("state", last(take("HVAC_STATE_CHANGED")).STATE, "Cooling")
sent = {}
hc:handleProxyCommand("SET_SETPOINT_COOL", { CELSIUS = "25", FAHRENHEIT = "77" })
T.eq("cool setpoint in F", published(), { "hvac/cool/set=77" })
sent = {}
hc:handleProxyCommand("SET_MODE_FAN", { MODE = "High" })
T.eq("fan mode default value", published(), { "hvac/fan/set=high" })
sent = {}
hc:handleProxyCommand("SET_MODE_HVAC", { MODE = "Auto" })
T.eq("mode default value", published(), { "hvac/mode/set=auto" })
sent = {}
hc:handleProxyCommand("SET_SCALE", { SCALE = "CELSIUS" })
T.eq("display scale", last(take("SCALE_CHANGED")).SCALE, "C")

-------------------------------------------------------------------------------
T.section("Single setpoint, no feedback")
-------------------------------------------------------------------------------
local single = newThermostat({
  scale = "C",
  features = {
    heat = { commandTopic = "ac/target" },
    cool = { commandTopic = "ac/target" },
    mode = { commandTopic = "ac/mode", values = "Off=OFF,Heat=HEAT,Cool=COOL,Dry=DRY" },
  },
})
T.eq("one topic for both: single setpoint", { single.caps.single, single.caps.heat, single.caps.cool }, {
  true,
  false,
  false,
})
T.eq("optimistic", single:isOptimistic(), true)
single:handleProxyCommand("SET_SETPOINT_SINGLE", { CELSIUS = "24" })
T.eq("sent", published(), { "ac/target=24" })
T.eq("and reported at once", last(take("SINGLE_SETPOINT_CHANGED")).SETPOINT, "24")
sent = {}
single:handleProxyCommand("SET_MODE_HVAC", { MODE = "Dry" })
T.eq("mode value", published(), { "ac/mode=DRY" })
T.eq("reported", last(take("HVAC_MODE_CHANGED")).MODE, "Dry")
sent = {}
single:handleProxyCommand("SET_MODE_HVAC", { MODE = "Auto" })
T.eq("a mode without a value is not sent", #take("PUBLISH"), 0)

-------------------------------------------------------------------------------
T.section("The driver")
-------------------------------------------------------------------------------
local realGetDriverConfigInfo = C4.GetDriverConfigInfo
C4.GetDriverConfigInfo = function(c4, section)
  if section == "minimum_os_version" then
    return "3.3.0"
  end
  return realGetDriverConfigInfo(c4, section)
end
local xml = assert(io.open("drivers/cp_mqtt_thermostat/driver.xml")):read("*a")
T.contains("thermostatV2 proxy", xml, ">thermostatV2</proxy>")
for block in xml:gmatch("<property>(.-)</property>") do
  Properties[block:match("<name>(.-)</name>")] = block:match("<default>(.-)</default>") or ""
end
Properties["Log Level"] = "2 - Warning"
ShimSetDevices({
  [900] = { deviceName = "MQTT Broker", driverFileName = "cp_mqtt_broker.c4z" },
  [12345] = { deviceName = "MQTT Thermostat", driverFileName = "cp_mqtt_thermostat.c4z" },
})
Properties["Temperature State Topic"] = "tele/th/SENSOR"
Properties["Temperature Value Path"] = "$.DS18B20.Temperature"
Properties["Heat Setpoint Command Topic"] = "cmnd/th/TempTargetSet1"
Properties["Availability Topic"] = "tele/th/LWT"
Properties["Payload Available"] = "Online"
Properties["Payload Not Available"] = "Offline"
local ok, err = T.capture(function()
  dofile("drivers/cp_mqtt_thermostat/driver.lua")
  OnDriverInit()
  OnDriverLateInit()
end)
T.check("the driver starts", ok, err)
T.eq("it connects itself to the broker", C4:GetBoundProviderDevice(12345, 5002), 900)
T.eq("capabilities at start-up", take("DYNAMIC_CAPABILITIES_CHANGED")[1].CAN_HEAT, true)
T.eq("not connected yet", last(take("CONNECTION")).CONNECTED, "false")
sent = {}
T.capture(function()
  ReceivedFromProxy(5002, "BROKER_CONNECTED", {})
end)
T.eq("connected", last(take("CONNECTION")).CONNECTED, "true")
local subs = {}
for _, m in ipairs(take("SUBSCRIBE")) do
  subs[m.topic] = true
end
T.check("subscribes to the temperature topic", subs["tele/th/SENSOR"])
sent = {}
T.capture(function()
  ExecuteCommand("MQTT_MESSAGE", { topic = "tele/th/SENSOR", payload = '{"DS18B20":{"Temperature":19.25}}' })
end)
T.eq("temperature reaches Control4", last(take("TEMPERATURE_CHANGED")).TEMPERATURE, "19.3")
sent = {}
T.capture(function()
  ReceivedFromProxy(5001, "SET_SETPOINT_HEAT", { CELSIUS = "21" })
end)
T.eq("Control4 sets the setpoint", published(), { "cmnd/th/TempTargetSet1=21" })
sent = {}
T.capture(function()
  ExecuteCommand("MQTT_MESSAGE", { topic = "tele/th/LWT", payload = "Offline" })
end)
T.eq("device offline: not connected", last(take("CONNECTION")).CONNECTED, "false")
Properties["Cool Setpoint Command Topic"] = "cmnd/th/TempTargetSet1"
sent = {}
T.capture(function()
  OnPropertyChanged("Cool Setpoint Command Topic")
end)
T.eq("filling in a topic changes the capabilities", take("DYNAMIC_CAPABILITIES_CHANGED")[1].HAS_SINGLE_SETPOINT, true)

T.finish()
