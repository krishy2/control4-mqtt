-- Tests that the MQTT Broker driver reads every kept Tasmota discovery message
-- again when it starts, so what a driver update reads from it (buttons, in
-- v2026102508) applies without waiting for each device to announce itself.
--
-- Run from the repo root:
--   make test
-- or:
--   ./test/run_test.sh test_tasmota_reparse.lua

local T = require("testlib")
require("c4_shim")
require("lib.utils")
require("drivers-common-public.global.lib")
JSON = JSON or require("JSON")
local persist = require("lib.persist")

-- A real discovery message (Sonoff M5-3C, SetOption73 1), and the record an
-- older broker kept for it: parsed before buttons were read.
local MAC = "C82E1852E884"
local payload = '{"ip":"10.80.104.32","dn":"Guest-Washroom","fn":["Guest-Washroom-Light-1","Guest-Washroom-Light-2",'
  .. '"","",null,null,null,null],"hn":"Guest-Washroom","mac":"C82E1852E884","md":"Sonoff M5-3C","ty":0,"if":0,'
  .. '"cam":0,"ofln":"Offline","onln":"Online","state":["OFF","ON","TOGGLE","HOLD"],"sw":"15.3.0",'
  .. '"t":"guest-washroom","ft":"%prefix%/%topic%/","tp":["cmnd","stat","tele"],"rl":[1,1,1,2,0,0,0,0],'
  .. '"swc":[-1,-1,-1,-1,-1,-1,-1,-1],"swn":[null,null,null,null,null,null,null,null],"btn":[1,1,1,0,0,0,0,0],'
  .. '"so":{"4":0,"11":0,"13":1,"17":0,"20":0,"30":0,"68":0,"73":1,"82":0,"114":1,"117":0},'
  .. '"lk":1,"lt_st":1,"bat":0,"dslp":0,"sho":[],"sht":[],"ver":1}'
persist:set("TasmotaDevices", {
  [MAC] = { mac = MAC, topic = "guest-washroom", name = "Guest-Washroom", ip = "10.80.104.32", relays = { 1, 1, 1, 2 } },
})
persist:set("TasmotaDiscovery", { [MAC] = payload })

local deviceMsgs = {}
C4.SendToDevice = function(_, deviceId, command, params)
  deviceMsgs[#deviceMsgs + 1] = { deviceId = deviceId, command = command, params = params or {} }
end
C4.CreateTCPServer = function()
  error("not used")
end
local realGetDriverConfigInfo = C4.GetDriverConfigInfo
C4.GetDriverConfigInfo = function(c4, section)
  if section == "minimum_os_version" then
    return "3.3.0"
  end
  return realGetDriverConfigInfo(c4, section)
end
local xml = assert(io.open("drivers/cp_mqtt_broker/driver.xml")):read("*a")
for block in xml:gmatch("<property>(.-)</property>") do
  Properties[block:match("<name>(.-)</name>")] = block:match("<default>(.-)</default>") or ""
end
Properties["Log Level"] = "2 - Warning"
Properties["Automatic Updates"] = "Off"

local ok, err = T.capture(function()
  dofile("drivers/cp_mqtt_broker/driver.lua")
  OnDriverInit()
  OnDriverLateInit()
end)
T.check("the broker starts", ok, err)
T.capture(function()
  ReceivedFromProxy(5001, "GET_TASMOTA_DEVICES", { device_id = "202" })
end)
local list = JSON:decode(deviceMsgs[#deviceMsgs].params.devices)
T.eq("the old record is read again: 3 buttons", list[1] and list[1].buttons, 3)
T.capture(function()
  ReceivedFromProxy(5001, "GET_TASMOTA_DEVICE", { device_id = "202", mac = MAC })
end)
local dev = JSON:decode(deviceMsgs[#deviceMsgs].params.device)
T.eq("and in full", { dev.so73, #dev.buttons }, { 1, 3 })

T.capture(function()
  ExecuteCommand("LUA_ACTION", { ACTION = "ForgetTasmotaDevices" })
end)
T.eq("Forget Tasmota Devices also drops the kept messages", persist:get("TasmotaDiscovery", nil), nil)

T.finish()
