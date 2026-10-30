-- Tests for the PI Thermostat: the controller (full power, PI, learning,
-- auto-tune), the time-proportional valves, the Extras/Message/preset text,
-- and the driver end to end in the C4 shim.
--
-- Run from the repo root:
--   make test
-- or:
--   ./test/run_test.sh test_pi_thermostat.lua

local T = require("testlib")
require("c4_shim")
require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")
JSON = JSON or require("JSON")

local Controller = require("pi_thermostat.controller")
local Autotune = require("pi_thermostat.autotune")
local Valves = require("pi_thermostat.valves")
local Ui = require("pi_thermostat.ui")

local function near(a, b, tol)
  return type(a) == "number" and math.abs(a - b) <= (tol or 1e-6)
end

local function input(t, mode, heat, cool, ok)
  return { temperature = t, sensorOk = ok ~= false, mode = mode, heatSetpoint = heat or 21, coolSetpoint = cool or 24 }
end

-------------------------------------------------------------------------------
T.section("Valve setups and modes")
-------------------------------------------------------------------------------
local c = Controller.new()
c:configure({ valveCount = 2 })
T.eq("2 valves: Off, Heat, Cool, Auto", c:modes(), { "Off", "Heat", "Cool", "Auto" })
c:configure({ valveCount = 1, singleValveUse = "Heat" })
T.eq("1 valve, heat only", c:modes(), { "Off", "Heat" })
c:configure({ valveCount = 1, singleValveUse = "Cool" })
T.eq("1 valve, cool only", c:modes(), { "Off", "Cool" })
c:configure({ valveCount = 1, singleValveUse = "Changeover" })
T.eq("1 changeover valve: the mode says which water, no Auto", c:modes(), { "Off", "Heat", "Cool" })
T.eq("changeover serves both sides", c:sides(), { heat = true, cool = true })
c:configure({ valveCount = 1, singleValveUse = "Heat" })
local r = c:update(0, input(15, "Cool"))
T.eq("a mode the setup cannot do runs nothing", r.state, "off")

-------------------------------------------------------------------------------
T.section("Full power above 5 °C, PI below 4.5 °C")
-------------------------------------------------------------------------------
local events = {}
c = Controller.new({
  onEvent = function(name)
    events[#events + 1] = name
  end,
})
c:configure({ valveCount = 2, learning = false })
c:setGains("heat", 10, 1800, "manual")
r = c:update(0, input(15.5, "Heat", 21))
T.eq("5.5 °C below: full heating", { r.state, r.side, r.output, r.heat, r.cool }, { "full", "heat", 100, 100, 0 })
T.eq("event", events[1], "full_started")
r = c:update(10, input(16.2, "Heat", 21))
T.eq("4.8 °C: still full (hysteresis)", r.state, "full")
r = c:update(20, input(16.6, "Heat", 21))
T.eq("4.4 °C: PI takes over", r.state, "pi")
T.check("bumpless: it starts at 100 %", near(r.output, 100, 0.01), tostring(r.output))
T.check(
  "the integral holds the rest (100 - Kp e)",
  near(c.integral.heat, 100 - 10 * 4.4, 0.05),
  tostring(c.integral.heat)
)
r = c:update(30, input(20.5, "Heat", 21))
T.check("near the setpoint the output drops", r.output < 100 and r.output > 0, tostring(r.output))

c = Controller.new()
c:configure({ valveCount = 2, learning = false })
r = c:update(0, input(30, "Cool", 21, 24))
T.eq(
  "cooling: 6 °C above the cool setpoint is full cooling",
  { r.state, r.side, r.cool, r.heat },
  { "full", "cool", 100, 0 }
)
T.check("the error is positive for cooling", near(r.error, 6))

c = Controller.new()
c:configure({ valveCount = 2, fullThreshold = 3, fullRelease = 1, learning = false })
r = c:update(0, input(17.5, "Heat", 21))
T.eq("the threshold is a setting", r.state, "full")
r = c:update(10, input(18.5, "Heat", 21))
T.eq("so is the release", r.state, "full")
r = c:update(20, input(19.1, "Heat", 21))
T.eq("below threshold - release: PI", r.state, "pi")

-------------------------------------------------------------------------------
T.section("PI, anti-windup, Auto")
-------------------------------------------------------------------------------
c = Controller.new()
c:configure({ valveCount = 2, learning = false })
c:setGains("heat", 40, 600, "manual")
for k = 0, 200 do
  c:update(k * 10, input(18, "Heat", 21)) -- 3 °C below, saturated
end
T.check("no wind-up past 100 %", c.integral.heat <= 100)
r = c:update(2020, input(21.5, "Heat", 21))
T.check("over the setpoint the output falls at once", r.output < 100, tostring(r.output))
c.integral.heat = 30
r = c:update(2030, input(21, "Heat", 21))
T.check("at the setpoint the output is the integral", near(r.output, 30, 0.01), tostring(r.output))

c = Controller.new()
c:configure({ valveCount = 2, learning = false })
r = c:update(0, input(20, "Auto", 21, 24))
T.eq("Auto below the heat setpoint heats", r.side, "heat")
r = c:update(10, input(22, "Auto", 21, 24))
T.eq("between the setpoints the last side winds down", { r.side, r.state }, { "heat", "idle" })
r = c:update(20, input(25, "Auto", 21, 24))
T.eq("above the cool setpoint cools", r.side, "cool")
T.eq("and the heat integral is forgotten", c.integral.heat, 0)

r = c:update(30, input(25, "Auto", 21, 24, false))
T.eq("no temperature: valves closed", { r.state, r.output, r.heat, r.cool }, { "sensor", 0, 0, 0 })
r = c:update(40, input(25, "Off", 21, 24))
T.eq("Off", { r.state, r.output }, { "off", 0 })

-------------------------------------------------------------------------------
T.section("Learning")
-------------------------------------------------------------------------------
-- Overshoot: start 1 °C below, swing 1 °C past, settle.
local learned = {}
c = Controller.new({
  onEvent = function(name, side, detail)
    if name == "learned" then
      learned[#learned + 1] = detail
    end
  end,
})
c:configure({ valveCount = 2, learning = true })
local tnow = 0
local function run(temps, step)
  for _, temp in ipairs(temps) do
    c:update(tnow, input(temp, "Heat", 21))
    tnow = tnow + (step or 60)
  end
end
run({ 20, 20.5, 21, 21.5, 22, 21.8, 21.2 })
for _ = 1, 40 do
  run({ 21 })
end
T.eq("an overshoot episode", learned[1], "overshoot")
T.check("Kp went down", c.gains.heat.kp < Controller.DEFAULT_KP, tostring(c.gains.heat.kp))
T.check("Ti went up", c.gains.heat.ti > Controller.DEFAULT_TI, tostring(c.gains.heat.ti))
T.eq("source and count", { c.gains.heat.source, c.gains.heat.learned }, { "learned", 1 })

-- Slow: 1 °C below for the whole episode with a part-open valve.
learned = {}
c = Controller.new({
  onEvent = function(name, _, detail)
    if name == "learned" then
      learned[#learned + 1] = detail
    end
  end,
})
c:configure({ valveCount = 2, learning = true })
c:setGains("heat", 5, 14400, "manual")
tnow = 0
for _ = 1, 6 * 60 + 5 do
  c:update(tnow, input(20, "Heat", 21))
  tnow = tnow + 600
  if #learned > 0 then
    break
  end
end
T.eq("never reaching the setpoint is slow", learned[1], "slow")
T.check("Kp went up", c.gains.heat.kp > 5, tostring(c.gains.heat.kp))

-- A setpoint step aborts the episode
c = Controller.new()
c:configure({ valveCount = 2, learning = true })
c:update(0, input(20, "Heat", 21))
T.check("an episode starts", c.episode ~= nil)
c:update(60, input(20, "Heat", 22))
T.eq("a setpoint step restarts it", c.episode and c.episode.start, 60)

c = Controller.new()
c:configure({ valveCount = 2, learning = false })
c:update(0, input(20, "Heat", 21))
T.eq("Self-Learning off: no episodes", c.episode, nil)

c = Controller.new()
c:configure({ valveCount = 2, learning = true })
for k = 0, 2000 do
  c:update(k * 600, input(23, "Heat", 21, 25))
end
T.eq(
  "a room warm from the sun (valve closed) teaches nothing",
  { c.gains.heat.kp, c.gains.heat.learned },
  { Controller.DEFAULT_KP, 0 }
)

-------------------------------------------------------------------------------
T.section("Gains: limits, Response, saving")
-------------------------------------------------------------------------------
c = Controller.new()
c:setGains("heat", 1000, 1, "manual")
T.eq("clamped", { c.gains.heat.kp, c.gains.heat.ti }, { Controller.KP_MAX, Controller.TI_MIN })
c:setGains("heat", 20, 900, "manual")
c:configure({ response = "Fast" })
T.eq("Response Fast multiplies Kp", { c:effectiveGains("heat") }, { 30, 900 })
c:configure({ response = "Slow" })
T.check("Response Slow", near(c:effectiveGains("heat"), 12))
c.integral.heat = 42.5
local snap = c:snapshot()
local c2 = Controller.new()
c2:restore(snap)
T.eq("gains survive a restart", { c2.gains.heat.kp, c2.gains.heat.ti, c2.gains.heat.source }, { 20, 900, "manual" })
T.eq("the integral too", c2.integral.heat, 42.5)
c2:restore({ gains = { heat = { kp = "x" } } })
T.eq("garbage restores to defaults", c2.gains.heat.kp, Controller.DEFAULT_KP)
c2:resetGains()
T.eq("reset", { c2.gains.cool.kp, c2.gains.cool.source }, { Controller.DEFAULT_KP, "default" })

-------------------------------------------------------------------------------
T.section("Auto-tune")
-------------------------------------------------------------------------------
-- A room that swings 0.5 °C around the setpoint every hour
local tune = Autotune.new("heat", 0, { hysteresis = 0.2 })
local done, res, k = false, nil, 0
while not done and k < 2000 do
  local e = 0.5 * math.sin(2 * math.pi * k * 60 / 3600)
  local out
  out, done, res = tune:step(k * 60, e)
  T.check("relay output", out == 0 or out == 100)
  k = k + 1
end
T.check("it finishes", done and res ~= nil and res.kp ~= nil, res and res.reason)
T.check("period ~ 1 h", near(res.pu, 3600, 120), tostring(res.pu))
T.check("amplitude ~ 0.5 °C", near(res.amplitude, 0.5, 0.02), tostring(res.amplitude))
T.check("Kp = Ku / 3.2", near(res.kp, res.ku / 3.2))
T.check("Ti = 2.2 Pu", near(res.ti, 2.2 * res.pu))

tune = Autotune.new("heat", 0, { hysteresis = 0.2, maxDuration = 3600 })
local _, d2, res2 = tune:step(4000, 1)
T.check("gives up after the limit", d2 and res2.reason ~= nil)

local ev = {}
c = Controller.new({
  onEvent = function(name)
    ev[#ev + 1] = name
  end,
})
c:configure({ valveCount = 1, singleValveUse = "Heat", learning = false })
T.eq("no cooling tune on a heat-only valve", select(2, c:startAutotune("cool", 0)) ~= nil, true)
T.check("heating tune starts", c:startAutotune("heat", 0))
r = c:update(0, input(15, "Heat", 21))
T.eq("the tune overrides full power", r.state, "autotune")
T.eq("valve open below the setpoint", r.heat, 100)
r = c:update(10, input(15, "Off", 21))
T.eq("Off stops it", c.autotune, nil)
T.eq("with an event", ev[#ev], "autotune_failed")

-- Tune to the end in a simulated room, then PI with the new gains
c = Controller.new()
c:configure({ valveCount = 2, learning = false })
c:startAutotune("heat", 0)
local temp, lag = 20, 0
for step = 0, 6 * 360 do
  local rr = c:update(step * 10, input(temp, "Heat", 21))
  lag = lag + ((rr.heat or 0) / 100 - lag) * 10 / 900
  temp = temp + ((5 - temp) / 10800 + lag * 30 / 10800) * 10
  if c.autotune == nil then
    break
  end
end
T.eq("the tune ends", c.autotune, nil)
T.eq("with tuned heating gains", c.gains.heat.source, "tuned")

-------------------------------------------------------------------------------
T.section("Time-proportional valves")
-------------------------------------------------------------------------------
local v = Valves.new()
v:configure({ cycle = 600, minTime = 120 })
T.eq("60 % of 10 min", v:openTime(60), 360)
T.eq("too short to open: 0", v:openTime(5), 0)
T.eq("short but more than half the minimum: the minimum", v:openTime(15), 120)
T.eq("almost always open: closed for the minimum", v:openTime(85), 480)
T.eq("almost 100 %: open", v:openTime(95), 600)
local open = v:update(0, { heat = 60, cool = 0 })
T.eq("opens at the cycle start", open, { heat = true, cool = false })
open = v:update(350, { heat = 60, cool = 0 })
T.eq("still open at 350 s", open.heat, true)
open = v:update(370, { heat = 60, cool = 0 })
T.eq("closed after 360 s", open.heat, false)
open = v:update(600, { heat = 60, cool = 0 })
T.eq("the next cycle opens again", open.heat, true)
open = v:update(650, { heat = 0, cool = 0 })
T.eq("no demand, but held for the minimum time", open.heat, true)
open = v:update(650, { heat = 0, cool = 0 }, true)
T.eq("an immediate close ignores it", open.heat, false)
open = v:update(700, { heat = 0, cool = 40 })
T.eq("demand from zero starts a cycle at once", open.cool, true)

-------------------------------------------------------------------------------
T.section("Extras, presets, message")
-------------------------------------------------------------------------------
local s = Ui.normalizeSettings(nil)
T.eq(
  "defaults",
  { s.response, s.learning, s.full_threshold, s.full_release, s.cycle_time, s.min_valve_time, s.sensor_timeout },
  { "Normal", true, 5, 0.5, 10, 2, 15 }
)
T.eq("an off-list value falls back", Ui.normalizeSettings({ full_threshold = 4.2 }).full_threshold, 5)
T.eq("list value", Ui.parseCommand("PI_FULL_THRESHOLD", { value = "6.5" }), { setting = "full_threshold", value = 6.5 })
T.eq("checkbox", Ui.parseCommand("PI_LEARNING", { value = "False" }), { setting = "learning", value = false })
T.eq("upper-case VALUE", Ui.parseCommand("PI_RESPONSE", { VALUE = "Fast" }), { setting = "response", value = "Fast" })
T.eq("invalid", Ui.parseCommand("PI_CYCLE_TIME", { value = "7" }).invalid, true)
T.eq("button", Ui.parseCommand("PI_TUNE_HEAT", {}), { button = "tune_heat" })
T.eq("not ours", Ui.parseCommand("SET_MODE_HVAC", { MODE = "Heat" }), nil)
local setup = Ui.extrasSetup(s, { heat = true, cool = false })
T.contains("setup has the threshold list", setup, 'command="PI_FULL_THRESHOLD" value="5"')
T.contains("its items", setup, '<item text="6.5 °C" value="6.5"/>')
T.contains("checkbox value", setup, 'type="checkbox" id="learning"')
T.contains("heat tune button", setup, 'command="PI_TUNE_HEAT"')
T.excludes("no cool tune without cooling", setup, "PI_TUNE_COOL")
T.contains("state", Ui.extrasState(s), '<object id="cycle_time" value="10"/>')
T.check("the setup is well-formed XML", pcall(C4.ParseXml, C4, setup))

local fields = Ui.presetFields({ "Off", "Heat", "Cool", "Auto" }, { min = 5, max = 35, minF = 41, maxF = 95 })
T.contains("preset mode list", fields, '<item text="Auto" value="Auto"/>')
T.contains("preset heat setpoint", fields, 'id="heat_setpoint_c" type="number" label="Heat Setpoint" min="5" max="35"')
local onlyHeat = Ui.presetFields({ "Off", "Heat" }, { min = 5, max = 35, minF = 41, maxF = 95 })
T.excludes("no cool setpoint without cooling", onlyHeat, "cool_setpoint")
local parsed = Ui.parsePresets(
  '<presets><preset name="Away"><preset_fields><field id="hvac_mode" value="Heat"/>'
    .. '<field id="heat_setpoint_f" value="59"/></preset_fields></preset></presets>'
)
T.eq("presets from the proxy", parsed.Away.hvac_mode, "Heat")
local ch = Ui.presetChanges(parsed.Away)
T.check("°F setpoints become °C", near(ch.heat, 15), tostring(ch.heat))
T.eq("mode", ch.mode, "Heat")
ch = Ui.presetChanges({ auto_setpoints_c = "20,25" })
T.eq("auto setpoints", { ch.heat, ch.cool }, { 20, 25 })

local msg = Ui.message(
  { state = "full", side = "heat", error = 6.24, output = 100, kp = 30, ti = 1800 },
  { valveCount = 2, valves = { heat = true }, gains = { heat = { kp = 30, ti = 1800, source = "default" } } }
)
T.eq(
  "message",
  msg,
  "Full heating: 6.2 °C below setpoint\nKp 30 %/°C, Ti 30 min (default)\nHeat valve open, cool valve closed"
)
msg = Ui.message(
  { state = "pi", side = "cool", error = -0.31, output = 42.4, p = -9.3, i = 51.7, kp = 30, ti = 1500 },
  {
    scale = "F",
    valveCount = 1,
    valves = { cool = true },
    gains = { cool = { kp = 30, ti = 1500, source = "learned", learned = 3 } },
  }
)
T.eq(
  "PI message in °F, one valve",
  msg,
  "PI cooling: 42 %\nKp 30 %/°C, Ti 25 min (learned, 3 adjustments)\nP -9 % + I 52 %, deviation -0.6 °F\nValve open"
)
T.eq(
  "sensor message",
  Ui.message({ state = "sensor" }, { valveCount = 2 }):match("^[^\n]*"),
  "No temperature reading: valves closed"
)

-------------------------------------------------------------------------------
T.section("The driver")
-------------------------------------------------------------------------------
local sent = {}
C4.SendToProxy = function(_, binding, command, params)
  sent[#sent + 1] = { binding = binding, command = command, params = params or {} }
end
local fired = {}
C4.FireEvent = function(_, name)
  fired[#fired + 1] = name
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
local function relays()
  local out = {}
  for _, m in ipairs(sent) do
    if m.binding == 2 or m.binding == 3 then
      out[#out + 1] = m.binding .. "=" .. m.command
    end
  end
  return out
end
local realTime = os.time
local clock = 1800000000
os.time = function(t)
  if t ~= nil then
    return realTime(t)
  end
  return clock
end

local realGetDriverConfigInfo = C4.GetDriverConfigInfo
C4.GetDriverConfigInfo = function(c4, section)
  if section == "minimum_os_version" then
    return "3.3.0"
  end
  return realGetDriverConfigInfo(c4, section)
end
local xml = assert(io.open("drivers/cp_pi_thermostat/driver.xml")):read("*a")
T.contains("thermostatV2 proxy", xml, ">thermostatV2</proxy>")
T.excludes("no MQTT broker connection", xml, "CP_MQTT_BROKER")
T.contains("a temperature input", xml, "<classname>TEMPERATURE_VALUE</classname>")
T.contains("relay outputs", xml, "<classname>RELAY</classname>")
for block in xml:gmatch("<property>(.-)</property>") do
  Properties[block:match("<name>(.-)</name>")] = block:match("<default>(.-)</default>") or ""
end
Properties["Log Level"] = "2 - Warning"
ShimSetDevices({
  [12345] = { deviceName = "PI Thermostat", driverFileName = "cp_pi_thermostat.c4z" },
  [700] = { deviceName = "Room Sensor", driverFileName = "sensor.c4z" },
  [800] = { deviceName = "Relays", driverFileName = "relays.c4z" },
})
C4:Bind(700, 10, 12345, 1, "TEMPERATURE_VALUE")
C4:Bind(800, 1, 12345, 2, "RELAY")
C4:Bind(800, 2, 12345, 3, "RELAY")

local ok, err = T.capture(function()
  dofile("drivers/cp_pi_thermostat/driver.lua")
  OnDriverInit()
  OnDriverLateInit()
end)
T.check("the driver starts", ok, err)
T.eq("modes", last(take("ALLOWED_HVAC_MODES_CHANGED")).MODES, "Off,Heat,Cool,Auto")
T.eq("extras", last(take("DYNAMIC_CAPABILITIES_CHANGED")).HAS_EXTRAS, "true")
T.contains("extras setup sent", last(take("EXTRAS_SETUP_CHANGED")).XML, "PI_RESPONSE")
T.contains("preset fields sent", last(take("PRESET_FIELDS_CHANGED")).XML, "heat_setpoint_c")
T.eq("starts Off", last(take("HVAC_MODE_CHANGED")).MODE, "Off")
local startRelays = {}
for _, x in ipairs(relays()) do
  startRelays[x] = true
end
T.eq("valves closed at start (relay opened)", startRelays, { ["2=OPEN"] = true, ["3=OPEN"] = true })
T.capture(function()
  ShimFireTimers() -- the proxy-ready resend
end)
T.eq("asks the sensor", #take("GET_SENSOR_VALUE", 1) >= 1, true)
T.contains("message", last(take("MESSAGE_CHANGED")).MESSAGE, "Off: valves closed")

sent = {}
T.capture(function()
  ReceivedFromProxy(1, "VALUE_CHANGED", { CELSIUS = "15.0", FAHRENHEIT = "59", TIMESTAMP = "1" })
  ReceivedFromProxy(5001, "SET_MODE_HVAC", { MODE = "Heat" })
end)
T.eq("temperature reaches the proxy", last(take("TEMPERATURE_CHANGED")).TEMPERATURE, "15")
T.eq("mode Heat", last(take("HVAC_MODE_CHANGED")).MODE, "Heat")
T.eq("6 °C below 21: heat valve opens", relays(), { "2=CLOSE" })
T.eq("Heating", last(take("HVAC_STATE_CHANGED")).STATE, "Heating")
T.contains("full heating message", last(take("MESSAGE_CHANGED")).MESSAGE, "Full heating: 6 °C below setpoint")
T.eq("event", fired[#fired], "Full Power Started")

sent = {}
T.capture(function()
  ReceivedFromProxy(5001, "SET_SETPOINT_COOL", { CELSIUS = "21.5", FAHRENHEIT = "71" })
end)
T.eq("the deadband pushes the heat setpoint down", last(take("HEAT_SETPOINT_CHANGED")).SETPOINT, "20.5")
T.eq("cool setpoint", last(take("COOL_SETPOINT_CHANGED")).SETPOINT, "21.5")
sent = {}
T.capture(function()
  ReceivedFromProxy(5001, "INC_SETPOINT_HEAT", {})
end)
T.eq(
  "increment by 0.5 °C pushes cool up",
  { last(take("HEAT_SETPOINT_CHANGED")).SETPOINT, last(take("COOL_SETPOINT_CHANGED")).SETPOINT },
  { "21", "22" }
)

sent = {}
T.capture(function()
  ReceivedFromProxy(1, "VALUE_CHANGED", { CELSIUS = "20.5" })
end)
T.eq("near the setpoint: PI", Properties["Controller State"] ~= nil, true)
T.contains("PI message", last(take("MESSAGE_CHANGED")).MESSAGE, "PI heating")

-- Extras: a setting
sent = {}
T.capture(function()
  ReceivedFromProxy(5001, "PI_CYCLE_TIME", { value = "5" })
end)
T.contains(
  "the new value goes back to the UI",
  last(take("EXTRAS_STATE_CHANGED")).XML,
  '<object id="cycle_time" value="5"/>'
)
T.eq("and is saved", Deserialize(C4:PersistGetValue("Settings")).cycle_time, 5)

-- Sensor timeout: valves close
sent = {}
clock = clock + 16 * 60
T.capture(function()
  ShimFireTimers()
end)
T.eq("no reading for 16 min: valves closed", relays(), { "2=OPEN" })
T.eq("event", fired[#fired], "Sensor Lost")
T.contains("message says so", last(take("MESSAGE_CHANGED")).MESSAGE, "No temperature reading")
sent = {}
T.capture(function()
  ReceivedFromProxy(1, "VALUE_CHANGED", { CELSIUS = "20.0" })
end)
T.eq("reading back", fired[#fired], "Sensor Restored")

-- Presets: the proxy's list, then one runs
sent = {}
T.capture(function()
  ReceivedFromProxy(5001, "SET_PRESETS", {
    XML = '<presets><preset name="Night"><preset_fields><field id="hvac_mode" value="Heat"/>'
      .. '<field id="heat_setpoint_c" value="18"/></preset_fields></preset></presets>',
  })
  ReceivedFromProxy(5001, "SET_PRESET", { NAME = "Night" })
end)
T.eq("preset setpoint", last(take("HEAT_SETPOINT_CHANGED")).SETPOINT, "18")
T.eq("preset name", last(take("PRESET_CHANGED")).NAME, "Night")

-- Extras: auto-tune button
sent = {}
T.capture(function()
  ReceivedFromProxy(5001, "PI_TUNE_HEAT", {})
end)
T.contains("auto-tune message", last(take("MESSAGE_CHANGED")).MESSAGE, "Auto-tune heating")
T.capture(function()
  ReceivedFromProxy(5001, "PI_TUNE_STOP", {})
end)
T.eq("stopped", fired[#fired], "Auto-Tune Failed")

-- Manual gains from a property
Properties["Heating Kp"] = "45"
Properties["Heating Ti"] = "20"
T.capture(function()
  OnPropertyChanged("Heating Kp")
end)
local savedController = Deserialize(C4:PersistGetValue("Controller"))
T.eq("manual gains are saved at once", { savedController.gains.heat.kp, savedController.gains.heat.ti }, { 45, 1200 })

-- One valve: modes follow, Auto is gone
Properties["Valve Count"] = "1 Valve"
Properties["Single Valve Use"] = "Changeover"
sent = {}
T.capture(function()
  OnPropertyChanged("Valve Count")
end)
T.eq("changeover modes", last(take("ALLOWED_HVAC_MODES_CHANGED")).MODES, "Off,Heat,Cool")

-- Cool mode on the changeover valve drives the bound valve connections
sent = {}
T.capture(function()
  ReceivedFromProxy(5001, "SET_SETPOINT_COOL", { CELSIUS = "22" })
  ReceivedFromProxy(1, "VALUE_CHANGED", { CELSIUS = "28" })
  ReceivedFromProxy(5001, "SET_MODE_HVAC", { MODE = "Cool" })
end)
T.eq("changeover: cooling opens the one valve", relays(), { "2=CLOSE", "3=CLOSE" })
T.eq("Cooling", last(take("HVAC_STATE_CHANGED")).STATE, "Cooling")

-- Restart: everything comes back from disk
sent = {}
T.capture(function()
  require("lib.persist"):flush()
end)
local savedState = Deserialize(C4:PersistGetValue("ThermostatState"))
T.eq("state on disk", { savedState.mode, savedState.cool }, { "Cool", 22 })

os.time = realTime
T.finish()
