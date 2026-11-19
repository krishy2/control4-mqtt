-- Tests for the MQTT Light's Advanced Lighting Scenes (PUSH_SCENE, ACTIVATE_SCENE,
-- scene ramps, delays, flash) and on modes (Default On, Previous On, Dim-To-Warm,
-- the Daylight Agent's preset), in src/mqtt/light.lua.
--
-- Run from the repo root:
--   make test

local T = require("testlib")

require("c4_shim")
require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

local Color = require("mqtt.color")
local MqttLight = require("mqtt.light")

local PROXY, BROKER = 5001, 5002

local sent = {}
SendToProxy = function(binding, command, params)
  sent[#sent + 1] = { binding = binding, command = command, params = params or {} }
end
local function reset()
  sent = {}
end
local function levels()
  local out = {}
  for _, m in ipairs(sent) do
    if m.binding == BROKER and m.command == "PUBLISH" and m.params.topic == "dim/set" then
      out[#out + 1] = tonumber(m.params.payload)
    end
  end
  return out
end
local function cts()
  local out = {}
  for _, m in ipairs(sent) do
    if m.binding == BROKER and m.command == "PUBLISH" and m.params.topic == "ct/set" then
      out[#out + 1] = tonumber(m.params.payload)
    end
  end
  return out
end
local function notifies(command)
  local out = {}
  for _, m in ipairs(sent) do
    if m.binding == PROXY and m.command == command then
      out[#out + 1] = m.params
    end
  end
  return out
end
local function last(t)
  return t[#t]
end

-- Fire timers until none is left (a scene's steps each arm the next).
local function run()
  for _ = 1, 30 do
    ShimFireTimers()
  end
end

local clock = 0
local saved
local function newLight()
  local light = MqttLight.new({
    proxyBinding = PROXY,
    brokerBinding = BROKER,
    now = function()
      return clock
    end,
    onSettingsChanged = function(s)
      saved = s
    end,
  })
  -- Optimistic, command-only dimmer with color temperature (Kelvin) that fades by itself
  light:configure({
    mode = MqttLight.MODE_TOPICS,
    optimistic = "Yes",
    brightnessMax = 100,
    colorTempUnit = "Kelvin",
    colorTempMin = 2000,
    colorTempMax = 6500,
    topics = {
      brightness = { commandTopic = "dim/set" },
      colorTemp = { commandTopic = "ct/set" },
      -- The light fades by itself: each step is one command.
      transition = { commandTopic = "fade/set" },
    },
  })
  return light
end
local function cmd(light, command, params)
  light:handleProxyCommand(command, params or {})
  run()
end
local function xyOf(kelvin)
  local x, y = Color.cctToXy(kelvin)
  return x, y
end

-------------------------------------------------------------------------------
T.section("driver.xml: full Advanced Lighting Scene support and on modes")
-------------------------------------------------------------------------------
local xml = assert(io.open("drivers/cp_mqtt_light/driver.xml")):read("*a")
for cap, want in pairs({
  advanced_scene_support = "true",
  reduced_als_support = "false",
  brightness_on_mode_preset = "true",
  brightness_on_mode_previous = "true",
  color_on_mode_preset = "true",
  color_on_mode_previous = "true",
  color_on_mode_fade = "true",
}) do
  T.eq(cap, xml:match("<" .. cap .. ">(%a+)</" .. cap .. ">"), want)
end

-------------------------------------------------------------------------------
T.section("Scene elements")
-------------------------------------------------------------------------------
local x2700, y2700 = xyOf(2700)
local ELEMENTS = "<element><delay>0</delay><rate>1000</rate><brightnessEnabled>true</brightnessEnabled>"
  .. "<brightness>80</brightness><colorEnabled>false</colorEnabled></element>"
  .. "<element><delay>5000</delay><rate>2000</rate><brightnessEnabled>true</brightnessEnabled>"
  .. "<brightness>30</brightness><colorEnabled>true</colorEnabled><colorX>"
  .. x2700
  .. "</colorX><colorY>"
  .. y2700
  .. "</colorY><colorMode>1</colorMode></element>"
local steps = MqttLight.parseSceneElements(ELEMENTS)
T.eq("two steps", #steps, 2)
T.eq("first: 80% over 1 s", { steps[1].level, steps[1].brightnessRate, steps[1].delay, steps[1].colorEnabled }, {
  80,
  1000,
  0,
  false,
})
T.eq("second: after 5 s, 30% and 2700 K over 2 s", {
  steps[2].delay,
  steps[2].level,
  steps[2].colorEnabled,
  steps[2].mode,
  steps[2].colorRate,
}, { 5000, 30, true, 1, 2000 })
T.eq("one element alone", #MqttLight.parseSceneElements("<element><level>50</level></element>"), 1)
T.eq(
  "an older layout (level, no flags) sets the level",
  MqttLight.parseSceneElements("<element><level>50</level></element>")[1].levelEnabled,
  true
)
T.eq("no elements", #MqttLight.parseSceneElements(""), 0)
T.eq("an element setting nothing is dropped", #MqttLight.parseSceneElements("<element><delay>0</delay></element>"), 0)

-------------------------------------------------------------------------------
T.section("A scene with a delay")
-------------------------------------------------------------------------------
local light = newLight()
cmd(light, "PUSH_SCENE", { SCENE_ID = "7", ELEMENTS = ELEMENTS })
T.eq("the scene is kept with the settings", #saved.scenes["7"].elements, 2)

-- Count what the scene sends, step by step, with the timers it arms.
local timers = {}
local realSetTimer = SetTimer
SetTimer = function(name, delay, fn, ...)
  if tostring(name):find("Scene", 1, true) then
    timers[#timers + 1] = delay
  end
  return realSetTimer(name, delay, fn, ...)
end
reset()
light:handleProxyCommand("ACTIVATE_SCENE", { SCENE_ID = "7" })
T.eq("the first step goes out at once", levels(), { 80 })
T.eq("then waits its fade, 1 s", timers[1], 1000)
ShimFireTimers() -- the first step's fade is over -> the delay starts
T.eq("then the second step's delay, 5 s", timers[2], 5000)
T.eq("nothing more yet", levels(), { 80 })
ShimFireTimers() -- the delay is over
T.eq("the second step's level", last(levels()), 30)
T.check("with its color", #cts() >= 1 and math.abs(last(cts()) - 2700) <= 30, tostring(last(cts())))
SetTimer = realSetTimer
run()
T.eq("the scene ends after its last step", light.sceneRun, nil)

-- Another hand moves the light: the scene's later steps are dropped.
reset()
light:handleProxyCommand("ACTIVATE_SCENE", { SCENE_ID = "7" })
light:handleProxyCommand("SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "55", RATE = "0" })
run()
T.eq("a level from elsewhere ends the scene", levels(), { 80, 55 })

reset()
cmd(light, "ACTIVATE_SCENE", { SCENE_ID = "99" })
T.eq("an unknown scene does nothing", #levels(), 0)

-------------------------------------------------------------------------------
T.section("Scene ramps")
-------------------------------------------------------------------------------
cmd(light, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "20", RATE = "0" })
clock = 0
reset()
light:handleProxyCommand("RAMP_SCENE_UP", { SCENE_ID = "7", RATE = "4000" })
T.eq("ramps toward full", last(notifies("LIGHT_BRIGHTNESS_CHANGING")).LIGHT_BRIGHTNESS_TARGET, 100)
T.eq("over the scene ramp's time", last(notifies("LIGHT_BRIGHTNESS_CHANGING")).RATE, 4000)
clock = 2000
light:handleProxyCommand("STOP_SCENE_RAMP", { SCENE_ID = "7" })
local stopped = last(notifies("LIGHT_BRIGHTNESS_CHANGED")).LIGHT_BRIGHTNESS_CURRENT
T.check("stops part way", stopped > 20 and stopped < 100, tostring(stopped))
reset()
run()
T.eq("no more steps after the stop", #levels(), 0)

cmd(light, "PUSH_SCENE", { SCENE_ID = "8", ELEMENTS = ELEMENTS, IGNORE_RAMP = "true" })
reset()
cmd(light, "RAMP_SCENE_DOWN", { SCENE_ID = "8", RATE = "2000" })
T.eq("a scene that ignores ramps does not ramp", #levels(), 0)

-------------------------------------------------------------------------------
T.section("Flash scenes")
-------------------------------------------------------------------------------
cmd(light, "PUSH_SCENE", {
  SCENE_ID = "9",
  FLASH = "true",
  ELEMENTS = "<element><delay>0</delay><rate>0</rate><brightnessEnabled>true</brightnessEnabled>"
    .. "<brightness>100</brightness></element><element><delay>0</delay><rate>0</rate>"
    .. "<brightnessEnabled>true</brightnessEnabled><brightness>0</brightness></element>",
})
reset()
local ok, err = pcall(cmd, light, "ACTIVATE_SCENE", { SCENE_ID = "9" })
T.check("a flash scene with nothing to wait on runs once, not forever", ok, err)
T.eq("each step once", levels(), { 100, 0 })

cmd(light, "PUSH_SCENE", {
  SCENE_ID = "10",
  FLASH = "true",
  ELEMENTS = "<element><delay>500</delay><brightnessEnabled>true</brightnessEnabled><brightness>100</brightness>"
    .. "</element><element><delay>500</delay><brightnessEnabled>true</brightnessEnabled><brightness>1</brightness>"
    .. "</element>",
})
reset()
light:handleProxyCommand("ACTIVATE_SCENE", { SCENE_ID = "10" })
for _ = 1, 8 do
  ShimFireTimers()
end
T.check("a flash scene with waits starts over", #levels() >= 4, table.concat(levels(), ","))
cmd(light, "DEACTIVATE_SCENE", { SCENE_ID = "10" })
reset()
run()
T.eq("until it is deactivated", #levels(), 0)

cmd(light, "REMOVE_SCENE", { SCENE_ID = "10" })
T.eq("REMOVE_SCENE", saved.scenes["10"], nil)
cmd(light, "CLEAR_ALL_SCENES")
T.eq("CLEAR_ALL_SCENES", next(saved.scenes), nil)

-------------------------------------------------------------------------------
T.section("Brightness On Mode: Preset and Previous")
-------------------------------------------------------------------------------
light = newLight()
cmd(light, "UPDATE_BRIGHTNESS_ON_MODE", { BRIGHTNESS_PRESET_ID = "1", BRIGHTNESS_PRESET_LEVEL = "70" })
reset()
cmd(light, "ON")
T.eq("Preset: On goes to the preset's level", last(levels()), 70)
T.eq("and tells its preset id", last(notifies("LIGHT_BRIGHTNESS_CHANGED")).LIGHT_BRIGHTNESS_CURRENT_PRESET_ID, 1)
cmd(light, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "40", RATE = "0" })
T.eq(
  "a level from elsewhere has no preset",
  last(notifies("LIGHT_BRIGHTNESS_CHANGED")).LIGHT_BRIGHTNESS_CURRENT_PRESET_ID,
  nil
)
cmd(light, "OFF")
cmd(light, "UPDATE_BRIGHTNESS_ON_MODE", { BRIGHTNESS_PRESET_ID = "10", BRIGHTNESS_PRESET_LEVEL = "100" })
reset()
cmd(light, "ON")
T.eq("Previous: On goes back to the last level", last(levels()), 40)
T.eq("telling Previous On's id", last(notifies("LIGHT_BRIGHTNESS_CHANGED")).LIGHT_BRIGHTNESS_CURRENT_PRESET_ID, 10)
cmd(light, "OFF")
reset()
cmd(light, "TOGGLE")
T.eq("Toggle too", last(levels()), 40)

-------------------------------------------------------------------------------
T.section("Color On Mode: the Daylight Agent's preset")
-------------------------------------------------------------------------------
light = newLight()
cmd(light, "OFF")
local dx, dy = xyOf(5000)
cmd(light, "UPDATE_COLOR_ON_MODE", {
  COLOR_PRESET_ID = "3",
  COLOR_PRESET_ORIGIN = "2",
  COLOR_PRESET_COLOR_X = tostring(dx),
  COLOR_PRESET_COLOR_Y = tostring(dy),
  COLOR_PRESET_COLOR_MODE = "1",
  COLOR_FADE_PRESET_ID = "0",
  COLOR_FADE_PRESET_ORIGIN = "0",
})
reset()
cmd(light, "ON")
T.check("On turns on in the preset's color", math.abs((last(cts()) or 0) - 5000) <= 50, tostring(last(cts())))
local col = last(notifies("LIGHT_COLOR_CHANGED"))
T.eq(
  "telling the preset and its origin",
  { col.LIGHT_COLOR_CURRENT_PRESET_ID, col.LIGHT_COLOR_CURRENT_PRESET_ORIGIN },
  {
    3,
    2,
  }
)

-- The agent moves its preset through the day: the lit light follows.
local ex, ey = xyOf(4000)
reset()
cmd(light, "UPDATE_COLOR_ON_MODE", {
  COLOR_PRESET_ID = "3",
  COLOR_PRESET_ORIGIN = "2",
  COLOR_PRESET_COLOR_X = tostring(ex),
  COLOR_PRESET_COLOR_Y = tostring(ey),
  COLOR_PRESET_COLOR_MODE = "1",
})
T.check("the light follows the preset's new color", math.abs((last(cts()) or 0) - 4000) <= 50, tostring(last(cts())))

-- The agent can also send the color with its preset.
local fx, fy = xyOf(3500)
reset()
cmd(light, "SET_COLOR_TARGET", {
  LIGHT_COLOR_TARGET_X = tostring(fx),
  LIGHT_COLOR_TARGET_Y = tostring(fy),
  LIGHT_COLOR_TARGET_MODE = "1",
  LIGHT_COLOR_TARGET_RATE = "0",
  LIGHT_COLOR_TARGET_PRESET_ID = "3",
  LIGHT_COLOR_TARGET_PRESET_ORIGIN = "2",
})
T.check("a color with its preset", math.abs((last(cts()) or 0) - 3500) <= 50, tostring(last(cts())))
T.eq("keeps the preset", last(notifies("LIGHT_COLOR_CHANGED")).LIGHT_COLOR_CURRENT_PRESET_ID, 3)

-- Someone picks a color: the light no longer follows the agent.
local gx, gy = xyOf(2700)
cmd(light, "SET_COLOR_TARGET", {
  LIGHT_COLOR_TARGET_X = tostring(gx),
  LIGHT_COLOR_TARGET_Y = tostring(gy),
  LIGHT_COLOR_TARGET_MODE = "1",
  LIGHT_COLOR_TARGET_RATE = "0",
})
T.eq("a color picked by hand has no preset", last(notifies("LIGHT_COLOR_CHANGED")).LIGHT_COLOR_CURRENT_PRESET_ID, nil)
reset()
cmd(light, "UPDATE_COLOR_ON_MODE", {
  COLOR_PRESET_ID = "3",
  COLOR_PRESET_ORIGIN = "2",
  COLOR_PRESET_COLOR_X = tostring(dx),
  COLOR_PRESET_COLOR_Y = tostring(dy),
  COLOR_PRESET_COLOR_MODE = "1",
})
T.eq("and stays in its color when the preset moves", #cts(), 0)

-- A preset named by its id alone.
reset()
cmd(light, "SET_COLOR_TARGET", { LIGHT_COLOR_TARGET_PRESET_ID = "3", LIGHT_COLOR_TARGET_PRESET_ORIGIN = "2" })
T.check("a preset by id uses its known color", math.abs((last(cts()) or 0) - 5000) <= 50, tostring(last(cts())))

-------------------------------------------------------------------------------
T.section("Color On Mode: Previous and Fade (Dim-To-Warm)")
-------------------------------------------------------------------------------
light = newLight()
local px, py = xyOf(3000)
cmd(light, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "60", RATE = "0" })
cmd(light, "SET_COLOR_TARGET", {
  LIGHT_COLOR_TARGET_X = tostring(px),
  LIGHT_COLOR_TARGET_Y = tostring(py),
  LIGHT_COLOR_TARGET_MODE = "1",
  LIGHT_COLOR_TARGET_RATE = "0",
})
cmd(light, "OFF")
cmd(light, "UPDATE_COLOR_ON_MODE", {
  COLOR_PRESET_ID = "10",
  COLOR_PRESET_ORIGIN = "1",
  COLOR_FADE_PRESET_ID = "0",
  COLOR_FADE_PRESET_ORIGIN = "0",
})
reset()
cmd(light, "ON")
T.check("Previous: on in the color it went off in", math.abs((last(cts()) or 0) - 3000) <= 50, tostring(last(cts())))

light = newLight()
local onx, ony = xyOf(4000)
local dimx, dimy = xyOf(2200)
cmd(light, "UPDATE_BRIGHTNESS_ON_MODE", { BRIGHTNESS_PRESET_ID = "1", BRIGHTNESS_PRESET_LEVEL = "100" })
cmd(light, "UPDATE_COLOR_ON_MODE", {
  COLOR_PRESET_ID = "1",
  COLOR_PRESET_ORIGIN = "1",
  COLOR_PRESET_COLOR_X = tostring(onx),
  COLOR_PRESET_COLOR_Y = tostring(ony),
  COLOR_PRESET_COLOR_MODE = "1",
  COLOR_FADE_PRESET_ID = "2",
  COLOR_FADE_PRESET_ORIGIN = "1",
  COLOR_FADE_PRESET_COLOR_X = tostring(dimx),
  COLOR_FADE_PRESET_COLOR_Y = tostring(dimy),
  COLOR_FADE_PRESET_COLOR_MODE = "1",
})
cmd(light, "OFF")
reset()
cmd(light, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "10", RATE = "0" })
local warm = last(cts()) or 0
T.check("Fade: dimmed low is warm", warm < 2600 and warm >= 2200, tostring(warm))
reset()
cmd(light, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "100", RATE = "0" })
T.check("at the on level it is the On color", math.abs((last(cts()) or 0) - 4000) <= 50, tostring(last(cts())))

-------------------------------------------------------------------------------
T.section("The proxy's setup (GET_SETUP)")
-------------------------------------------------------------------------------
light = newLight()
local SETUP = "<setup><light_brightness_on_mode_preset_id>1</light_brightness_on_mode_preset_id>"
  .. "<light_brightness_rate_default>750</light_brightness_rate_default>"
  .. "<light_color_on_mode_preset_id>3</light_color_on_mode_preset_id>"
  .. "<light_color_on_mode_preset_origin>2</light_color_on_mode_preset_origin>"
  .. "<light_color_on_mode_fade_preset_id>0</light_color_on_mode_fade_preset_id>"
  .. "<light_color_on_mode_fade_preset_origin>0</light_color_on_mode_fade_preset_origin>"
  .. "<light_color_rate_default>500</light_color_rate_default>"
  .. '<brightnesses><level name="On" id="1" level="65"/><level name="Off" id="2" level="0"/>'
  .. '<level name="Previous On" id="10" level="100"/></brightnesses>'
  .. '<colors><color name="Daylight" id="3" origin="2" color_x="'
  .. dx
  .. '" color_y="'
  .. dy
  .. '" color_mode="1"/>'
  .. '<color name="On Color" id="1" origin="1" color_x="0.42" color_y="0.39" color_mode="1"/></colors></setup>'
T.eq("the setup is read", light:readSetup(SETUP), true)
T.eq("on level and default rates", {
  light.settings.onLevel,
  light.settings.brightnessRateDefault,
  light.settings.colorRateDefault,
}, { 65, 750, 500 })
T.eq("the color on mode's preset with its color", {
  light.settings.colorOnMode.on.id,
  light.settings.colorOnMode.on.origin,
  light.settings.colorOnMode.on.x ~= nil,
}, { 3, 2, true })
T.eq("an answer that cannot be read changes nothing", light:readSetup("not xml <"), false)

T.finish()
