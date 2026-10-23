-- Tests for the MQTT Light driver: color math, capability detection, payload
-- translation for Tasmota-style topics and Zigbee2MQTT-style JSON, ramps,
-- keypad buttons, and a smoke test of drivers/mqtt_light/driver.lua.
--
-- Run from the repo root:
--   make test
-- or:
--   ./test/run_test.sh test_mqtt_light.lua

local T = require("testlib")

require("c4_shim")
require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

local Color = require("mqtt.color")
local MqttLight = require("mqtt.light")

local PROXY, BROKER = 5001, 5002

-------------------------------------------------------------------------------
-- Harness
-------------------------------------------------------------------------------

local sent = {}
SendToProxy = function(binding, command, params, kind)
  table.insert(sent, { binding = binding, command = command, params = params or {}, kind = kind })
end

local function reset()
  sent = {}
end

local function publishes()
  local out = {}
  for _, m in ipairs(sent) do
    if m.binding == BROKER and m.command == "PUBLISH" then
      table.insert(out, { topic = m.params.topic, payload = m.params.payload })
    end
  end
  return out
end

local function published(topic)
  local out = {}
  for _, p in ipairs(publishes()) do
    if p.topic == topic then
      table.insert(out, p.payload)
    end
  end
  return out
end

local function notifies(command)
  local out = {}
  for _, m in ipairs(sent) do
    if m.binding == PROXY and m.command == command then
      table.insert(out, m.params)
    end
  end
  return out
end

local function last(list)
  return list[#list]
end

local clock = 0
local function newLight(cfg)
  local light = MqttLight.new({
    proxyBinding = PROXY,
    brokerBinding = BROKER,
    now = function()
      return clock
    end,
  })
  light:configure(cfg)
  return light
end

local function near(name, got, want, tol)
  T.check(
    name,
    got ~= nil and math.abs(got - want) <= tol,
    string.format("got %s want %s ±%s", tostring(got), want, tol)
  )
end

local function tasmotaConfig(extra)
  local cfg = {
    mode = MqttLight.MODE_TOPICS,
    optimistic = "Auto",
    stateOn = "ON",
    stateOff = "OFF",
    payloadOn = "ON",
    payloadOff = "OFF",
    brightnessMax = 100,
    colorTempUnit = "Mireds",
    colorTempMin = 2000,
    colorTempMax = 6500,
    colorFormat = MqttLight.COLOR_FORMATS.HEX,
    colorIncludesBrightness = true,
    transitionUnit = MqttLight.TRANSITION_UNITS.SECONDS,
    topics = {
      power = { stateTopic = "stat/bulb/POWER", commandTopic = "cmnd/bulb/POWER" },
      brightness = { stateTopic = "stat/bulb/RESULT", valuePath = "$.Dimmer", commandTopic = "cmnd/bulb/Dimmer" },
      colorTemp = { stateTopic = "stat/bulb/RESULT", valuePath = "$.CT", commandTopic = "cmnd/bulb/CT" },
      color = { stateTopic = "stat/bulb/RESULT", valuePath = "$.Color", commandTopic = "cmnd/bulb/Color" },
      white = {},
      transition = {},
    },
  }
  for k, v in pairs(extra or {}) do
    cfg[k] = v
  end
  return cfg
end

-------------------------------------------------------------------------------
T.section("Color conversions")
-------------------------------------------------------------------------------
local x, y = Color.rgbToXy(255, 0, 0)
near("red x", x, 0.64, 0.002)
near("red y", y, 0.33, 0.002)
local r, g, b = Color.xyToRgb(x, y)
T.eq("red round trips", { r, g, b }, { 255, 0, 0 })
T.eq("black has no chromaticity", { Color.rgbToXy(0, 0, 0) }, {})
x, y = Color.cctToXy(2700)
near("2700K round trips through xy", Color.xyToCct(x, y), 2700, 30)
x, y = Color.cctToXy(6500)
near("6500K round trips through xy", Color.xyToCct(x, y), 6500, 60)
T.eq("2700K is 370 mireds", Color.kelvinToMired(2700), 370)
T.eq("153 mireds is 6536K", Color.miredToKelvin(153), 6536)
T.eq("hsv red", { Color.hsvToRgb(0, 100, 100) }, { 255, 0, 0 })
T.eq("scale rgb to 50%", { Color.scaleRgb(255, 128, 0, 50) }, { 128, 64, 0 })

-------------------------------------------------------------------------------
T.section("Capabilities follow the filled-in topics")
-------------------------------------------------------------------------------
local light = newLight({ mode = MqttLight.MODE_TOPICS, topics = { power = { commandTopic = "cmnd/sw/POWER" } } })
T.eq("power only is a switch", light.caps.dimmer, false)
T.eq("power only has no color", light.caps.color, false)
T.eq("describe", light:describeCapabilities(), "On/Off")

light = newLight(tasmotaConfig())
T.eq("brightness topic makes a dimmer", light.caps.dimmer, true)
T.eq("color temp topic adds CCT", light.caps.cct, true)
T.eq("CCT range", { light.caps.cctMin, light.caps.cctMax }, { 2000, 6500 })
T.eq("color topic adds color", light.caps.color, true)
local dyn = light:dynamicCapabilities()
T.eq("dynamic caps: dimmer", dyn.dimmer, "true")
T.eq(
  "dynamic caps: color and CCT together",
  { dyn.supports_color, dyn.supports_color_correlated_temperature },
  { "true", "true" }
)
T.eq("one subscription for the shared RESULT topic", light:subscriptions(), { "stat/bulb/POWER", "stat/bulb/RESULT" })
T.eq("state topics mean not optimistic", light:isOptimistic(), false)

light = newLight({
  mode = MqttLight.MODE_TOPICS,
  colorFormat = MqttLight.COLOR_FORMATS.RGB,
  topics = { color = { commandTopic = "rgb/set" } },
})
T.eq("an RGB-only light dims through the color value", light.caps.dimmer, true)
T.eq("an RGB-only light has no native CCT", light.caps.cct, false)

light = newLight({
  mode = MqttLight.MODE_TOPICS,
  whiteColorTemp = 4000,
  topics = { color = { commandTopic = "c" }, white = { commandTopic = "w" } },
})
T.eq(
  "a white channel gives a fixed CCT",
  { light.caps.cct, light.caps.cctMin, light.caps.cctMax },
  { true, 4000, 4000 }
)

light = newLight({
  mode = MqttLight.MODE_JSON,
  json = {
    stateTopic = "z2m/bulb",
    commandTopic = "z2m/bulb/set",
    keys = { power = "state", brightness = "brightness" },
  },
})
T.eq("JSON mode: a key makes the ability", { light.caps.dimmer, light.caps.color }, { true, false })
T.eq("JSON mode subscribes to the state topic", light:subscriptions(), { "z2m/bulb" })

local changed = light:configure({
  mode = MqttLight.MODE_JSON,
  json = { stateTopic = "z2m/bulb", commandTopic = "z2m/bulb/set", keys = { power = "state" } },
})
T.eq("clearing a key changes capabilities", { changed, light.caps.dimmer }, { true, false })

-------------------------------------------------------------------------------
T.section("Tasmota: brightness, color temperature and color")
-------------------------------------------------------------------------------
reset()
light = newLight(tasmotaConfig())
light:handleProxyCommand("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "50", RATE = "0" })
T.eq("nothing is sent before the debounce", #publishes(), 0)
ShimFireTimers()
T.eq("turning on sends POWER ON then Dimmer", publishes(), {
  { topic = "cmnd/bulb/POWER", payload = "ON" },
  { topic = "cmnd/bulb/Dimmer", payload = "50" },
})
T.eq("not optimistic: no BRIGHTNESS_CHANGED before feedback", #notifies("LIGHT_BRIGHTNESS_CHANGED"), 0)

light:onMessage("stat/bulb/RESULT", '{"POWER":"ON","Dimmer":50,"CT":250,"Color":"808080"}')
T.eq("feedback reports the level", last(notifies("LIGHT_BRIGHTNESS_CHANGED")).LIGHT_BRIGHTNESS_CURRENT, 50)
light:onMessage("stat/bulb/POWER", "ON")
T.eq("a repeated state is not re-notified", #notifies("LIGHT_BRIGHTNESS_CHANGED"), 1)

reset()
local cx, cy = Color.cctToXy(2700)
light:handleProxyCommand("SET_COLOR_TARGET", {
  LIGHT_COLOR_TARGET_X = tostring(cx),
  LIGHT_COLOR_TARGET_Y = tostring(cy),
  LIGHT_COLOR_TARGET_MODE = "1",
  LIGHT_COLOR_TARGET_RATE = "0",
})
ShimFireTimers()
T.eq("CCT target goes to the CT topic in mireds", published("cmnd/bulb/CT"), { "370" })
T.eq("CCT target does not touch the color topic", published("cmnd/bulb/Color"), {})

reset()
light:handleProxyCommand("SET_COLOR_TARGET", {
  LIGHT_COLOR_TARGET_X = "0.64",
  LIGHT_COLOR_TARGET_Y = "0.33",
  LIGHT_COLOR_TARGET_MODE = "0",
})
ShimFireTimers()
T.eq("red at 50% is scaled hex", published("cmnd/bulb/Color"), { "800000" })

light:onMessage("stat/bulb/RESULT", '{"POWER":"ON","Dimmer":50,"CT":250,"Color":"80000000"}')
local col = last(notifies("LIGHT_COLOR_CHANGED"))
T.eq("a lit RGB part with dark white channels is full color", col.LIGHT_COLOR_CURRENT_COLOR_MODE, 0)
near("reported x", col.LIGHT_COLOR_CURRENT_X, 0.64, 0.002)

light:onMessage("stat/bulb/RESULT", '{"POWER":"ON","Dimmer":50,"CT":370,"Color":"000000FF"}')
col = last(notifies("LIGHT_COLOR_CHANGED"))
T.eq("dark RGB with a lit white channel is CCT", col.LIGHT_COLOR_CURRENT_COLOR_MODE, 1)
near("reported CCT", Color.xyToCct(col.LIGHT_COLOR_CURRENT_X, col.LIGHT_COLOR_CURRENT_Y), 2700, 40)

reset()
light:onMessage("stat/bulb/POWER", "OFF")
T.eq("power off reports 0", last(notifies("LIGHT_BRIGHTNESS_CHANGED")).LIGHT_BRIGHTNESS_CURRENT, 0)
light:onMessage("stat/bulb/RESULT", '{"Dimmer":50}')
T.eq("brightness while off stays 0", #notifies("LIGHT_BRIGHTNESS_CHANGED"), 1)
T.eq("state text", light:stateText(), "Off")

reset()
light:handleProxyCommand("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "0" })
ShimFireTimers()
T.eq("turning off sends POWER OFF only", publishes(), { { topic = "cmnd/bulb/POWER", payload = "OFF" } })

-------------------------------------------------------------------------------
T.section("Color chosen while off is applied at the next turn on")
-------------------------------------------------------------------------------
reset()
light = newLight(tasmotaConfig({ optimistic = "Yes" }))
light.level = 0
light:handleProxyCommand("SET_COLOR_TARGET", { LIGHT_COLOR_TARGET_X = "0.15", LIGHT_COLOR_TARGET_Y = "0.06" })
ShimFireTimers()
T.eq("color while off publishes nothing", #publishes(), 0)
T.eq("but the proxy hears the new color", #notifies("LIGHT_COLOR_CHANGED"), 1)
light:handleProxyCommand("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "100" })
ShimFireTimers()
T.eq("turning on sends the saved color", published("cmnd/bulb/Color"), { "0000FF" })
T.eq("optimistic reports the level at once", last(notifies("LIGHT_BRIGHTNESS_CHANGED")).LIGHT_BRIGHTNESS_CURRENT, 100)

-------------------------------------------------------------------------------
T.section("Zigbee2MQTT JSON with transition")
-------------------------------------------------------------------------------
reset()
light = newLight({
  mode = MqttLight.MODE_JSON,
  optimistic = "Auto",
  brightnessMax = 254,
  colorTempUnit = "Mireds",
  colorTempMin = 2200,
  colorTempMax = 6500,
  jsonColorFormat = MqttLight.JSON_COLOR_FORMATS.XY,
  transitionUnit = MqttLight.TRANSITION_UNITS.SECONDS,
  json = {
    stateTopic = "z2m/bulb",
    commandTopic = "z2m/bulb/set",
    keys = {
      power = "state",
      brightness = "brightness",
      colorTemp = "color_temp",
      color = "color",
      transition = "transition",
      colorMode = "color_mode",
    },
  },
})
T.eq("transition key enables device fades", light:dynamicCapabilities().color_rate_behavior, "1")
light:handleProxyCommand("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "100", RATE = "2000" })
light:handleProxyCommand("SET_COLOR_TARGET", { LIGHT_COLOR_TARGET_X = "0.64", LIGHT_COLOR_TARGET_Y = "0.33" })
ShimFireTimers()
local cmds = published("z2m/bulb/set")
T.eq("brightness and color are combined into one message", #cmds, 1)
local obj = JSON:decode(cmds[1])
T.eq("json state", obj.state, "ON")
T.eq("json brightness scaled to 254", obj.brightness, 254)
T.eq("json transition in seconds", obj.transition, 2)
near("json color x", obj.color and obj.color.x, 0.64, 0.001)
local changing = last(notifies("LIGHT_BRIGHTNESS_CHANGING"))
T.eq("BRIGHTNESS_CHANGING carries the rate", { changing.LIGHT_BRIGHTNESS_TARGET, changing.RATE }, { 100, 2000 })

light:onMessage("z2m/bulb", '{"state":"ON","brightness":254,"color_mode":"color_temp","color_temp":370}')
T.eq("feedback is held while the fade runs", #notifies("LIGHT_BRIGHTNESS_CHANGED"), 0)
ShimFireTimers()
T.eq("the end of the fade reports the level", last(notifies("LIGHT_BRIGHTNESS_CHANGED")).LIGHT_BRIGHTNESS_CURRENT, 100)
T.eq("color_mode decides CCT", last(notifies("LIGHT_COLOR_CHANGED")).LIGHT_COLOR_CURRENT_COLOR_MODE, 1)

reset()
light:onMessage("z2m/bulb", '{"state":"ON","brightness":127}')
T.eq("254 scale: 127 is 50%", last(notifies("LIGHT_BRIGHTNESS_CHANGED")).LIGHT_BRIGHTNESS_CURRENT, 50)

-------------------------------------------------------------------------------
T.section("Ramps without device transitions are stepped")
-------------------------------------------------------------------------------
reset()
clock = 0
light = newLight({
  mode = MqttLight.MODE_TOPICS,
  topics = { brightness = { commandTopic = "dim/set" } },
})
T.eq("command-only light is optimistic", light:isOptimistic(), true)
light:handleProxyCommand("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "100", RATE = "1000" })
ShimFireTimers() -- debounce -> first step
clock = 500
ShimFireTimers()
clock = 1000
for _ = 1, 10 do
  ShimFireTimers()
end
local steps = published("dim/set")
T.check("several steps were sent", #steps >= 3, tostring(#steps))
T.check(
  "no step turns the light off",
  not table.concat(steps, ","):find("^0,") and steps[1] ~= "0",
  table.concat(steps, ",")
)
T.eq("the last step is the target", last(steps), "100")
T.eq("the ramp ends with BRIGHTNESS_CHANGED", last(notifies("LIGHT_BRIGHTNESS_CHANGED")).LIGHT_BRIGHTNESS_CURRENT, 100)

-------------------------------------------------------------------------------
T.section("Keypad buttons: hold to dim, release to stop, click to toggle")
-------------------------------------------------------------------------------
reset()
clock = 0
light = newLight({
  mode = MqttLight.MODE_TOPICS,
  topics = { brightness = { commandTopic = "dim/set" } },
})
light:loadSettings({ holdRateUp = 4000 })
light:handleProxyCommand("BUTTON_ACTION", { BUTTON_ID = "0", ACTION = "1" })
T.eq("press is echoed to the proxy", last(notifies("BUTTON_ACTION")), { BUTTON_ID = 0, ACTION = 1 })
ShimFireTimers() -- hold delay -> ramp starts (first step)
T.eq("hold ramps toward 100", last(notifies("LIGHT_BRIGHTNESS_CHANGING")).LIGHT_BRIGHTNESS_TARGET, 100)
T.eq("a ramp up from off never sends 0 (off) first", published("dim/set")[1], "1")
clock = 2000
light:handleProxyCommand("BUTTON_ACTION", { BUTTON_ID = "0", ACTION = "0" })
local stopped = last(notifies("LIGHT_BRIGHTNESS_CHANGED")).LIGHT_BRIGHTNESS_CURRENT
near("release stops half way", stopped, 50, 1)
ShimFireTimers()
T.eq("no more steps after release", last(notifies("LIGHT_BRIGHTNESS_CHANGED")).LIGHT_BRIGHTNESS_CURRENT, stopped)

reset()
light:handleProxyCommand("BUTTON_ACTION", { BUTTON_ID = "2", ACTION = "1" })
light:handleProxyCommand("BUTTON_ACTION", { BUTTON_ID = "2", ACTION = "2" })
T.eq("toggle click while on turns off", last(published("dim/set")), "0")
light:handleProxyCommand("BUTTON_ACTION", { BUTTON_ID = "2", ACTION = "1" })
light:handleProxyCommand("BUTTON_ACTION", { BUTTON_ID = "2", ACTION = "2" })
T.eq("toggle click while off turns on to the On level", last(published("dim/set")), "100")

-------------------------------------------------------------------------------
T.section("Switches")
-------------------------------------------------------------------------------
reset()
light = newLight({
  mode = MqttLight.MODE_TOPICS,
  payloadOn = "1",
  payloadOff = "0",
  topics = { power = { commandTopic = "relay/set" } },
})
light:handleProxyCommand("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "30", RATE = "5000" })
ShimFireTimers()
T.eq("a switch turns fully on", published("relay/set"), { "1" })
T.eq("a switch reports 100", last(notifies("LIGHT_BRIGHTNESS_CHANGED")).LIGHT_BRIGHTNESS_CURRENT, 100)
T.eq("a switch sends no BRIGHTNESS_CHANGING", #notifies("LIGHT_BRIGHTNESS_CHANGING"), 0)

-------------------------------------------------------------------------------
T.section("Proxy settings are kept")
-------------------------------------------------------------------------------
local saved
light = MqttLight.new({
  proxyBinding = PROXY,
  brokerBinding = BROKER,
  onSettingsChanged = function(s)
    saved = s
  end,
})
light:configure({ mode = MqttLight.MODE_TOPICS, topics = { brightness = { commandTopic = "d" } } })
reset()
light:handleProxyCommand("SET_CLICK_RATE_UP", { RATE = "750" })
T.eq("click rate is confirmed to the proxy", last(notifies("CLICK_RATE_UP")), { RATE = 750 })
T.eq("click rate is saved", saved and saved.clickRateUp, 750)
light:handleProxyCommand("SET_PRESET_LEVEL", { LEVEL = "80" })
T.eq("On preset is saved", saved.onLevel, 80)

-------------------------------------------------------------------------------
T.section("drivers/mqtt_light/driver.lua loads and starts")
-------------------------------------------------------------------------------
local function readFile(path)
  local fh = assert(io.open(path, "r"))
  local body = fh:read("*a")
  fh:close()
  return body
end
local xml = readFile("drivers/mqtt_light/driver.xml")
for block in xml:gmatch("<property>(.-)</property>") do
  local name = block:match("<name>(.-)</name>")
  local default = block:match("<default>(.-)</default>") or ""
  Properties[name] = default
end
Properties["Log Level"] = "2 - Warning"
-- The shim carries no driver config, so the OS version gate would disable the driver.
local realGetDriverConfigInfo = C4.GetDriverConfigInfo
C4.GetDriverConfigInfo = function(c4, section)
  if section == "minimum_os_version" then
    return "3.3.0"
  end
  return realGetDriverConfigInfo(c4, section)
end
-- The shim's C4:UpdateProperty is a stub; record what the driver writes.
local propertyWrites = {}
C4.UpdateProperty = function(_, name, value)
  propertyWrites[name] = value
end
reset()
local ok, err = pcall(function()
  T.capture(function()
    dofile("drivers/mqtt_light/driver.lua")
    OnDriverInit()
    OnDriverLateInit()
  end)
end)
T.check("driver init runs without error", ok, err)
local capsMsg = last(notifies("DYNAMIC_CAPABILITIES_CHANGED"))
T.check("capabilities are sent at startup", capsMsg ~= nil)
T.eq("a light with no topics starts as a switch", capsMsg and capsMsg.dimmer, "false")

reset()
Properties["Brightness Command Topic"] = "cmnd/x/Dimmer"
T.capture(function()
  OnPropertyChanged("Brightness Command Topic")
end)
T.eq("filling a brightness topic makes it a dimmer", last(notifies("DYNAMIC_CAPABILITIES_CHANGED")).dimmer, "true")
T.eq("the Capabilities property follows", propertyWrites["Capabilities"], "On/Off, Dimmer")

reset()
Properties["Brightness State Topic"] = "stat/x/RESULT"
Properties["Brightness Value Path"] = "$.Dimmer"
T.capture(function()
  OnPropertyChanged("Brightness State Topic")
  ReceivedFromProxy(5002, "BROKER_CONNECTED", {})
end)
local subs = {}
for _, m in ipairs(sent) do
  if m.binding == 5002 and m.command == "SUBSCRIBE" then
    table.insert(subs, m.params.topic)
  end
end
T.eq("broker connect subscribes to the state topic", subs, { "stat/x/RESULT" })
T.eq("broker connect marks the light online", last(notifies("ONLINE_CHANGED")).STATE, "true")

reset()
T.capture(function()
  ExecuteCommand("MQTT_MESSAGE", { topic = "stat/x/RESULT", payload = '{"POWER":"ON","Dimmer":42}' })
end)
T.eq("an MQTT message reaches the proxy", last(notifies("LIGHT_BRIGHTNESS_CHANGED")).LIGHT_BRIGHTNESS_CURRENT, 42)
T.eq("Light State property", propertyWrites["Light State"], "On 42%")

reset()
T.capture(function()
  ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "10", RATE = "0" })
  ShimFireTimers()
end)
T.eq("a proxy command is published", published("cmnd/x/Dimmer"), { "10" })

T.finish()
