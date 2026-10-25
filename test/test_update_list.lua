-- Tests that the MQTT Broker's GitHub updater covers every driver in this repo.
--
-- The broker updates all installed drivers from one GitHub release. A driver
-- missing from DRIVER_FILENAMES never auto-updates, so adding a driver under
-- drivers/ without listing it here fails this test.
--
-- Run from the repo root:
--   make test
-- or:
--   ./test/run_test.sh test_update_list.lua

local T = require("testlib")

local function readFile(path)
  local fh = assert(io.open(path, "r"))
  local body = fh:read("*a")
  fh:close()
  return body
end

local src = readFile("drivers/cp_mqtt_broker/driver.lua")
local listed = {}
local block = src:match("DRIVER_FILENAMES%s*=%s*(%b{})")
T.check("the broker declares DRIVER_FILENAMES", block ~= nil)
for name in (block or ""):gmatch('"([^"]+)"') do
  listed[name] = true
end

T.section("every driver in drivers/ is in the broker's update list")
local pipe = assert(io.popen("ls drivers"))
for dir in pipe:lines() do
  local filename = dir .. ".c4z"
  T.check(
    filename .. " is listed",
    listed[filename] == true,
    "add it to DRIVER_FILENAMES in drivers/cp_mqtt_broker/driver.lua"
  )
  listed[filename] = nil
end
pipe:close()
T.check("no listed driver is missing from drivers/", next(listed) == nil, tostring(next(listed)))

T.section("updates come from this repository")
T.contains("DRIVER_GITHUB_REPO", src, 'DRIVER_GITHUB_REPO = "krishy2/control4-mqtt"')

T.section("Version numbers the updater compares (YYYYMMDDNN)")
local version = require("version")
T.check("a 10-digit release is newer than the old 8-digit versions", version("v2026102500") > version("20261032"))
T.check("a second release the same day is newer", version("v2026102501") > version("2026102500"))
T.check("the next day is newer than the last number of a day", version("v2026102600") > version("2026102599"))
T.check("the installed version is not an update to itself", not (version("v2026102500") > version("2026102500")))
T.check("versions fit Control4's 32-bit version field until 2147", 2147123199 < 2147483647)

T.finish()
