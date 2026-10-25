--- MQTT Server Test driver (step 0)
---
--- Hardware test for the built-in broker: listens for MQTT clients (Tasmota)
--- on a TCP port and measures what the controller can handle. It answers the
--- three step 0 questions:
---   1. Can a driver listen on the port?          -> Server Status
---   2. How many connections can one driver hold?  -> Connected / Peak Clients
---   3. Does binary MQTT data arrive intact?       -> framing and error counters
---
--- It is a working broker for testing (connect, subscribe, publish, retained,
--- Last Will), but it is not bound to other drivers. The MQTT Broker driver's
--- Built-in mode uses the same code (src/mqtt/server).

require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

local log = require("lib.logging")
local Broker = require("mqtt.server.broker")
local C4Server = require("mqtt.server.c4_server")

--- @type table
local broker
--- @type table
local server

local function prop(name, default)
  local v = Properties[name]
  if v == nil or v == "" then
    return default
  end
  return v
end

local function updateStatsProperties()
  for _, row in ipairs(server:report()) do
    UpdateProperty(row[1], row[2])
  end
  UpdateProperty(
    "Test Summary",
    string.format(
      "%d clients (peak %d), %d problems, max timer lag %d ms",
      broker:clientCount(),
      broker.stats.peakClients,
      server:problemCount(),
      server.lag.max
    )
  )
end

local function startServer()
  server:start(tonumber(prop("Listen Port", "3883")) or 3883)
end

-----------------------------------------------------------------------
-- Driver lifecycle
-----------------------------------------------------------------------

function OnDriverInit()
  C4:AllowExecute(true)
  gInitialized = false
  log:setLogName(C4:GetDeviceData(C4:GetDeviceID(), "name"))
  log:setLogLevel(Properties["Log Level"])
  log:setLogMode(Properties["Log Mode"])
  broker = Broker.new({
    now = function()
      return C4:GetTime()
    end,
    log = log,
    onPublish = function(topic, payload, retain, clientId)
      if Properties["Log Messages"] == "On" then
        log:print(
          "%s -> %s%s: %s",
          tostring(clientId or "driver"),
          topic,
          retain and " (retained)" or "",
          #payload > 200 and (payload:sub(1, 200) .. "...") or payload
        )
      end
    end,
  })
  server = C4Server.new({
    broker = broker,
    log = log,
    maxClients = function()
      return tonumber(prop("Max Clients", "250")) or 250
    end,
    onStatus = function(s)
      UpdateProperty("Server Status", s.status)
      if s.listening then
        log:print("MQTT test server: %s", s.status)
      end
    end,
  })
end

function OnDriverLateInit()
  log:trace("OnDriverLateInit()")
  for p, _ in pairs(Properties) do
    local status, err = pcall(OnPropertyChanged, p)
    if not status and err ~= nil then
      log:error(err)
    end
  end
  gInitialized = true
  local info = C4.GetVersionInfo and C4:GetVersionInfo() or {}
  UpdateProperty("Controller OS", tostring(info.version or "?"))
  UpdateProperty("Driver Version", C4:GetDriverConfigInfo("version") or "")
  server:resetStats()
  SetTimer("Housekeeping", 1000, function()
    local ok, err = xpcall(function()
      if server:tick(5) then
        updateStatsProperties()
        server:clearRecentLag()
      end
    end, debug.traceback)
    if not ok then
      log:error("Housekeeping failed: %s", err)
    end
  end, true)
  startServer()
end

function OnDriverDestroyed()
  CancelTimer("Housekeeping")
  server:stop("driver removed")
end

-----------------------------------------------------------------------
-- Properties and actions
-----------------------------------------------------------------------

function OPC.Log_Mode(propertyValue)
  log:setLogMode(propertyValue)
  CancelTimer("LogMode")
  if not log:isEnabled() then
    return
  end
  log:warn("Log mode '%s' will expire in 3 hours", propertyValue)
  SetTimer("LogMode", 3 * ONE_HOUR, function()
    log:warn("Setting log mode to 'Off' (timer expired)")
    UpdateProperty("Log Mode", "Off", true)
  end)
end

function OPC.Log_Level(propertyValue)
  log:setLogLevel(propertyValue)
end

function OPC.Listen_Port(_)
  if gInitialized then
    startServer()
  end
end

function EC.PrintReport()
  updateStatsProperties()
  local lines = { "==== MQTT Server Test report ====" }
  for _, name in ipairs({ "Controller OS", "Driver Version", "Test Summary" }) do
    lines[#lines + 1] = string.format("%-22s %s", name .. ":", tostring(Properties[name] or ""))
  end
  for _, row in ipairs(server:report()) do
    lines[#lines + 1] = string.format("%-22s %s", row[1] .. ":", row[2])
  end
  lines[#lines + 1] = "================================="
  print(table.concat(lines, "\n"))
end

function EC.PrintClients()
  print(server:clientsText())
end

function EC.PrintRetained()
  print(server:retainedText())
end

function EC.ResetStatistics()
  broker:resetStats()
  server:resetStats()
  updateStatsProperties()
  log:print("Statistics reset")
end

function EC.DisconnectAllClients()
  broker:closeAll("disconnected from Composer")
  updateStatsProperties()
  log:print("All clients disconnected")
end

function EC.RestartServer()
  startServer()
end

function EC.PublishTest(tParams)
  local topic = Select(tParams, "Topic")
  local payload = Select(tParams, "Payload") or ""
  if IsEmpty(topic) then
    log:print("Publish Test needs a topic")
    return
  end
  if broker:publish(topic, payload, false) then
    log:print("Published %s: %s", topic, payload)
  else
    log:print("Not a valid topic: %s", topic)
  end
end
