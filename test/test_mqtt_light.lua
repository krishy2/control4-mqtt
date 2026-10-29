-- Tests for the MQTT Light driver: color math, capability detection, payload
-- translation for Tasmota-style topics and Zigbee2MQTT-style JSON, ramps,
-- keypad buttons, and a smoke test of drivers/cp_mqtt_light/driver.lua.
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
T.section("drivers/cp_mqtt_light/driver.lua loads and starts")
-------------------------------------------------------------------------------
local function readFile(path)
  local fh = assert(io.open(path, "r"))
  local body = fh:read("*a")
  fh:close()
  return body
end
local xml = readFile("drivers/cp_mqtt_light/driver.xml")
T.contains("driver.xml declares the light_v2 proxy on binding 5001", xml, '<proxy proxybindingid="5001"')
T.check(
  "driver.xml is not a combo driver (combo drivers get no proxy or Navigator UI)",
  not xml:find("<combo>", 1, true)
)
-- Composer reads the brightness and color rate limits as 16-bit numbers: a larger
-- maximum wraps negative and even its 0.75 s default is refused as out of range.
for _, cap in ipairs({ "brightness_rate_min", "brightness_rate_max", "color_rate_min", "color_rate_max" }) do
  local value = tonumber(xml:match("<" .. cap .. ">(%-?%d+)</" .. cap .. ">"))
  T.check(cap .. " fits a 16-bit signed number", value ~= nil and value >= 0 and value <= 32767, tostring(value))
end
-- Composer takes missing ranges in DYNAMIC_CAPABILITIES_CHANGED as 0-0 and then
-- refuses the 0.75 s default color rate on a plain dimmer.
for _, cfg in ipairs({ {}, { color = true } }) do
  local dyn = MqttLight.new({}):dynamicCapabilities()
  if cfg.color then
    local l = MqttLight.new({})
    l:configure({ topics = { power = { commandTopic = "p" }, color = { commandTopic = "c" } } })
    dyn = l:dynamicCapabilities()
  end
  for _, cap in ipairs({ "brightness_rate_min", "brightness_rate_max", "color_rate_min", "color_rate_max" }) do
    T.eq(
      (cfg.color and "color light: " or "switch: ") .. cap .. " matches driver.xml",
      dyn[cap],
      xml:match("<" .. cap .. ">(%-?%d+)</" .. cap .. ">")
    )
  end
end
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
-- A project with a broker driver (900) and this light, not yet connected.
ShimSetDevices({
  [900] = { deviceName = "MQTT Broker", driverFileName = "cp_mqtt_broker.c4z" },
  [12345] = { deviceName = "MQTT Light", driverFileName = "cp_mqtt_light.c4z" },
  [12346] = { deviceName = "MQTT Light", driverFileName = "light_v2.c4i" },
})
ShimSetProxyDevices(12346)
-- T.capture returns pcall's result itself; wrapping it in another pcall would hide errors.
local ok, err = T.capture(function()
  dofile("drivers/cp_mqtt_light/driver.lua")
  OnDriverInit()
  OnDriverLateInit()
end)
T.check("driver init runs without error", ok, err)
T.eq("it connects itself to the broker", C4:GetBoundProviderDevice(12345, 5002), 900)
T.eq("the light is not renamed at start-up", #ShimRenames(), 0)
T.eq("no driver code leaks into globals", { rawget(_G, "tasmotaSelection"), rawget(_G, "tasmotaChoices") }, {})
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

-------------------------------------------------------------------------------
T.section("State request when the broker connects or the device comes online")
-------------------------------------------------------------------------------
local fakeNow = 1000000
local realGetTime = C4.GetTime
C4.GetTime = function()
  return fakeNow
end
Properties["State Request Topic"] = "cmnd/x/STATE"
Properties["State Request Payload"] = ""
Properties["Availability Topic"] = "tele/x/LWT"
Properties["Payload Available"] = "Online"
Properties["Payload Not Available"] = "Offline"
T.capture(function()
  OnPropertyChanged("Availability Topic")
end)

reset()
T.capture(function()
  ReceivedFromProxy(5002, "BROKER_CONNECTED", {})
end)
T.eq("broker connected: state is requested", published("cmnd/x/STATE"), { "" })

fakeNow = fakeNow + 500
T.capture(function()
  ExecuteCommand("MQTT_MESSAGE", { topic = "tele/x/LWT", payload = "Online" })
end)
T.eq("Online right after: merged into the same request", #published("cmnd/x/STATE"), 1)

fakeNow = fakeNow + 60000
T.capture(function()
  ExecuteCommand("MQTT_MESSAGE", { topic = "tele/x/LWT", payload = "Online" })
end)
T.eq("Online again while already online: no request", #published("cmnd/x/STATE"), 1)

T.capture(function()
  ExecuteCommand("MQTT_MESSAGE", { topic = "tele/x/LWT", payload = "Offline" })
end)
fakeNow = fakeNow + 5000
T.capture(function()
  ExecuteCommand("MQTT_MESSAGE", { topic = "tele/x/LWT", payload = "Online" })
end)
T.eq("device back online: state is requested again", #published("cmnd/x/STATE"), 2)

reset()
Properties["State Request Topic"] = ""
fakeNow = fakeNow + 60000
T.capture(function()
  ReceivedFromProxy(5002, "BROKER_CONNECTED", {})
end)
T.eq("no State Request Topic: nothing is sent", #published("cmnd/x/STATE"), 0)
C4.GetTime = realGetTime

-------------------------------------------------------------------------------
T.section("Discovered Device dropdown: Tasmota")
-------------------------------------------------------------------------------
local Tasmota = require("mqtt.tasmota")
local lists = {}
C4.UpdatePropertyList = function(_, name, items, current)
  lists[name] = { items = items, current = current }
end
local function sentTo(command)
  local out = {}
  for _, m in ipairs(sent) do
    if m.binding == BROKER and m.command == command then
      out[#out + 1] = m.params
    end
  end
  return out
end
local function tasmotaConfig(topic, lt, rl)
  return Tasmota.parse(
    string.format(
      '{"ip":"10.0.0.7","dn":"Kitchen","fn":["Kitchen",null,null,null,null,null,null,null],"hn":"h","mac":"84F3EBA1B2C3",'
        .. '"md":"Generic","ofln":"Offline","onln":"Online","state":["OFF","ON","TOGGLE","HOLD"],"sw":"14.3.0",'
        .. '"t":"%s","ft":"%%prefix%%/%%topic%%/","tp":["cmnd","stat","tele"],"rl":[%s],'
        .. '"so":{"4":0,"11":0,"13":0,"17":0,"20":0,"30":0,"68":0,"73":0,"82":0,"114":0,"117":0},"lk":1,"lt_st":%d,"ver":1}',
      topic,
      rl,
      lt
    )
  )
end
local kitchen = tasmotaConfig("tasmota_kitchen", 5, "1,2,0,0,0,0,0,0")
local function listPayload(dev)
  return JSON:encode({ Tasmota.summary(dev) })
end

reset()
Properties["Transition Command Topic"] = ""
T.capture(function()
  ReceivedFromProxy(5002, "BROKER_CONNECTED", {})
end)
T.eq("broker connected: the device list is requested", #sentTo("GET_TASMOTA_DEVICES"), 1)
T.capture(function()
  ExecuteCommand("TASMOTA_DEVICES", { devices = listPayload(kitchen) })
end)
local dl = lists["Discovered Device"]
T.contains("the dropdown offers the light", dl and dl.items, "Kitchen [tasmota_kitchen] RGBCCT light")
T.contains("and the relay", dl and dl.items, "Kitchen [tasmota_kitchen] Relay 1")
T.eq("(Manual) stays selected", dl and dl.current, "(Manual)")

reset()
Properties["Discovered Device"] = "Kitchen [tasmota_kitchen] RGBCCT light"
T.capture(function()
  OnPropertyChanged("Discovered Device")
end)
local req = sentTo("GET_TASMOTA_DEVICE")[1]
T.eq("choosing it asks for the device", req and req.mac, "84F3EBA1B2C3")

reset()
local applied, applyErr = T.capture(function()
  ExecuteCommand("TASMOTA_DEVICE", { mac = "84F3EBA1B2C3", device = JSON:encode(kitchen) })
end)
T.check("applying runs without error", applied, applyErr)
T.eq("power on output 2 of 2", { Properties["Power Value Path"], Properties["Power Command Topic"] }, {
  "$.POWER2",
  "cmnd/tasmota_kitchen/POWER2",
})
T.eq("availability", Properties["Availability Topic"], "tele/tasmota_kitchen/LWT")
local capsMsg2 = last(notifies("DYNAMIC_CAPABILITIES_CHANGED"))
T.eq("capabilities: dimmer, color and CT", {
  capsMsg2 and capsMsg2.dimmer,
  capsMsg2 and capsMsg2.supports_color,
  capsMsg2 and capsMsg2.supports_color_correlated_temperature,
}, { "true", "true", "true" })
local subs2 = {}
for _, m in ipairs(sentTo("SUBSCRIBE")) do
  subs2[m.topic] = true
end
T.check("subscribes to RESULT", subs2["stat/tasmota_kitchen/RESULT"])
T.check("and to LWT", subs2["tele/tasmota_kitchen/LWT"])
T.eq("asks the device for its state", #published("cmnd/tasmota_kitchen/STATE"), 1)
T.contains("Capabilities property", propertyWrites["Capabilities"], "Color Temp")
T.eq("picking the output renames the light and its proxy", ShimRenames(), {
  { deviceId = 12345, name = "Kitchen RGBCCT light" },
  { deviceId = 12346, name = "Kitchen RGBCCT light" },
})

reset()
T.capture(function()
  ExecuteCommand("MQTT_MESSAGE", { topic = "stat/tasmota_kitchen/RESULT", payload = '{"POWER2":"ON","Dimmer":30}' })
end)
T.eq("its state reaches Control4", last(notifies("LIGHT_BRIGHTNESS_CHANGED")).LIGHT_BRIGHTNESS_CURRENT, 30)

-------------------------------------------------------------------------------
T.section("The light follows the device")
-------------------------------------------------------------------------------
Properties["Transition Command Topic"] = "cmnd/tasmota_kitchen/Speed"
local renamed = tasmotaConfig("kitchen_light", 5, "1,2,0,0,0,0,0,0")
reset()
T.capture(function()
  ReceivedFromProxy(5002, "TASMOTA_DEVICES_CHANGED", { mac = "84F3EBA1B2C3" })
end)
T.eq(
  "a change asks for the list and the device",
  { #sentTo("GET_TASMOTA_DEVICES"), #sentTo("GET_TASMOTA_DEVICE") },
  { 1, 1 }
)
T.capture(function()
  ExecuteCommand("TASMOTA_DEVICES", { devices = listPayload(renamed) })
  ExecuteCommand("TASMOTA_DEVICE", { mac = "84F3EBA1B2C3", device = JSON:encode(renamed) })
end)
T.eq("topics follow the new device topic", Properties["Power Command Topic"], "cmnd/kitchen_light/POWER2")
T.eq("a Tasmota fade topic follows too", Properties["Transition Command Topic"], "cmnd/kitchen_light/Speed")
T.eq("the dropdown shows the new name", lists["Discovered Device"].current, "Kitchen [kitchen_light] RGBCCT light")
T.eq("the device changing does not rename the light again", #ShimRenames(), 2)

reset()
T.capture(function()
  ReceivedFromProxy(5002, "TASMOTA_DEVICES_CHANGED", { mac = "OTHERMAC" })
end)
T.eq("another device changing does not touch this light", #sentTo("GET_TASMOTA_DEVICE"), 0)

-------------------------------------------------------------------------------
T.section("The choice survives a restart")
-------------------------------------------------------------------------------
lists["Discovered Device"] = nil
local restarted, restartErr = T.capture(function()
  OnDriverInit()
  OnDriverLateInit()
end)
T.check("restart runs without error", restarted, restartErr)
T.eq(
  "the chosen device is still selected",
  lists["Discovered Device"] and lists["Discovered Device"].current,
  "Kitchen [kitchen_light] RGBCCT light"
)
reset()
T.capture(function()
  ReceivedFromProxy(5002, "TASMOTA_DEVICES_CHANGED", { mac = "84F3EBA1B2C3" })
end)
T.eq("and still followed", #sentTo("GET_TASMOTA_DEVICE"), 1)
T.capture(function()
  ExecuteCommand("TASMOTA_DEVICE", { mac = "84F3EBA1B2C3", device = JSON:encode(renamed) })
end)
T.eq("nor does a restart", #ShimRenames(), 2)
T.eq("a restart does not bind a second time", #ShimConnections(), 1)

-------------------------------------------------------------------------------
T.section("Back to Manual")
-------------------------------------------------------------------------------
Properties["Discovered Device"] = "(Manual)"
T.capture(function()
  OnPropertyChanged("Discovered Device")
end)
reset()
T.capture(function()
  ReceivedFromProxy(5002, "TASMOTA_DEVICES_CHANGED", { mac = "84F3EBA1B2C3" })
end)
T.eq("Manual: device changes are no longer applied", #sentTo("GET_TASMOTA_DEVICE"), 0)
T.eq("the settings stay as they were", Properties["Power Command Topic"], "cmnd/kitchen_light/POWER2")

-------------------------------------------------------------------------------
T.section("Discovered Device dropdown: Shelly")
-------------------------------------------------------------------------------
local Shelly = require("mqtt.shelly")
local constants = require("constants")
local SP = "shellyplusrgbwpm-a0a3b3c4d5e6"
local shellyDev = Shelly.build(
  { id = SP, mac = "A0A3B3C4D5E6", model = "SNDC-0D4P10WW", gen = 2, ver = "1.4.4", app = "PlusRGBWPM" },
  SP,
  { sys = { device = { name = "Living RGBW" } }, ["rgbw:0"] = { id = 0 } }
)
local shellyAttribs = {}
C4.SetPropertyAttribs = function(_, name, value)
  shellyAttribs[name] = value
end
reset()
T.capture(function()
  ExecuteCommand("TASMOTA_DEVICES", {
    devices = JSON:encode({ Tasmota.summary(renamed), Shelly.summary(shellyDev) }),
  })
end)
local shellyLabel = "Living RGBW [" .. SP .. "] RGBW light"
T.contains("the dropdown offers the Shelly", lists["Discovered Device"].items, shellyLabel)
T.contains("next to the Tasmota", lists["Discovered Device"].items, "Kitchen [kitchen_light] RGBCCT light")

Properties["Discovered Device"] = shellyLabel
T.capture(function()
  OnPropertyChanged("Discovered Device")
end)
T.eq("choosing it asks the broker for it", sentTo("GET_TASMOTA_DEVICE")[1].mac, "A0A3B3C4D5E6")
local renamesBefore = #ShimRenames()
-- The restart above left the light without a broker; connect it, and move the
-- clock past the window that merges state requests.
local shellyNow = os.time() * 1000 + 10000000
C4.GetTime = function()
  return shellyNow
end
T.capture(function()
  ReceivedFromProxy(5002, "BROKER_CONNECTED", {})
end)
shellyNow = shellyNow + 10000
reset()
local shellyApplied, shellyErr = T.capture(function()
  ExecuteCommand("TASMOTA_DEVICE", { mac = "A0A3B3C4D5E6", device = JSON:encode(shellyDev) })
end)
T.check("applying the Shelly runs without error", shellyApplied, shellyErr)
T.eq("Shelly settings", {
  Properties["Payload Mode"],
  Properties["Shelly Topic Prefix"],
  Properties["Shelly Component"],
  Properties["Availability Topic"],
}, { "Shelly (Gen2+)", SP, "rgbw:0", SP .. "/online" })
local shellyCaps = last(notifies("DYNAMIC_CAPABILITIES_CHANGED"))
T.eq("capabilities: dimmer and color", {
  shellyCaps and shellyCaps.dimmer,
  shellyCaps and shellyCaps.supports_color,
}, { "true", "true" })
local shellySubs = {}
for _, m in ipairs(sentTo("SUBSCRIBE")) do
  shellySubs[m.topic] = true
end
T.check("subscribes to NotifyStatus", shellySubs[SP .. "/events/rpc"])
T.check("and to its status answers", shellySubs["control4/" .. SP .. "/rgbw_0/rpc"])
local stateAsk = published(SP .. "/rpc")[1]
T.contains("asks the Shelly for its state", stateAsk, "RGBW.GetStatus")
T.eq("Shelly fields shown, topic fields hidden", {
  shellyAttribs["Shelly Topic Prefix"],
  shellyAttribs["Power Command Topic"],
  shellyAttribs["JSON State Topic"],
}, { constants.SHOW_PROPERTY, constants.HIDE_PROPERTY, constants.HIDE_PROPERTY })
T.eq("the light is renamed after the Shelly", last(ShimRenames()).name, "Living RGBW")
T.eq("light and proxy", #ShimRenames() - renamesBefore, 2)

reset()
T.capture(function()
  ExecuteCommand("MQTT_MESSAGE", {
    topic = SP .. "/events/rpc",
    payload = '{"method":"NotifyStatus","params":{"ts":1,"rgbw:0":{"id":0,"output":true,"brightness":35,"rgb":[0,0,255],"white":0}}}',
  })
end)
T.eq("Shelly state reaches Control4", last(notifies("LIGHT_BRIGHTNESS_CHANGED")).LIGHT_BRIGHTNESS_CURRENT, 35)
reset()
T.capture(function()
  ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "0", RATE = "0" })
  ShimFireTimers()
end)
T.contains("Control4 turns it off over RPC", published(SP .. "/rpc")[1], '"on":false')

-------------------------------------------------------------------------------
T.section("ON, OFF and Toggle button links")
-------------------------------------------------------------------------------
for id, name in pairs({ [300] = "ON Button Link", [301] = "OFF Button Link", [302] = "Toggle Button Link" }) do
  local found = false
  for conn in xml:gmatch("<connection>(.-)</connection>") do
    if conn:find("<id>" .. id .. "</id>", 1, true) then
      found = conn:find("<connectionname>" .. name .. "</connectionname>", 1, true) ~= nil
        and conn:find("<classname>BUTTON_LINK</classname>", 1, true) ~= nil
        and conn:find("<consumer>False</consumer>", 1, true) ~= nil
    end
  end
  T.check("driver.xml declares the " .. name .. " (" .. id .. ")", found)
end
T.contains("has_leds: Composer shows the LED colors", xml, "<has_leds>true</has_leds>")
T.contains("has_button_events", xml, "<has_button_events>true</has_button_events>")
T.contains("three buttons", xml, "<num_buttons>3</num_buttons>")

local function onLink(binding, command)
  local out = {}
  for _, m in ipairs(sent) do
    if m.binding == binding and m.command == command then
      out[#out + 1] = m.params
    end
  end
  return out
end

-- Keypad buttons bound to the ON and Toggle links (as Composer does).
C4:Bind(12345, 300, 700, 1, "BUTTON_LINK")
C4:Bind(12345, 302, 701, 1, "BUTTON_LINK")

-- The light is the Shelly RGBW from the section above: commands go over RPC.
reset()
T.capture(function()
  ReceivedFromProxy(300, "DO_PUSH", {})
  ReceivedFromProxy(300, "DO_CLICK", {})
end)
T.contains("ON link tap turns the light on", published(SP .. "/rpc")[1], '"on":true')
T.eq("echoed to the proxy as button 0 like a stock driver", last(notifies("BUTTON_ACTION")).BUTTON_ID, 0)

-- Still on from the section above: switch it off first, so on is a change.
T.capture(function()
  ExecuteCommand("MQTT_MESSAGE", {
    topic = SP .. "/events/rpc",
    payload = '{"method":"NotifyStatus","params":{"ts":1,"rgbw:0":{"id":0,"output":false}}}',
  })
end)
reset()
T.capture(function()
  ExecuteCommand("MQTT_MESSAGE", {
    topic = SP .. "/events/rpc",
    payload = '{"method":"NotifyStatus","params":{"ts":2,"rgbw:0":{"id":0,"output":true,"brightness":50}}}',
  })
end)
T.eq("light on: MATCH_LED_STATE true on the bound ON link", last(onLink(300, "MATCH_LED_STATE")).STATE, "true")
T.eq("and on the bound Toggle link", last(onLink(302, "MATCH_LED_STATE")).STATE, "true")
T.eq("not on the unbound OFF link", #onLink(301, "MATCH_LED_STATE"), 0)

reset()
T.capture(function()
  ExecuteCommand("MQTT_MESSAGE", {
    topic = SP .. "/events/rpc",
    payload = '{"method":"NotifyStatus","params":{"ts":3,"rgbw:0":{"id":0,"brightness":60}}}',
  })
end)
T.eq("a brightness change alone does not resend it", #onLink(300, "MATCH_LED_STATE"), 0)

reset()
T.capture(function()
  ReceivedFromProxy(5001, "SET_BUTTON_COLOR", {
    BUTTON_ID = "2",
    ON_COLOR = "00ff00",
    OFF_COLOR = "0000ff",
    CURRENT_COLOR = "00ff00",
  })
end)
local info = last(notifies("BUTTON_INFO"))
T.eq("a color from the proxy panel is confirmed with BUTTON_INFO", {
  info and info.BUTTON_ID,
  info and info.ON_COLOR,
  info and info.OFF_COLOR,
  info and info.CURRENT_COLOR,
}, { 2, "00ff00", "0000ff", "00ff00" })
local linkColors = last(onLink(302, "BUTTON_COLORS"))
T.eq("and sent to the keypad on the Toggle link", { linkColors.ON_COLOR, linkColors.OFF_COLOR }, { "00ff00", "0000ff" })
T.eq("with the light's state", last(onLink(302, "MATCH_LED_STATE")).STATE, "true")
T.eq("not passed on to the light model", #published(SP .. "/rpc"), 0)

reset()
T.capture(function()
  ReceivedFromProxy(301, "DO_PUSH", {})
  ReceivedFromProxy(301, "DO_CLICK", {})
end)
T.contains("OFF link tap turns the light off", published(SP .. "/rpc")[1], '"on":false')

reset()
T.capture(function()
  ExecuteCommand("MQTT_MESSAGE", {
    topic = SP .. "/events/rpc",
    payload = '{"method":"NotifyStatus","params":{"ts":4,"rgbw:0":{"id":0,"output":false}}}',
  })
end)
T.eq("light off: MATCH_LED_STATE false", last(onLink(300, "MATCH_LED_STATE")).STATE, "false")

reset()
T.capture(function()
  ReceivedFromProxy(302, "DO_PUSH", {})
  ReceivedFromProxy(302, "DO_CLICK", {})
end)
T.contains("Toggle tap while off turns it on", published(SP .. "/rpc")[1], '"on":true')

reset()
T.capture(function()
  ReceivedFromProxy(300, "DO_PUSH", {})
  ShimFireTimers()
end)
T.contains("holding the ON link dims up on the device", published(SP .. "/rpc")[1], "transition_duration")
reset()
T.capture(function()
  ReceivedFromProxy(300, "DO_RELEASE", {})
end)
T.contains("releasing stops the fade where it is", published(SP .. "/rpc")[1], '"brightness"')

reset()
T.capture(function()
  ReceivedFromProxy(302, "REQUEST_BUTTON_COLORS", {})
end)
T.eq("a keypad asking gets the colors", last(onLink(302, "BUTTON_COLORS")).ON_COLOR, "00ff00")
reset()
T.capture(function()
  OnBindingChanged(301, "BUTTON_LINK", true, 702, 1)
end)
T.eq("binding a keypad button sends it the colors", last(onLink(301, "BUTTON_COLORS")).OFF_COLOR, "0000ff")

reset()
T.capture(function()
  ReceivedFromProxy(5001, "SET_ALL_LED", { COLOR = "ff0000" })
end)
T.eq("SET_ALL_LED sets every button", #notifies("BUTTON_INFO"), 3)

restarted, restartErr = T.capture(function()
  OnDriverInit()
  OnDriverLateInit()
end)
T.check("restart runs without error", restarted, restartErr)
reset()
T.capture(function()
  ReceivedFromProxy(301, "REQUEST_BUTTON_COLORS", {})
end)
T.eq("chosen colors survive a restart", last(onLink(301, "BUTTON_COLORS")).ON_COLOR, "ff0000")

-------------------------------------------------------------------------------
T.section("Load groups (Switch Group)")
-------------------------------------------------------------------------------
T.contains("driver.xml offers load groups", xml, "<load_group_support>true</load_group_support>")
local grp = newLight({
  mode = "Separate Topics",
  topics = {
    power = { commandTopic = "cmnd/g/POWER", stateTopic = "" },
    brightness = { commandTopic = "cmnd/g/Dimmer" },
    transition = { commandTopic = "cmnd/g/Speed" },
  },
  optimistic = "Yes",
})
local function grpRun(command, params)
  reset()
  T.capture(function()
    grp:handleProxyCommand(command, params)
  end)
end
grpRun("JOIN_GROUP", { GROUP_ID = "120", KEEP_SYNC = "True" })
T.eq("joining a group sends nothing", #publishes(), 0)
grpRun("GROUP_SET_LEVEL", { GROUP_ID = "120", LEVEL = "60" })
T.eq("a group level is this light's level", published("cmnd/g/Dimmer"), { "60" })
grpRun("GROUP_RAMP_TO_LEVEL", { GROUP_ID = "120", LEVEL = "0", TIME = "2000" })
T.eq("a group ramp to off fades on the device", { published("cmnd/g/Speed")[1], published("cmnd/g/POWER")[1] }, {
  "2",
  "OFF",
})
grp.level = 0
grpRun("GROUP_START_RAMP", { GROUP_ID = "120", RAMP_UP = "True", RATE = "4000" })
T.eq("a group ramp up starts a fade to full", published("cmnd/g/Dimmer"), { "100" })
T.eq("over the whole rate (seconds)", published("cmnd/g/Speed"), { "4" })
grpRun("GROUP_STOP_RAMP", { GROUP_ID = "120" })
T.eq("stopping the group ramp stops this light", #published("cmnd/g/Dimmer"), 1)
grpRun("LEAVE_GROUP", { GROUP_ID = "120" })
T.eq("leaving sends nothing", #publishes(), 0)
T.eq("group commands are handled", grp:handleProxyCommand("SET_GROUP_SYNC", { GROUP_ID = "120" }), true)

T.finish()
