-- Tests for the MQTT Web View: the field model (src/mqtt/dashboard.lua) and the
-- driver end to end in the C4 shim (broker connect, subscription, an MQTT
-- message, variables, and what the web view receives).
--
-- Run from the repo root:
--   make test
-- or:
--   ./test/run_test.sh test_mqtt_webview.lua

local T = require("testlib")
local JSON = require("JSON")
local fields = require("mqtt.dashboard")

local function decode(s)
  return JSON:decode(s)
end

local function byKey(list)
  local out = {}
  for _, f in ipairs(list) do
    out[f.key] = f
  end
  return out
end

local function keys(list)
  local out = {}
  for _, f in ipairs(list) do
    table.insert(out, f.key)
  end
  return out
end

T.section("a zigbee2mqtt Vindstyrka payload")
local vindstyrka = '{"humidity":41.2,"linkquality":142,"pm25":18,"temperature":22.43,"voc_index":96,'
  .. '"update":{"installed_version":1,"latest_version":2,"state":"available"},"update_available":false}'
local flat = fields.decodePayload("zigbee2mqtt/Vindstyrka", vindstyrka, decode)
T.eq("nested objects are flattened", flat["update.state"], "available")
T.eq("numbers stay numbers", flat.pm25, 18)

local values = {}
for k, v in pairs(flat) do
  values[k] = { value = v, ts = 100, topic = "zigbee2mqtt/Vindstyrka" }
end
local list = fields.build(values, { hidden = fields.parseList("update*,last_seen") })
local f = byKey(list)
T.eq("update* hides the nested and flag keys", { f["update.state"], f.update_available }, { nil, nil })
T.eq(
  "known keys get labels",
  { f.pm25.label, f.voc_index.label, f.humidity.label },
  { "PM2.5", "VOC Index", "Humidity" }
)
T.eq("and units", { f.pm25.unit, f.temperature.unit, f.humidity.unit }, { "µg/m³", "°C", "%" })
T.eq("temperature rounds to one decimal", f.temperature.display, "22.4")
T.eq("humidity rounds to whole numbers", f.humidity.display, "41")
T.eq("PM2.5 of 18 is fair", f.pm25.level, "fair")
T.eq("VOC index of 96 is good", f.voc_index.level, "good")
T.eq("worst level wins", fields.worstLevel(list), "fair")
T.eq("graded air readings sort first", keys(list), { "pm25", "voc_index", "temperature", "humidity", "linkquality" })

T.section("ordering, labels and conversion")
list = fields.build(values, {
  hidden = { "update*" },
  order = { "temperature", "humidity" },
  overrides = fields.parseOverrides("pm25=Fine dust; voc_index=Air|; linkquality=Signal|lqi"),
  tempConversion = "Celsius to Fahrenheit",
})
f = byKey(list)
T.eq("Field Order puts keys first", { list[1].key, list[2].key }, { "temperature", "humidity" })
T.eq("label override keeps default unit", { f.pm25.label, f.pm25.unit }, { "Fine dust", "µg/m³" })
T.eq("empty unit after | removes it", { f.voc_index.label, f.voc_index.unit }, { "Air", "" })
T.eq("custom unit", f.linkquality.unit, "lqi")
T.eq("C to F conversion", { f.temperature.display, f.temperature.unit }, { "72.4", "°F" })

T.section("non-JSON payloads")
flat = fields.decodePayload("home/office/co2", " 1450 ", decode)
T.eq("plain number is named after the topic", flat.co2, 1450)
list = fields.build({ co2 = { value = 1450 } }, {})
T.eq("CO2 of 1450 is poor", list[1].level, "poor")
flat = fields.decodePayload("home/door", "OPEN", decode)
T.eq("plain text kept as text", flat.door, "OPEN")
flat = fields.decodePayload("x/y", "{broken", decode)
T.eq("broken JSON falls back to raw text", flat.y, "{broken")

T.section("helpers")
T.eq(
  "prettify snake and camel",
  { fields.prettify("battery_low"), fields.prettify("a.colorTemp") },
  { "Battery Low", "Color Temp" }
)
T.eq("booleans render Yes/No", fields.build({ ok = { value = true } }, {})[1].display, "Yes")
T.eq("arrays get indexes", fields.flatten(decode('{"a":[5,6]}'))["a[2]"], 6)
T.eq("trailing zeros trimmed", { fields.formatNumber(3.10, 2), fields.formatNumber(-0.01, 1) }, { "3.1", "0" })
T.eq("summary", fields.summary({ { label = "PM2.5", display = "4", unit = "µg/m³" } }), "PM2.5: 4 µg/m³")

-------------------------------------------------------------------------------
-- The driver
-------------------------------------------------------------------------------

-- Record what the driver sends
local proxySent, uiData, events, props = {}, {}, {}, {}
function C4:SendToProxy(binding, cmd, params)
  table.insert(proxySent, { binding = binding, cmd = cmd, params = params or {} })
end
function C4:SendDataToUI(xml)
  table.insert(uiData, xml)
end
function C4:FireEvent(name)
  table.insert(events, name)
end
function C4:UpdateProperty(name, value)
  props[name] = value
  Properties[name] = value
end
function C4:GetDriverFileName()
  return "cp_mqtt_webview.c4z"
end
local xmlText = io.open("drivers/cp_mqtt_webview/driver.xml"):read("*a")
function C4:GetDriverConfigInfo(key)
  if key == "version" then
    return "20261030"
  elseif key == "minimum_os_version" then
    return "3.3.0"
  elseif key == "config" then
    return string.match(xmlText, "<config>.*</config>")
  end
  return ""
end

local function sentOf(cmd)
  local out = {}
  for _, s in ipairs(proxySent) do
    if s.cmd == cmd then
      table.insert(out, s)
    end
  end
  return out
end

-- Property defaults from driver.xml
for k, v in pairs({
  ["Log Level"] = "3 - Info",
  ["Log Mode"] = "Off",
  ["MQTT Topics"] = "zigbee2mqtt/Vindstyrka",
  ["QoS"] = "0",
  ["Title"] = "",
  ["Theme"] = "Dark",
  ["Field Order"] = "",
  ["Hidden Fields"] = "update*,last_seen,identify",
  ["Field Labels"] = "",
  ["Temperature Display"] = "As Received",
  ["Stale After (minutes)"] = "15",
  ["Create Variables"] = "Yes",
  ["Driver Status"] = "",
  ["Driver Version"] = "",
  ["Last Message"] = "",
  ["Last Payload"] = "",
  ["Current Values"] = "",
  ["Web View URL"] = "",
}) do
  Properties[k] = v
end

ShimSetDevices({
  [900] = { deviceName = "MQTT Broker", driverFileName = "cp_mqtt_broker.c4z" },
  [12345] = { deviceName = "Test Device", driverFileName = "cp_mqtt_webview.c4z" },
})
dofile("drivers/cp_mqtt_webview/driver.lua")

T.section("startup")
OnDriverInit()
OnDriverLateInit()
T.eq("it connects itself to the broker", C4:GetBoundProviderDevice(12345, 5002), 900)
T.eq(
  "URL points at this driver's page",
  props["Web View URL"],
  "controller://driver/cp_mqtt_webview/dashboard/index.html"
)
T.eq("URL_CHANGED sent to the UI Button proxy", sentOf("URL_CHANGED")[1].binding, 5001)
T.eq("asks broker for status", sentOf("GET_STATUS")[1].binding, 5002)
T.eq("no subscription before the broker is up", #sentOf("SUBSCRIBE"), 0)

T.section("broker connects")
ReceivedFromProxy(5002, "BROKER_CONNECTED", {})
local sub = sentOf("SUBSCRIBE")
T.eq("subscribes to the topic", sub[1] and sub[1].params.topic, "zigbee2mqtt/Vindstyrka")
T.eq("with our device id", sub[1] and sub[1].params.device_id, "12345")
T.eq("status", props["Driver Status"], "Connected")

T.section("a message arrives")
ExecuteCommand("MQTT_MESSAGE", {
  topic = "zigbee2mqtt/Vindstyrka",
  payload = '{"humidity":41.2,"linkquality":142,"pm25":18,"temperature":22.43,"voc_index":96,"update":{"state":"idle"}}',
})
T.contains("Current Values summary", props["Current Values"], "PM2.5: 18 µg/m³")
T.eq(
  "variables created",
  { Variables["pm25"], Variables["temperature"], Variables["Air Quality"] },
  { "18", "22.43", "Fair" }
)
T.eq("hidden fields get no variable", Variables["update.state"], nil)
T.contains("Values Updated fired", table.concat(events, ","), "Values Updated")
local icon = sentOf("ICON_CHANGED")
T.eq("navigator icon follows air quality", icon[#icon].params.icon, "fair")

T.section("the web view")
local reply = UIRequest("GET_DASHBOARD", {})
T.contains("UIRequest returns the dashboard XML", reply, "<dashboard>")
local json = string.match(reply, "<dashboard>(.*)</dashboard>")
json = string.gsub(json, "&quot;", '"')
json = string.gsub(json, "&apos;", "'")
json = string.gsub(json, "&lt;", "<")
json = string.gsub(json, "&gt;", ">")
json = string.gsub(json, "&amp;", "&")
local d = JSON:decode(json)
T.eq("marker, title and level", { d.mqttDashboard, d.title, d.level }, { 1, "Test Device", "fair" })
T.eq("fields in display order", d.fields[1].label, "PM2.5")
T.eq("connected flag", d.connected, true)
ShimFireTimers()
T.contains("DataToUI push", uiData[#uiData] or "", "mqttDashboard")

T.section("messages for other topics are ignored")
local before = props["Current Values"]
ExecuteCommand("MQTT_MESSAGE", { topic = "other/topic", payload = '{"x":1}' })
T.eq("unchanged", props["Current Values"], before)

T.section("changing topics drops old values")
Properties["MQTT Topics"] = "home/co2"
OnPropertyChanged("MQTT Topics")
T.eq("unsubscribed from the old topic", sentOf("UNSUBSCRIBE")[1].params.topic, "zigbee2mqtt/Vindstyrka")
T.eq("subscribed to the new one", sentOf("SUBSCRIBE")[#sentOf("SUBSCRIBE")].params.topic, "home/co2")
T.eq("old values cleared", props["Current Values"], "")
T.eq("their variables deleted", Variables["pm25"], nil)
ExecuteCommand("MQTT_MESSAGE", { topic = "home/co2", payload = "1450" })
T.eq("plain payload named after topic", Variables["co2"], "1450")

T.section("broker disconnects")
ReceivedFromProxy(5002, "BROKER_DISCONNECTED", {})
T.eq("status", props["Driver Status"], "Broker disconnected")

T.finish()
