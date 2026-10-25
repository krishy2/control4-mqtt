-- Tests for Shelly Gen2+ discovery (src/mqtt/shelly.lua) and the MQTT Light's
-- "Shelly (Gen2+)" payload mode (src/mqtt/light.lua). Payloads follow the
-- Shelly Gen2 API docs: GetDeviceInfo for announces, GetConfig, NotifyStatus
-- and <Type>.Set / <Type>.GetStatus over RPC.
--
-- Run from the repo root:
--   make test
-- or:
--   ./test/run_test.sh test_shelly.lua

local T = require("testlib")
require("c4_shim")
require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")
JSON = JSON or require("JSON")
local Shelly = require("mqtt.shelly")
local MqttLight = require("mqtt.light")

T.section("Announces")
T.eq(
  "prefix from <prefix>/announce",
  Shelly.prefixFrom("shellyplus1-aabbcc/announce", "announce"),
  "shellyplus1-aabbcc"
)
T.eq("deeper prefixes work", Shelly.prefixFrom("home/hall/announce", "announce"), "home/hall")
T.eq("shellies/announce gives none", Shelly.prefixFrom("shellies/announce", "announce"), nil)
T.eq("other topics give none", Shelly.prefixFrom("tele/x/LWT", "announce"), nil)
local info = Shelly.parseAnnounce(
  '{"name":"Hall","id":"shellyplus1pm-a8032ab12345","mac":"A8:03:2A:B1:23:45","slot":0,'
    .. '"model":"SNSW-001P16EU","gen":2,"fw_id":"x","ver":"1.4.4","app":"Plus1PM","auth_en":false}'
)
T.eq(
  "Gen2 device info",
  { info and info.id, info and info.mac, info and info.app, info and info.name },
  { "shellyplus1pm-a8032ab12345", "A8032AB12345", "Plus1PM", "Hall" }
)
T.eq("Gen3 too", Shelly.parseAnnounce('{"id":"shelly1g3-a","mac":"AA","gen":3}') ~= nil, true)
T.eq(
  "Gen1 (no gen field) is ignored",
  Shelly.parseAnnounce('{"id":"shellydimmer2-E8DB","model":"SHDM-2","mac":"E8DB","fw_ver":"x"}'),
  nil
)
T.eq("not JSON", Shelly.parseAnnounce("true"), nil)
local req = JSON:decode(Shelly.configRequest(7))
T.eq("GetConfig request", { req.id, req.src, req.method }, { 7, "control4/shelly", "Shelly.GetConfig" })

T.section("Outputs from the configuration")
local function device(config, name)
  return Shelly.build({
    id = "shellyprodm2pm-aabbccddeeff",
    mac = "AABBCCDDEEFF",
    model = "SPDM-002PE01EU",
    gen = 2,
    ver = "1.4.4",
    name = name,
  }, "shellyprodm2pm-aabbccddeeff", config)
end
local pro = device({
  sys = { device = { name = "Kitchen" } },
  ["light:1"] = { id = 1, name = "Island" },
  ["light:0"] = { id = 0, name = JSON.null },
  ["input:0"] = { id = 0 },
  ["switch:0"] = { id = 0, name = "Fan" },
  ble = {},
})
local loads = Shelly.loads(pro)
local ids = {}
for _, l in ipairs(loads) do
  ids[#ids + 1] = l.id .. "=" .. l.label
end
T.eq("light and relay outputs in order, others left out", ids, {
  "light:0=Dimmer 1",
  "light:1=Dimmer 2 'Island'",
  "switch:0=Relay 'Fan'",
})
T.eq("device name from sys.device.name", pro.name, "Kitchen")
T.eq("names: an output's own name", Shelly.loadName(pro, "light:1"), "Island")
T.eq("names: device name and output", Shelly.loadName(pro, "light:0"), "Kitchen Dimmer 1")
T.eq("names: relay with a name", Shelly.loadName(pro, "switch:0"), "Fan")
T.eq("unknown output", Shelly.loadName(pro, "light:5"), nil)

local single = device({ ["light:0"] = { id = 0 }, sys = { device = { name = JSON.null } } })
T.eq("one output, no names: the device ID", Shelly.loadName(single, "light:0"), "shellyprodm2pm-aabbccddeeff")
local named = device({ ["light:0"] = { id = 0 }, sys = { device = { name = "Hall Lamp" } } })
T.eq("one output: the device name", Shelly.loadName(named, "light:0"), "Hall Lamp")

local duo = device({ ["cct:0"] = { id = 0, ct_range = { 2700, 6500 } } })
local props = Shelly.lightProperties(duo, "cct:0")
T.eq("light settings", {
  props["Payload Mode"],
  props["Shelly Topic Prefix"],
  props["Shelly Component"],
  props["Availability Topic"],
  props["Payload Available"],
  props["State Request Topic"],
}, {
  "Shelly (Gen2+)",
  "shellyprodm2pm-aabbccddeeff",
  "cct:0",
  "shellyprodm2pm-aabbccddeeff/online",
  "true",
  "shellyprodm2pm-aabbccddeeff/rpc",
})
T.eq("CT range from ct_range", { props["Color Temp Min"], props["Color Temp Max"] }, { "2700", "6500" })
local sr = JSON:decode(props["State Request Payload"])
T.eq(
  "state request is CCT.GetStatus answered to the light",
  { sr.method, sr.params.id, sr.src },
  { "CCT.GetStatus", 0, "control4/shellyprodm2pm-aabbccddeeff/cct_0" }
)
T.eq("an unknown output", Shelly.lightProperties(duo, "light:0"), nil)
T.eq("summary for the list", Shelly.summary(pro).loads[3].id, "switch:0")
T.contains("a cover-only device gets a note", table.concat(Shelly.notes(device({ ["cover:0"] = {} })), " "), "No light")

-------------------------------------------------------------------------------
-- The light in Shelly mode
-------------------------------------------------------------------------------
local P = "shellyplusrgbwpm-a0a3b3c4d5e6"
local sent = {}
C4.SendToProxy = function(_, binding, command, params)
  sent[#sent + 1] = { binding = binding, command = command, params = params or {} }
end
local function rpcs()
  local out = {}
  for _, m in ipairs(sent) do
    if m.command == "PUBLISH" then
      local body = JSON:decode(m.params.payload)
      body.topic = m.params.topic
      out[#out + 1] = body
    end
  end
  sent = {}
  return out
end
local function last(list)
  return list[#list]
end
local function notified(command)
  local found
  for _, m in ipairs(sent) do
    if m.command == command then
      found = m.params
    end
  end
  return found
end

local function newLight(component, extra)
  local l = MqttLight.new({ proxyBinding = 5001, brokerBinding = 5002 })
  local cfg = {
    mode = "Shelly (Gen2+)",
    shelly = { prefix = P, component = component },
    colorTempMin = 2700,
    colorTempMax = 6500,
    whiteColorTemp = 4000,
  }
  for k, v in pairs(extra or {}) do
    cfg[k] = v
  end
  l:configure(cfg)
  sent = {}
  return l
end

T.section("Shelly mode: abilities from the output type")
local function caps(component)
  local c = newLight(component).caps
  return { c.dimmer, c.colorTemp, c.color, c.white, c.transition }
end
T.eq("switch: on/off", caps("switch:0"), { false, false, false, false, false })
T.eq("light: dimmer with fades", caps("light:0"), { true, false, false, false, true })
T.eq("cct: dimmer and color temp", caps("cct:0"), { true, true, false, false, true })
T.eq("rgb: dimmer and color", caps("rgb:0"), { true, false, true, false, true })
T.eq("rgbw: dimmer, color and white", caps("rgbw:0"), { true, false, true, true, true })
T.eq(
  "Generic settings are ignored",
  newLight("light:0", { topics = { color = { commandTopic = "x" } } }).caps.color,
  false
)
T.eq("no prefix: just on/off", newLight("").caps.dimmer, false)
local cctLight = newLight("cct:0")
T.eq("cct range", { cctLight.caps.cctMin, cctLight.caps.cctMax }, { 2700, 6500 })
local subs = newLight("light:1"):subscriptions()
T.eq("subscriptions", subs, {
  "control4/" .. P .. "/light_1/rpc",
  P .. "/events/rpc",
  P .. "/status/light:1",
})

T.section("Shelly mode: state")
local dim = newLight("light:0")
dim:onMessage(P .. "/status/light:0", '{"id":0,"source":"init","output":true,"brightness":42}')
T.check("status topic: the proxy hears the level", notified("LIGHT_BRIGHTNESS_CHANGED") ~= nil)
T.eq("level 42", dim.level, 42)
sent = {}
dim:onMessage(
  P .. "/events/rpc",
  '{"src":"'
    .. P
    .. '","dst":"'
    .. P
    .. '/events","method":"NotifyStatus","params":{"ts":1,"light:0":{"id":0,"brightness":60}}}'
)
T.eq("NotifyStatus with only brightness keeps the light on", dim.level, 60)
dim:onMessage(P .. "/events/rpc", '{"method":"NotifyStatus","params":{"ts":2,"light:0":{"id":0,"output":false}}}')
T.eq("NotifyStatus off", dim.level, 0)
dim:onMessage(P .. "/events/rpc", '{"method":"NotifyStatus","params":{"ts":3,"light:1":{"id":1,"output":true}}}')
T.eq("another output's status is not ours", dim.level, 0)
dim:onMessage(P .. "/events/rpc", '{"method":"NotifyEvent","params":{"events":[]}}')
T.eq("events are ignored", dim.level, 0)
dim:onMessage(
  "control4/" .. P .. "/light_0/rpc",
  '{"id":1,"src":"x","dst":"y","result":{"id":0,"output":true,"brightness":15}}'
)
T.eq("a GetStatus answer", dim.level, 15)
T.eq("another topic is not handled", dim:onMessage("tele/x/LWT", "Online"), false)

local rgbw = newLight("rgbw:0")
rgbw:onMessage(P .. "/status/rgbw:0", '{"id":0,"output":true,"brightness":80,"rgb":[255,0,0],"white":0}')
T.eq("rgbw color: level from brightness", rgbw.level, 80)
T.eq("rgbw color: full color mode", rgbw.color and rgbw.color.mode, MqttLight.COLOR_MODE_FULL)
T.check("rgbw color: red", rgbw.color and rgbw.color.x > 0.6)
rgbw:onMessage(P .. "/status/rgbw:0", '{"id":0,"output":true,"brightness":100,"rgb":[0,0,0],"white":128}')
T.eq("rgbw white: level from white", rgbw.level, 50)
T.eq("rgbw white: white mode", rgbw.color and rgbw.color.mode, MqttLight.COLOR_MODE_CCT)

local cct = newLight("cct:0")
cct:onMessage(P .. "/status/cct:0", '{"id":0,"output":true,"brightness":30,"ct":3000}')
T.eq("cct: level", cct.level, 30)
T.eq("cct: color temp mode", cct.color and cct.color.mode, MqttLight.COLOR_MODE_CCT)

local sw = newLight("switch:0")
sw:onMessage(P .. "/status/switch:0", '{"id":0,"output":true,"apower":12.5}')
T.eq("switch on: 100", sw.level, 100)

T.section("Shelly mode: commands")
local function lastRpc()
  return last(rpcs())
end
dim = newLight("light:0")
dim:rampTo(50, 0)
local r = lastRpc()
T.eq(
  "Light.Set to <prefix>/rpc",
  { r.topic, r.method, r.src },
  { P .. "/rpc", "Light.Set", "control4/" .. P .. "/light_0" }
)
T.eq("on at 50", { r.params.id, r.params.on, r.params.brightness }, { 0, true, 50 })
T.eq("no fade asked: the device's own", r.params.transition_duration, nil)
dim:rampTo(0, 0)
r = lastRpc()
T.eq("off", { r.params.on, r.params.brightness }, { false, nil })
dim:rampTo(80, 2500)
r = lastRpc()
T.eq("a fade runs on the device", { r.params.brightness, r.params.transition_duration }, { 80, 2.5 })

cct = newLight("cct:0")
cct:rampTo(70, 0, { x = 0.4578, y = 0.4101, mode = MqttLight.COLOR_MODE_CCT })
r = lastRpc()
T.eq("CCT.Set with ct", r.method, "CCT.Set")
T.check("ct about 2700 K", r.params.ct >= 2690 and r.params.ct <= 2760, tostring(r.params.ct))
T.eq("and brightness", r.params.brightness, 70)

rgbw = newLight("rgbw:0")
rgbw:rampTo(60, 0, { x = 0.7006, y = 0.2993, mode = MqttLight.COLOR_MODE_FULL })
r = lastRpc()
T.eq("RGBW.Set red, white off", { r.method, r.params.rgb[1], r.params.rgb[3], r.params.white, r.params.brightness }, {
  "RGBW.Set",
  255,
  0,
  0,
  60,
})
local wx, wy = 0.3804, 0.3768
rgbw:rampTo(40, 0, { x = wx, y = wy, mode = MqttLight.COLOR_MODE_CCT })
r = lastRpc()
T.eq("RGBW white mode: color off, dimmed with white", {
  r.params.rgb[1],
  r.params.rgb[2],
  r.params.rgb[3],
  r.params.white,
  r.params.brightness,
}, { 0, 0, 0, 102, 100 })

sw = newLight("switch:0")
sw:rampTo(100, 0)
r = lastRpc()
T.eq("Switch.Set on", { r.method, r.params.on, r.params.brightness }, { "Switch.Set", true, nil })
sw:rampTo(0, 0)
T.eq("Switch.Set off", lastRpc().params.on, false)

local none = newLight("")
none:rampTo(50, 0)
T.eq("not set up: nothing is sent", #rpcs(), 0)

T.finish()
