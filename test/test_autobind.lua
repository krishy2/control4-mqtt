-- Tests that MQTT Light and MQTT General drivers connect to the MQTT Broker
-- driver by themselves, from either side.
--
-- Run from the repo root:
--   make test
-- or:
--   ./test/run_test.sh test_autobind.lua

local T = require("testlib")
require("c4_shim")
require("drivers-common-public.global.lib")
local AutoBind = require("mqtt.autobind")

local myId = 12345
C4.GetDeviceID = function()
  return myId
end

local function project(devices)
  ShimResetDynamicBindings()
  ShimSetDevices(devices)
end

local function providerOf(deviceId, bindingId)
  return C4:GetBoundProviderDevice(deviceId, bindingId)
end

T.section("A light or general driver connects itself")
project({
  [900] = { deviceName = "MQTT Broker", driverFileName = "cp_mqtt_broker.c4z" },
  [12345] = { deviceName = "Kitchen", driverFileName = "cp_mqtt_light.c4z" },
})
local bound
T.capture(function()
  bound = AutoBind.connectSelf(5002)
end)
T.eq("binds to the broker", bound, true)
T.eq("on the broker's 5001 and its own 5002", providerOf(12345, 5002), 900)
T.eq("the class", ShimConnections()[1].class, "CP_MQTT_BROKER")
T.capture(function()
  bound = AutoBind.connectSelf(5002)
end)
T.eq("already connected: left alone", bound, false)
T.eq("still one connection", #ShimConnections(), 1)

project({ [12345] = { deviceName = "Kitchen", driverFileName = "cp_mqtt_light.c4z" } })
T.capture(function()
  bound = AutoBind.connectSelf(5002)
end)
T.eq("no broker in the project: nothing bound", bound, false)
T.eq("no connection", #ShimConnections(), 0)

project({
  [950] = { deviceName = "Broker B", driverFileName = "cp_mqtt_broker.c4z" },
  [900] = { deviceName = "Broker A", driverFileName = "cp_mqtt_broker.c4z" },
  [12345] = { deviceName = "Kitchen", driverFileName = "cp_mqtt_light.c4z" },
})
T.capture(function()
  AutoBind.connectSelf(5002)
end)
T.eq("two brokers: the lowest device ID", providerOf(12345, 5002), 900)

project({
  [900] = { deviceName = "MQTT Broker", driverFileName = "cp_mqtt_broker.c4z" },
  [800] = { deviceName = "Other broker", driverFileName = "some_other_mqtt.c4z" },
  [12345] = { deviceName = "Kitchen", driverFileName = "cp_mqtt_light.c4z" },
})
C4:Bind(800, 1, 12345, 5002, "CP_MQTT_BROKER")
T.capture(function()
  bound = AutoBind.connectSelf(5002)
end)
T.eq("connected by hand to something else: left alone", { bound, providerOf(12345, 5002) }, { false, 800 })

T.section("The broker connects drivers added before it")
myId = 900
project({
  [900] = { deviceName = "MQTT Broker", driverFileName = "cp_mqtt_broker.c4z" },
  [101] = { deviceName = "Hall", driverFileName = "cp_mqtt_light.c4z" },
  [102] = { deviceName = "Porch", driverFileName = "cp_mqtt_light.c4z" },
  [201] = { deviceName = "Sensors", driverFileName = "cp_mqtt_general.c4z" },
  [301] = { deviceName = "A dimmer", driverFileName = "some_dimmer.c4z" },
})
C4:Bind(900, 5001, 102, 5002, "CP_MQTT_BROKER")
local count
T.capture(function()
  count = AutoBind.connectAll()
end)
T.eq("the two unconnected drivers", count, 2)
T.eq("light on 5002", providerOf(101, 5002), 900)
T.eq("general on 5001", providerOf(201, 5001), 900)
T.eq("other drivers untouched", providerOf(301, 5001), 0)
T.eq("connected ones not bound twice", #ShimConnections(), 3)
T.capture(function()
  count = AutoBind.connectAll()
end)
T.eq("a second run binds nothing", count, 0)

myId = 950
project({
  [900] = { deviceName = "Broker A", driverFileName = "cp_mqtt_broker.c4z" },
  [950] = { deviceName = "Broker B", driverFileName = "cp_mqtt_broker.c4z" },
  [101] = { deviceName = "Hall", driverFileName = "cp_mqtt_light.c4z" },
})
T.capture(function()
  count = AutoBind.connectAll()
end)
T.eq("a second broker leaves it to the first", { count, #ShimConnections() }, { 0, 0 })

T.section("Controller answers in other shapes")
myId = 12345
project({
  [900] = { deviceName = "MQTT Broker", driverFileName = "cp_mqtt_broker.c4z" },
  [12345] = { deviceName = "Kitchen", driverFileName = "cp_mqtt_light.c4z" },
})
local realProvider = C4.GetBoundProviderDevice
C4.GetBoundProviderDevice = function()
  return { [900] = "MQTT Broker" }
end
T.eq("a { id = name } table counts as connected", AutoBind.isBound(12345, 5002), true)
C4.GetBoundProviderDevice = function()
  return {}
end
T.eq("an empty table does not", AutoBind.isBound(12345, 5002), false)
C4.GetBoundProviderDevice = function()
  return nil
end
T.eq("nor does nil", AutoBind.isBound(12345, 5002), false)
C4.GetBoundProviderDevice = realProvider

T.section("The XML and the module agree")
local function readFile(path)
  local f = assert(io.open(path, "r"))
  local text = f:read("*a")
  f:close()
  return text
end
for file, binding in pairs(AutoBind.CONSUMERS) do
  local dir = file:gsub("%.c4z$", "")
  local xml = readFile("drivers/" .. dir .. "/driver.xml")
  local found = false
  for block in xml:gmatch("<connection>(.-)</connection>") do
    if block:find("<id>" .. binding .. "</id>", 1, true) and block:find("CP_MQTT_BROKER", 1, true) then
      found = block:find("<consumer>True</consumer>", 1, true) ~= nil
    end
  end
  T.check(dir .. " has its broker binding on " .. binding, found)
end
local brokerXml = readFile("drivers/cp_mqtt_broker/driver.xml")
T.check(
  "the broker provides CP_MQTT_BROKER on " .. AutoBind.BROKER_BINDING,
  brokerXml:find("<id>" .. AutoBind.BROKER_BINDING .. "</id>", 1, true) ~= nil
)

T.finish()
