-- Tests that a driver update says in the log when it starts and whether it
-- worked: the broker's Update Drivers action, then the check after the
-- drivers restart.
--
-- Run from the repo root:
--   make test
-- or:
--   ./test/run_test.sh test_update_log.lua

local T = require("testlib")
require("c4_shim")
require("drivers-common-public.global.lib")
local deferred = require("deferred")

-- A fake updater: each test says what updateAll answers.
local answer
local updater = { calls = {} }
function updater:updateAll(repo, files, prerelease, force)
  self.calls[#self.calls + 1] = { repo = repo, force = force }
  self.lastRelease = answer.release
  if answer.error then
    return deferred.new():reject(answer.error)
  end
  return deferred.new():resolve(answer.updated)
end
package.loaded["lib.github-updater"] = updater

local realGetDriverConfigInfo = C4.GetDriverConfigInfo
C4.GetDriverConfigInfo = function(c4, section)
  if section == "minimum_os_version" then
    return "3.3.0"
  end
  return realGetDriverConfigInfo(c4, section)
end
C4.CreateTCPServer = function()
  error("not used")
end

ShimSetDevices({
  [12345] = { deviceName = "MQTT Broker", driverFileName = "cp_mqtt_broker.c4z" },
  [101] = { deviceName = "Hall", driverFileName = "cp_mqtt_light.c4z" },
  [201] = { deviceName = "Sensors", driverFileName = "cp_mqtt_general.c4z" },
})
-- Make the drivers it binds count as connected so start-up stays quiet.
local versions = {
  ["cp_mqtt_broker.c4z"] = "2026102502",
  ["cp_mqtt_light.c4z"] = "2026102502",
  ["cp_mqtt_general.c4z"] = "2026102502",
}

local xml = assert(io.open("drivers/cp_mqtt_broker/driver.xml")):read("*a")
for block in xml:gmatch("<property>(.-)</property>") do
  Properties[block:match("<name>(.-)</name>")] = block:match("<default>(.-)</default>") or ""
end
Properties["Log Level"] = "2 - Warning"
Properties["Automatic Updates"] = "Off"

local function start()
  return T.capture(function()
    dofile("drivers/cp_mqtt_broker/driver.lua")
    GetDriverVersion = function(filename)
      return versions[filename]
    end
    OnDriverInit()
    OnDriverLateInit()
  end)
end
local ok, err = start()
T.check("the broker starts", ok, err)

local release = { tag_name = "v2026102600" }

T.section("Update Drivers: start and hand-over to the controller")
answer = { release = release, updated = { "cp_mqtt_light.c4z", "cp_mqtt_general.c4z", "cp_mqtt_broker.c4z" } }
local ran, runErr, out = T.capture(function()
  ExecuteCommand("LUA_ACTION", { ACTION = "UpdateDrivers" })
end)
T.check("runs without error", ran, runErr)
T.eq("a forced update", updater.calls[#updater.calls].force, true)
T.contains("says it started", out, "Update started: checking krishy2/control4-mqtt")
T.contains("with the installed versions", out, "cp_mqtt_light.c4z 2026102502")
T.contains("says what was sent", out, "Update: v2026102600 downloaded and sent to the controller")

T.section("After the restart: success")
versions["cp_mqtt_broker.c4z"] = "2026102600"
versions["cp_mqtt_light.c4z"] = "2026102600"
versions["cp_mqtt_general.c4z"] = "2026102600"
local _, _, restartOut = start()
T.excludes("not reported before the others had time", restartOut, "succeeded")
local _, _, verifyOut = T.capture(function()
  ShimFireTimers()
end)
T.contains("reports success", verifyOut, "Update to v2026102600 succeeded")
T.contains("names the version", verifyOut, "on version 2026102600")
local _, _, againOut = T.capture(function()
  start()
  ShimFireTimers()
end)
T.excludes("reported once only", againOut, "Update to v2026102600")

T.section("After the restart: a driver did not update")
answer = { release = { tag_name = "v2026102601" }, updated = { "cp_mqtt_light.c4z", "cp_mqtt_broker.c4z" } }
T.capture(function()
  ExecuteCommand("LUA_ACTION", { ACTION = "UpdateDrivers" })
end)
versions["cp_mqtt_broker.c4z"] = "2026102601"
local _, _, failOut = T.capture(function()
  start()
  ShimFireTimers()
end)
T.contains("reports the failure", failOut, "Update to v2026102601 FAILED")
T.contains("and which driver", failOut, "cp_mqtt_light.c4z is on 2026102600")

T.section("Nothing to do, or GitHub fails")
answer = { release = { tag_name = "v2026102601" }, updated = {} }
local _, _, noneOut = T.capture(function()
  UpdateDrivers(false, true)
end)
T.contains("already up to date", noneOut, "already on the latest release v2026102601")
answer = { error = "HTTP 503" }
local _, _, errOut = T.capture(function()
  ExecuteCommand("LUA_ACTION", { ACTION = "UpdateDrivers" })
end)
T.contains("a failed check is reported", errOut, "Update FAILED: HTTP 503")
answer = { error = { "asset a failed", "asset b failed" } }
local _, _, errOut2 = T.capture(function()
  ExecuteCommand("LUA_ACTION", { ACTION = "UpdateDrivers" })
end)
T.contains("several errors are listed", errOut2, "asset a failed")

T.finish()
