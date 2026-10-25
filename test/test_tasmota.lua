-- Tests for Tasmota discovery parsing and the MQTT Light settings derived
-- from it (src/mqtt/tasmota.lua). Payloads follow the exact shape Tasmota's
-- xdrv_12_discovery.ino publishes.
--
-- Run from the repo root:
--   make test
-- or:
--   ./test/run_test.sh test_tasmota.lua

local T = require("testlib")
require("c4_shim")
require("drivers-common-public.global.lib")
local Tasmota = require("mqtt.tasmota")

--- A discovery payload as Tasmota builds it.
local function discovery(opts)
  local rl = opts.rl or { 2, 0, 0, 0, 0, 0, 0, 0 }
  local fn = opts.fn or { "Tasmota" }
  local fnJson = {}
  for i = 1, 8 do
    fnJson[i] = fn[i] and string.format('"%s"', fn[i]) or "null"
  end
  local rlJson = {}
  for i = 1, 8 do
    rlJson[i] = tostring(rl[i] or 0)
  end
  local so = opts.so or {}
  return string.format(
    '{"ip":"10.80.104.%d","dn":"%s","fn":[%s],"hn":"%s","mac":"%s","md":"%s","ty":0,"if":0,"cam":0,'
      .. '"ofln":"Offline","onln":"Online","state":["OFF","ON","TOGGLE","HOLD"],"sw":"14.3.0",'
      .. '"t":"%s","ft":"%s","tp":["cmnd","stat","tele"],"rl":[%s],'
      .. '"swc":[-1,-1,-1,-1,-1,-1,-1,-1],"swn":[null,null,null,null,null,null,null,null],"btn":[0,0,0,0,0,0,0,0],'
      .. '"so":{"4":%d,"11":0,"13":0,"17":%d,"20":0,"30":0,"68":%d,"73":0,"82":%d,"114":0,"117":0},'
      .. '"lk":%d,"lt_st":%d,"bat":0,"dslp":0,"sho":[],"sht":[],"ver":1}',
    opts.ip or 21,
    opts.name or "Kitchen",
    table.concat(fnJson, ","),
    opts.hostname or "tasmota-A1B2C3-0123",
    opts.mac or "84F3EBA1B2C3",
    opts.model or "Generic",
    opts.topic or "tasmota_A1B2C3",
    opts.ft or "%prefix%/%topic%/",
    table.concat(rlJson, ","),
    so[4] or 0,
    so[17] or 0,
    so[68] or 0,
    so[82] or 0,
    opts.lk == nil and 1 or opts.lk,
    opts.lt or 0
  )
end

local function ids(loads)
  local out = {}
  for _, l in ipairs(loads) do
    out[#out + 1] = l.id .. "=" .. l.power
  end
  return out
end

-------------------------------------------------------------------------------
T.section("Parsing")
-------------------------------------------------------------------------------
T.eq("discovery topic gives the MAC", Tasmota.discoveryMac("tasmota/discovery/84F3EBA1B2C3/config"), "84F3EBA1B2C3")
T.eq("sensors topic is not a config", Tasmota.discoveryMac("tasmota/discovery/84F3EBA1B2C3/sensors"), nil)
T.eq("empty payload is a removal", Tasmota.parse(""), nil)
T.eq("random JSON is ignored", Tasmota.parse('{"POWER":"ON"}'), nil)

local bulb = Tasmota.parse(discovery({ lt = 5 }))
T.check("an RGBCCT bulb parses", bulb ~= nil)
T.eq("fields", { bulb.topic, bulb.name, bulb.mac, bulb.lightType, bulb.linked }, {
  "tasmota_A1B2C3",
  "Kitchen",
  "84F3EBA1B2C3",
  5,
  true,
})
T.eq("relay list trimmed to used outputs", bulb.relays, { 2 })
T.eq("JSON nulls in friendly names become empty", bulb.friendlyNames, { "Tasmota" })

-------------------------------------------------------------------------------
T.section("Topics")
-------------------------------------------------------------------------------
T.eq("command topic", Tasmota.topicFor(bulb, 1, "POWER"), "cmnd/tasmota_A1B2C3/POWER")
T.eq("state topic", Tasmota.topicFor(bulb, 2, "RESULT"), "stat/tasmota_A1B2C3/RESULT")
T.eq("telemetry topic", Tasmota.topicFor(bulb, 3, "LWT"), "tele/tasmota_A1B2C3/LWT")
local custom = Tasmota.parse(discovery({ lt = 1, ft = "home/%topic%/%prefix%/", topic = "hall" }))
T.eq("custom full topic", Tasmota.topicFor(custom, 1, "Dimmer"), "home/hall/cmnd/Dimmer")
local byId = Tasmota.parse(discovery({ lt = 1, ft = "%prefix%/%hostname%/%id%" }))
T.eq(
  "hostname and id, missing trailing slash",
  Tasmota.topicFor(byId, 2, "RESULT"),
  "stat/tasmota-A1B2C3-0123/A1B2C3/RESULT"
)

-------------------------------------------------------------------------------
T.section("Light settings for each light type")
-------------------------------------------------------------------------------
local function props(lt, extra)
  extra = extra or {}
  extra.lt = lt
  local dev = Tasmota.parse(discovery(extra))
  local loads = Tasmota.loads(dev)
  return Tasmota.lightProperties(dev, loads[1].id), dev, loads
end

local p = props(5)
T.eq("RGBCCT: power from RESULT", { p["Power State Topic"], p["Power Value Path"], p["Power Command Topic"] }, {
  "stat/tasmota_A1B2C3/RESULT",
  "$.POWER",
  "cmnd/tasmota_A1B2C3/POWER",
})
T.eq("RGBCCT: dimmer", { p["Brightness Value Path"], p["Brightness Command Topic"] }, {
  "$.Dimmer",
  "cmnd/tasmota_A1B2C3/Dimmer",
})
T.eq(
  "RGBCCT: CT in mireds 2000-6500K",
  { p["Color Temp Value Path"], p["Color Temp Unit"], p["Color Temp Min"], p["Color Temp Max"] },
  {
    "$.CT",
    "Mireds",
    "2000",
    "6500",
  }
)
T.eq(
  "RGBCCT: hex color with brightness",
  { p["Color Value Path"], p["Color Format"], p["Color Includes Brightness"] },
  {
    "$.Color",
    "Hex (RRGGBB)",
    "Yes",
  }
)
T.eq("RGBCCT: no white channel", p["White Command Topic"], "")
T.eq("state request", p["State Request Topic"], "cmnd/tasmota_A1B2C3/STATE")
T.eq("availability", { p["Availability Topic"], p["Payload Available"], p["Payload Not Available"] }, {
  "tele/tasmota_A1B2C3/LWT",
  "Online",
  "Offline",
})

p = props(1)
T.eq("dimmer: no CT or color", { p["Color Temp Command Topic"], p["Color Command Topic"] }, { "", "" })
T.eq("dimmer: brightness", p["Brightness Value Path"], "$.Dimmer")
p = props(2)
T.eq("CCT: CT, no color", { p["Color Temp Value Path"], p["Color Command Topic"] }, { "$.CT", "" })
p = props(3)
T.eq(
  "RGB: color, no CT, no white",
  { p["Color Value Path"], p["Color Temp Command Topic"], p["White Command Topic"] },
  {
    "$.Color",
    "",
    "",
  }
)
p = props(4)
T.eq("RGBW: color and white", { p["Color Value Path"], p["White Value Path"] }, { "$.Color", "$.White" })

p = props(5, { so = { [17] = 1, [82] = 1 } })
T.eq("SetOption17: decimal color", p["Color Format"], "RGB (r,g,b)")
T.eq("SetOption82: reduced CT range", { p["Color Temp Min"], p["Color Temp Max"] }, { "2630", "5000" })

local relayOnly = Tasmota.parse(discovery({ rl = { 1 } }))
local relayLoads = Tasmota.loads(relayOnly)
T.eq("a plain relay is offered as an on/off load", ids(relayLoads), { "relay1=POWER" })
p = Tasmota.lightProperties(relayOnly, "relay1")
T.eq("relay: on/off only", { p["Power Value Path"], p["Brightness Command Topic"], p["Color Command Topic"] }, {
  "$.POWER",
  "",
  "",
})

-------------------------------------------------------------------------------
T.section("Several outputs: POWER<n>")
-------------------------------------------------------------------------------
local _, _, loads = props(3, { rl = { 1, 1, 2 }, fn = { "Kitchen", "Fan", "Strip" } })
T.eq("light first, then relays, all indexed", ids(loads), { "light3=POWER3", "relay1=POWER1", "relay2=POWER2" })
T.eq("relay named by its friendly name", loads[3].label, "Relay 2 'Fan'")
p = props(3, { rl = { 1, 1, 2 } })
T.eq("light on output 3", { p["Power Value Path"], p["Power Command Topic"] }, {
  "$.POWER3",
  "cmnd/tasmota_A1B2C3/POWER3",
})

-------------------------------------------------------------------------------
T.section("RGB and white split (lk = 0)")
-------------------------------------------------------------------------------
local split = Tasmota.parse(discovery({ lt = 5, lk = 0, rl = { 2, 2 } }))
T.eq("two lights", ids(Tasmota.loads(split)), { "light1=POWER1", "light2=POWER2" })
local rgb = Tasmota.lightProperties(split, "light1")
local white = Tasmota.lightProperties(split, "light2")
T.eq("color part: POWER1, Dimmer1, Color, no CT", {
  rgb["Power Value Path"],
  rgb["Brightness Value Path"],
  rgb["Brightness Command Topic"],
  rgb["Color Value Path"],
  rgb["Color Temp Command Topic"],
}, { "$.POWER1", "$.Dimmer1", "cmnd/tasmota_A1B2C3/Dimmer1", "$.Color", "" })
T.eq("white part: POWER2, Dimmer2, CT, no color", {
  white["Power Value Path"],
  white["Brightness Value Path"],
  white["Color Temp Value Path"],
  white["Color Command Topic"],
}, { "$.POWER2", "$.Dimmer2", "$.CT", "" })

-------------------------------------------------------------------------------
T.section("SetOption68: one dimmer per channel")
-------------------------------------------------------------------------------
local multi = Tasmota.parse(discovery({ lt = 3, lk = 0, rl = { 2, 2, 2 }, so = { [68] = 1 } }))
T.eq("three channels", ids(Tasmota.loads(multi)), { "channel1=POWER1", "channel2=POWER2", "channel3=POWER3" })
p = Tasmota.lightProperties(multi, "channel2")
T.eq(
  "channel 2",
  { p["Power Value Path"], p["Brightness Value Path"], p["Brightness Command Topic"], p["Color Command Topic"] },
  {
    "$.POWER2",
    "$.Channel2",
    "cmnd/tasmota_A1B2C3/Channel2",
    "",
  }
)

-------------------------------------------------------------------------------
T.section("Notes and summaries")
-------------------------------------------------------------------------------
T.eq("no notes for a default device", #Tasmota.notes(bulb), 0)
local so4 = Tasmota.parse(discovery({ lt = 1, so = { [4] = 1 } }))
T.contains("SetOption4 is flagged", Tasmota.notes(so4)[1], "SetOption4 0")
local summary = Tasmota.summary(Tasmota.parse(discovery({ lt = 3, rl = { 1, 2 } })))
T.eq(
  "summary lists loads",
  { summary.topic, #summary.loads, summary.loads[1].label },
  { "tasmota_A1B2C3", 2, "RGB light" }
)
T.eq("unknown load id", Tasmota.lightProperties(bulb, "relay9"), nil)

T.section("A Control4 name for each output")
local function nameOf(opts, loadId)
  return Tasmota.loadName(Tasmota.parse(discovery(opts)), loadId)
end
T.eq("a bulb: its device name", nameOf({ name = "Hall Lamp", lt = 5, rl = { 2 } }, "light1"), "Hall Lamp")
T.eq(
  "default FriendlyName on a bulb is not used",
  nameOf({ name = "Hall Lamp", fn = { "Tasmota" }, lt = 5, rl = { 2 } }, "light1"),
  "Hall Lamp"
)
T.eq(
  "DeviceName left at the default: the topic",
  nameOf({ name = "Tasmota", fn = { "Tasmota" }, topic = "hall_lamp", lt = 2, rl = { 2 } }, "light1"),
  "hall_lamp"
)
T.eq(
  "a relay and a light: device name and output",
  nameOf({ name = "Kitchen", fn = { "Kitchen" }, lt = 5, rl = { 1, 2 } }, "light2"),
  "Kitchen RGBCCT light"
)
T.eq(
  "an output with its own FriendlyName",
  nameOf({ name = "Kitchen", fn = { "Kitchen", "Island" }, lt = 2, rl = { 1, 2 } }, "light2"),
  "Island"
)
T.eq(
  "relay named by its FriendlyName",
  nameOf({ name = "Kitchen", fn = { "Fan", "Island" }, lt = 2, rl = { 1, 2 } }, "relay1"),
  "Fan"
)
T.eq(
  "default FriendlyName on output 2 is not used",
  nameOf({ name = "Kitchen", fn = { "Kitchen", "Tasmota2" }, lt = 2, rl = { 1, 2 } }, "light2"),
  "Kitchen CCT light"
)
local split = { name = "Strip", fn = { "Strip", "Strip" }, lt = 5, lk = 0, rl = { 2, 2 } }
T.eq("split RGB part", nameOf(split, "light1"), "Strip RGB light")
T.eq("split white part", nameOf(split, "light2"), "Strip CCT light")
T.eq("no such output", nameOf(split, "relay9"), nil)

T.finish()
