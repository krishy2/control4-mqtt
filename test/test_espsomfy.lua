-- Tests for ESPSomfy-RTS discovery (src/mqtt/espsomfy.lua) and an MQTT
-- Shutter run with the settings it gives: topics, positions, movement and
-- the Somfy My button as Stop.
--
-- Run from the repo root:
--   make test
-- or:
--   ./test/run_test.sh test_espsomfy.lua

local T = require("testlib")
require("c4_shim")
require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")
JSON = JSON or require("JSON")
local ESPSomfy = require("mqtt.espsomfy")
local Shutter = require("mqtt.shutter")

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

--- Feed retained messages the way a controller publishes them on connect.
local function controller(root, messages)
  local dev = ESPSomfy.newDevice(root)
  for _, m in ipairs(messages) do
    local info = ESPSomfy.parseTopic(m[1])
    assert(info, "not an ESPSomfy topic: " .. m[1])
    ESPSomfy.update(dev, info, m[2])
  end
  return dev
end

local function shadeMessages(prefix, id, name, shadeType, tiltType, flip)
  local p = (prefix ~= "" and (prefix .. "/") or "") .. "shades/" .. id .. "/"
  return {
    { p .. "name", name },
    { p .. "shadeType", tostring(shadeType) },
    { p .. "tiltType", tostring(tiltType or 0) },
    { p .. "flipPosition", flip and "true" or "false" },
  }
end

local function concat(...)
  local out = {}
  for _, list in ipairs({ ... }) do
    for _, v in ipairs(list) do
      out[#out + 1] = v
    end
  end
  return out
end

-------------------------------------------------------------------------------
T.section("Topics")
-------------------------------------------------------------------------------
local info = ESPSomfy.parseTopic("shades/3/name")
T.eq("no root topic (the default)", { info.root, info.kind, info.id, info.attr }, { "", "shade", "3", "name" })
info = ESPSomfy.parseTopic("somfy/shades/12/shadeType")
T.eq("a root topic", { info.root, info.id, info.attr }, { "somfy", "12", "shadeType" })
info = ESPSomfy.parseTopic("home/somfy/groups/1/name")
T.eq("a two-level root, groups", { info.root, info.kind, info.id }, { "home/somfy", "group", "1" })
T.eq("the shade list", ESPSomfy.parseTopic("somfy/shades").kind, "shades")
T.eq("the host name", ESPSomfy.parseTopic("host").kind, "host")
T.eq("position is not a discovery topic", ESPSomfy.parseTopic("shades/3/position"), nil)
T.eq("nor a command", ESPSomfy.parseTopic("shades/3/target/set"), nil)
T.eq("nor anything else", ESPSomfy.parseTopic("stat/tasmota/RESULT"), nil)
T.eq("id lists", ESPSomfy.parseIds("[1,2,10]"), { "1", "2", "10" })
T.eq("an empty list", ESPSomfy.parseIds("[]"), {})
T.eq("not a list", ESPSomfy.parseIds("on"), nil)

local filters = {}
for _, f in ipairs(ESPSomfy.EXTERNAL_FILTERS) do
  filters[f] = true
end
T.check("external broker: attributes under no root", filters["shades/+/shadeType"])
T.check("one-level root", filters["+/shades/+/name"])
T.check("two-level root", filters["+/+/groups/+/name"])
T.check("not position (changes often)", not filters["+/shades/+/position"])

-------------------------------------------------------------------------------
T.section("A controller's shades")
-------------------------------------------------------------------------------
local dev = controller(
  "somfy",
  concat(
    { { "somfy/host", "ESPSomfyRTS" }, { "somfy/ipAddress", "10.0.0.30" } },
    shadeMessages("somfy", 1, "Living Room", 0),
    shadeMessages("somfy", 2, "Terrace", 3),
    shadeMessages("somfy", 3, "Office Blind", 1, 2),
    shadeMessages("somfy", 4, "Gate Relay", 9),
    shadeMessages("somfy", 5, "Bedroom", 0, 0, true),
    shadeMessages("somfy", 6, "Slats", 1, 3),
    { { "somfy/shades", "[1,2,3,4,5,6]" } },
    { { "somfy/groups/1/name", "All Shades" }, { "somfy/groups", "[1]" } }
  )
)
T.eq("host name and address", { dev.name, dev.ip, dev.topic, dev.mac }, {
  "ESPSomfyRTS",
  "10.0.0.30",
  "somfy",
  "espsomfy:somfy",
})
local list = ESPSomfy.shutters(dev)
local labels = {}
for _, s in ipairs(list) do
  labels[#labels + 1] = s.id .. " " .. s.label .. (s.tilt and " (tilt)" or "")
end
T.eq("covers and groups; the dry contact is left out", labels, {
  "shade:1 Living Room",
  "shade:2 Terrace",
  "shade:3 Office Blind (tilt)",
  "shade:5 Bedroom",
  "shade:6 Slats (tilt)",
  "group:1 All Shades (group)",
})
T.eq("counts", { ESPSomfy.counts(dev) }, { 5, 1 })
local summary = ESPSomfy.summary(dev)
T.eq("summary for the shutter's list", { summary.type, summary.mac, #summary.shutters }, {
  "espsomfy",
  "espsomfy:somfy",
  6,
})

T.eq(
  "a repeated message changes nothing",
  ESPSomfy.update(dev, ESPSomfy.parseTopic("somfy/shades/1/name"), "Living Room"),
  false
)
T.eq("a rename does", ESPSomfy.update(dev, ESPSomfy.parseTopic("somfy/shades/1/name"), "Lounge"), true)
T.eq(
  "a shade dropped from the list goes",
  ESPSomfy.update(dev, ESPSomfy.parseTopic("somfy/shades"), "[1,2,3,4,5]"),
  true
)
T.eq("shade 6 is gone", dev.shades["6"], nil)
ESPSomfy.update(dev, ESPSomfy.parseTopic("somfy/shades/5/name"), "")
T.eq("a cleared name removes a shade", dev.shades["5"], nil)

local lonely = controller("x", { { "x/groups/1/name", "Not a controller" } })
T.eq("groups alone are not listed (could be any device)", #ESPSomfy.shutters(lonely), 0)

-------------------------------------------------------------------------------
T.section("Shutter settings")
-------------------------------------------------------------------------------
dev = controller(
  "",
  concat(
    shadeMessages("", 1, "Living Room", 0),
    shadeMessages("", 2, "Terrace", 3),
    shadeMessages("", 3, "Office Blind", 1, 2),
    shadeMessages("", 5, "Bedroom", 0, 0, true),
    shadeMessages("", 6, "Slats", 1, 3),
    shadeMessages("", 7, "Garage", 5),
    { { "groups/1/name", "All Shades" } }
  )
)
local roller = ESPSomfy.shutterProperties(dev, "shade:1")
T.eq("roller: topics under no root", {
  roller["Position State Topic"],
  roller["Position Command Topic"],
  roller["Target State Topic"],
  roller["Movement State Topic"],
  roller["Availability Topic"],
}, { "shades/1/position", "shades/1/target/set", "shades/1/target", "shades/1/direction", "status" })
T.eq("roller: up (-1) opens, My (0) stops", {
  roller["Open Command Topic"],
  roller["Open Payload"],
  roller["Close Payload"],
  roller["Stop Payload"],
  roller["Stop Only While Moving"],
}, { "shades/1/direction/set", "-1", "1", "0", "Yes" })
T.eq("roller: 0 is up (open), so positions and movement are inverted", {
  roller["Invert Position"],
  roller["Invert Movement"],
}, { "Yes", "Yes" })
T.eq("no tilt", { roller["Tilt State Topic"], roller["Tilt Command Topic"] }, { "", "" })

local awning = ESPSomfy.shutterProperties(dev, "shade:2")
T.eq("awning: down (1) opens; 100 is out", {
  awning["Open Payload"],
  awning["Close Payload"],
  awning["Invert Position"],
  awning["Invert Movement"],
}, { "1", "-1", "No", "No" })

local flipped = ESPSomfy.shutterProperties(dev, "shade:5")
T.eq("Flip Position: the numbers are mirrored, the direction is not", {
  flipped["Invert Position"],
  flipped["Invert Movement"],
  flipped["Open Payload"],
}, { "No", "Yes", "-1" })

local blind = ESPSomfy.shutterProperties(dev, "shade:3")
T.eq("integrated tilt: tilt topics, 0-100", {
  blind["Tilt State Topic"],
  blind["Tilt Command Topic"],
  blind["Tilt Min"],
  blind["Tilt Max"],
}, { "shades/3/tiltPosition", "shades/3/tiltTarget/set", "0", "100" })

local slats = ESPSomfy.shutterProperties(dev, "shade:6")
T.eq("tilt only: no positions", { slats["Position State Topic"], slats["Position Command Topic"] }, { "", "" })
T.eq("and a note for Control Position", ESPSomfy.notes(dev, "shade:6", "Position"), {
  "This shade only tilts; set Control to Tilt.",
})
T.eq("no note for Control Tilt", ESPSomfy.notes(dev, "shade:6", "Tilt"), {})
T.eq("tilt on a shade without it", ESPSomfy.notes(dev, "shade:1", "Tilt"), {
  "This shade has no tilt in ESPSomfy; set Control to Position.",
})
T.check("a one-button garage door is noted", #ESPSomfy.notes(dev, "shade:7", "Position") == 1)

local group = ESPSomfy.shutterProperties(dev, "group:1")
T.eq("a group: direction commands, no movement topic (it stays -1 after Up)", {
  group["Position Command Topic"],
  group["Open Command Topic"],
  group["Movement State Topic"],
  group["Stop Only While Moving"],
}, { "", "groups/1/direction/set", "", "Yes" })
T.eq("named after the shade", ESPSomfy.shutterName(dev, "shade:3"), "Office Blind")
T.eq("an unknown shade", ESPSomfy.shutterProperties(dev, "shade:99"), nil)

-------------------------------------------------------------------------------
T.section("An MQTT Shutter with these settings")
-------------------------------------------------------------------------------
local clock = 1000000
--- The shutter configuration the driver builds from the properties.
local function configFrom(p, control)
  local target = p["Target State Topic"] ~= "" and p["Target State Topic"] or ""
  return {
    mode = p["Payload Mode"],
    control = control or "Position",
    optimistic = "Auto",
    travelTime = 20,
    tiltTime = 2,
    invert = p["Invert Position"] == "Yes",
    invertMovement = p["Invert Movement"] == "Yes",
    stopOnlyWhileMoving = p["Stop Only While Moving"] == "Yes",
    tiltMin = tonumber(p["Tilt Min"]),
    tiltMax = tonumber(p["Tilt Max"]),
    payloadOpen = p["Open Payload"],
    payloadClose = p["Close Payload"],
    payloadStop = p["Stop Payload"],
    topics = {
      position = { stateTopic = p["Position State Topic"], commandTopic = p["Position Command Topic"] },
      target = { stateTopic = target },
      state = { stateTopic = p["Movement State Topic"] },
      tilt = { stateTopic = p["Tilt State Topic"], commandTopic = p["Tilt Command Topic"] },
      open = { commandTopic = p["Open Command Topic"], payload = p["Open Payload"] },
      close = { commandTopic = p["Close Command Topic"], payload = p["Close Payload"] },
      stop = { commandTopic = p["Stop Command Topic"], payload = p["Stop Payload"] },
    },
  }
end
local function newShutter(p, control)
  local s = Shutter.new({
    proxyBinding = 5001,
    brokerBinding = 5002,
    now = function()
      return clock
    end,
  })
  s:configure(configFrom(p, control))
  sent = {}
  return s
end

local s = newShutter(roller)
T.eq("position, open/close and stop", { s.caps.hasLevel, s.caps.canOpenClose, s.caps.canStop }, {
  true,
  true,
  true,
})
s:onMessage("shades/1/direction", "0")
s:onMessage("shades/1/position", "100")
T.eq("ESPSomfy 100 (down) is Control4 closed", last(take("STOPPED")).LEVEL, 0)
sent = {}
s:handleProxyCommand("STOP", {})
T.eq("idle: Stop is not sent (My would go to the favorite position)", published(), {})
s:handleProxyCommand("SET_LEVEL_TARGET", { LEVEL_TARGET = "30" })
T.eq("30% open is ESPSomfy target 70", published(), { "shades/1/target/set=70" })
sent = {}
s:onMessage("shades/1/target", "70")
s:onMessage("shades/1/direction", "-1")
T.eq("going up is opening: no second MOVING", #take("MOVING"), 0)
s:onMessage("shades/1/position", "90")
s:handleProxyCommand("STOP", {})
T.eq("moving: Stop sends My", published(), { "shades/1/direction/set=0" })
sent = {}
s:onMessage("shades/1/direction", "0")
T.eq("stopped where it was", last(take("STOPPED")).LEVEL, 10)
sent = {}
s:handleProxyCommand("SET_LEVEL_TARGET", { LEVEL_TARGET = "100" })
T.eq("fully open: Up (the end stop)", published(), { "shades/1/direction/set=-1" })
sent = {}
s:onMessage("shades/1/target", "0")
s:onMessage("shades/1/direction", "-1")
s:onMessage("shades/1/position", "0")
s:onMessage("shades/1/direction", "0")
T.eq("open", last(take("STOPPED")).LEVEL, 100)
sent = {}
s:onMessage("shades/1/target", "100")
s:onMessage("shades/1/direction", "1")
T.eq("a Somfy remote sends it down: MOVING to closed", last(take("MOVING")).LEVEL_TARGET, 0)
sent = {}
s:handleProxyCommand("TOGGLE", {})
T.eq("toggle while moving stops it", published(), { "shades/1/direction/set=0" })

local aw = newShutter(awning)
aw:onMessage("shades/2/position", "100")
T.eq("awning: ESPSomfy 100 is out (open)", last(take("STOPPED")).LEVEL, 100)
sent = {}
aw:onMessage("shades/2/direction", "-1")
T.eq("awning going up is closing", last(take("MOVING")).LEVEL_TARGET, 0)

local fl = newShutter(flipped)
fl:onMessage("shades/5/position", "100")
T.eq("flipped: 100 reported is up (open)", last(take("STOPPED")).LEVEL, 100)
sent = {}
fl:onMessage("shades/5/direction", "1")
T.eq("and going down still closes", last(take("MOVING")).LEVEL_TARGET, 0)

local tilt = newShutter(blind, "Tilt")
tilt:onMessage("shades/3/tiltPosition", "40")
T.eq("tilt as ESPSomfy reports it", last(take("STOPPED")).LEVEL, 40)
sent = {}
tilt:setLevel(75)
T.eq("tilt target", published(), { "shades/3/tiltTarget/set=75" })

local g = newShutter(group)
T.eq("group: open and close only", { g.caps.hasLevel, g.caps.canOpenClose }, { false, true })
T.eq("going by its travel time", g:isOptimistic(), true)
g:handleProxyCommand("SET_LEVEL_TARGET", { LEVEL_TARGET = "2" })
T.eq("opens with Up", published(), { "groups/1/direction/set=-1" })
sent = {}
g:handleProxyCommand("STOP", {})
T.eq("Stop during the move sends My", published(), { "groups/1/direction/set=0" })
g:handleProxyCommand("SET_LEVEL_TARGET", { LEVEL_TARGET = "0" })
ShimFireTimers()
T.eq("arrived after the travel time", last(take("STOPPED")).LEVEL, 0)
sent = {}
g:handleProxyCommand("STOP", {})
T.eq("idle group: no My", published(), {})

T.eq("Tasmota numbers are unchanged", Shutter.parseMovement("1"), Shutter.OPENING)
T.eq("inverted", Shutter.parseMovement("1", true), Shutter.CLOSING)
T.eq("words are not inverted", Shutter.parseMovement("opening", true), Shutter.OPENING)

T.finish()
