-- Tests that updateAll keeps the UpdateProjectC4i socket open while the
-- controller carries the requests out. Closing once they were written (even
-- confirmed by OnWrite) dropped the last one, the running driver's own update:
-- the MQTT Broker stayed a version behind while the drivers sent before it
-- updated.
--
-- Run from the repo root:
--   make test
-- or:
--   ./test/run_test.sh test_github_updater_close.lua

local T = require("testlib")
local F = require("c4_fixtures")

local updater = require("lib.github-updater")
require("drivers-common-public.global.lib")
JSON = require("JSON")
local deferred = require("deferred")
local semver = require("version")
local http = require("lib.http")

local RUNNING = C4:GetDriverFileName()
local COMPANION = "example_companion_a.c4z"
C4.GetDevicesByC4iName = function()
  return { 1 }
end
GetDriverVersion = function()
  return "1.0.0"
end
updater.getLatestRelease = function()
  return deferred.new():resolve({
    version = semver("2.0.0"),
    assets = {
      { name = RUNNING, browser_download_url = "https://example.invalid/self" },
      { name = COMPANION, browser_download_url = "https://example.invalid/a" },
    },
  })
end
http.get = function()
  return deferred.new():resolve({ body = "payload" })
end

T.section("The socket stays open while the controller carries the updates out")
local tcp = F.captureTcpClient()
local result
updater:updateAll("krishy2/control4-mqtt", { RUNNING, COMPANION }, false, false):next(function(r)
  result = r
end)
T.eq("both drivers are sent", #tcp.writes, 2)
T.eq("the update is reported", result and #result, 2)
T.check("the running driver's own update is sent last", tcp.writes[2]:find(RUNNING, 1, true) ~= nil, tcp.writes[2])
tcp.client._onWrite(tcp.client)
tcp.client._onWrite(tcp.client)
T.eq("written is not done: still open after both writes", tcp.closedAfter, nil)
ShimFireTimers()
T.eq("closed by the timer", tcp.closedAfter, 2)
tcp.restore()

T.section("Writes confirmed at once")
tcp = F.captureTcpClient()
tcp.confirmWrites = true
updater:updateAll("krishy2/control4-mqtt", { RUNNING, COMPANION }, false, false)
T.eq("still open", tcp.closedAfter, nil)
ShimFireTimers()
T.eq("closed by the timer", tcp.closedAfter, 2)
tcp.restore()

T.finish()
