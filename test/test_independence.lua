-- Tests that these drivers stay independent of other MQTT drivers (such as the
-- Finite Labs MQTT suite) that may be installed in the same project:
--   - own file names (cp_ prefix), so installing or auto-updating one suite
--     never replaces the other's .c4z
--   - own connection class (CP_MQTT_BROKER), so the suites never bind to each
--     other
--   - no references to the other suite's publisher or licensing
--
-- Run from the repo root:
--   make test
-- or:
--   ./test/run_test.sh test_independence.lua

local T = require("testlib")

local function readFile(path)
  local fh = io.open(path, "r")
  if not fh then
    return nil
  end
  local body = fh:read("*a")
  fh:close()
  return body
end

local function ls(dir)
  local out = {}
  local pipe = assert(io.popen(string.format("ls %q", dir)))
  for name in pipe:lines() do
    out[#out + 1] = name
  end
  pipe:close()
  return out
end

local drivers = ls("drivers")
T.check("there are drivers to check", #drivers >= 3, tostring(#drivers))

T.section("File names")
for _, dir in ipairs(drivers) do
  T.check(dir .. " has the cp_ prefix", dir:sub(1, 3) == "cp_")
  local proj = readFile("drivers/" .. dir .. "/driver.c4zproj") or ""
  T.eq(dir .. " packages as " .. dir .. ".c4z", proj:match('name="([^"]+)"'), dir)
end

T.section("Connection class")
for _, dir in ipairs(drivers) do
  local xml = readFile("drivers/" .. dir .. "/driver.xml") or ""
  T.check(
    dir .. " does not use the shared MQTT_BROKER class",
    not xml:find("<classname>MQTT_BROKER</classname>", 1, true)
  )
  -- MQTT drivers (cp_mqtt_*) use the suite's broker class; others (cp_pi_thermostat) need no broker
  if dir:sub(1, 8) == "cp_mqtt_" then
    T.check(dir .. " uses CP_MQTT_BROKER", xml:find("<classname>CP_MQTT_BROKER</classname>", 1, true) ~= nil)
  else
    T.check(dir .. " has no MQTT broker connection", not xml:find("MQTT_BROKER", 1, true))
  end
end

T.section("No references to the other suite")
local banned = { "finite labs", "finitelabs", "drivercentral", "derek", "dc_pid", "cloud%-client", "buymeacoffee" }
for _, dir in ipairs(drivers) do
  for _, file in ipairs({ "driver.lua", "driver.xml", "www/documentation/index.md" }) do
    local text = (readFile("drivers/" .. dir .. "/" .. file) or ""):lower()
    for _, word in ipairs(banned) do
      T.check(string.format("%s/%s has no '%s'", dir, file, word:gsub("%%", "")), not text:find(word))
    end
  end
end

T.finish()
