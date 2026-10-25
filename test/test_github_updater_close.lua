-- Tests that updateAll keeps the UpdateProjectC4i socket open until every
-- driver it sends has been written. Closing right after the last Write could
-- drop that last message, which is the running driver's own update: the MQTT
-- Broker stayed a version behind while the drivers sent before it updated.
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

T.section("Writes not confirmed yet")
local tcp = F.captureTcpClient()
local result
updater:updateAll("krishy2/control4-mqtt", { RUNNING, COMPANION }, false, false):next(function(r)
  result = r
end)
T.eq("both drivers are written", #tcp.writes, 2)
T.eq("the update is reported", result and #result, 2)
T.eq("the socket stays open", tcp.closedAfter, nil)
tcp.client._onWrite(tcp.client)
T.eq("one confirmed: still open", tcp.closedAfter, nil)
tcp.client._onWrite(tcp.client)
T.eq("both confirmed: closed", tcp.closedAfter, 2)
tcp.restore()

T.section("Writes confirmed at once")
tcp = F.captureTcpClient()
tcp.confirmWrites = true
updater:updateAll("krishy2/control4-mqtt", { RUNNING, COMPANION }, false, false)
T.eq("closed after the last write", tcp.closedAfter, 2)
tcp.restore()

T.section("No confirmation at all")
tcp = F.captureTcpClient()
updater:updateAll("krishy2/control4-mqtt", { RUNNING, COMPANION }, false, false)
T.eq("open at first", tcp.closedAfter, nil)
ShimFireTimers()
T.eq("closed by the timer", tcp.closedAfter, 2)
tcp.restore()

T.finish()
