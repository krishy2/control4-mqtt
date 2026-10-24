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
--- Last Will), but it is not bound to other drivers. That is step 1.

require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

local log = require("lib.logging")
local Broker = require("mqtt.server.broker")

local READ_SIZE = 16384
local STATS_INTERVAL_MS = 5000

--- @type table|nil
local server = nil
--- @type table
local broker
local serverStatus = "Stopped"
local driverStarted = 0
local extra = {
  rejectedMaxClients = 0,
  socketErrors = 0,
  lastSocketError = "",
  internalErrors = 0,
  lastInternalError = "",
}
local lag = { last = nil, max = 0, recentMax = 0, ticks = 0 }
local rate = { lastCount = 0, lastTime = nil, perSecond = 0, peak = 0 }

local function nowMs()
  return C4:GetTime()
end

local function prop(name, default)
  local v = Properties[name]
  if v == nil or v == "" then
    return default
  end
  return v
end

local function fmtBytes(n)
  if n >= 1024 * 1024 then
    return string.format("%.1f MB", n / 1024 / 1024)
  elseif n >= 1024 then
    return string.format("%.1f KB", n / 1024)
  end
  return string.format("%d B", n)
end

local function fmtDuration(ms)
  local s = math.floor(ms / 1000)
  return string.format(
    "%dd %02d:%02d:%02d",
    math.floor(s / 86400),
    math.floor(s / 3600) % 24,
    math.floor(s / 60) % 60,
    s % 60
  )
end

-----------------------------------------------------------------------
-- Statistics
-----------------------------------------------------------------------

local function summaryLine()
  local s = broker.stats
  local problems = s.protocolErrors + extra.socketErrors + extra.internalErrors + s.slowClientsDropped
  return string.format(
    "%d clients (peak %d), %d problems, max timer lag %d ms",
    broker:clientCount(),
    s.peakClients,
    problems,
    lag.max
  )
end

local function updateStatsProperties()
  local s = broker.stats
  UpdateProperty("Server Status", serverStatus)
  UpdateProperty("Test Summary", summaryLine())
  UpdateProperty("Connected Clients", tostring(broker:clientCount()))
  UpdateProperty("Open Connections", tostring(broker:connectionCount()))
  UpdateProperty("Peak Connections", tostring(s.peakClients))
  UpdateProperty("Total Connections", tostring(s.connectionsTotal))
  UpdateProperty("Rejected Connections", tostring(s.connectsRejected + extra.rejectedMaxClients))
  UpdateProperty("Client Takeovers", tostring(s.takeovers))
  UpdateProperty("Messages In", tostring(s.publishesIn))
  UpdateProperty("Messages Delivered", tostring(s.messagesDelivered))
  UpdateProperty("Messages per Second", string.format("%.1f (peak %.1f)", rate.perSecond, rate.peak))
  UpdateProperty("Retained Messages", tostring(broker.retainedCount))
  UpdateProperty("Wills Published", tostring(s.willsPublished))
  UpdateProperty("Data In", string.format("%s in %d packets", fmtBytes(s.bytesIn), s.packetsIn))
  UpdateProperty("Data Out", string.format("%s in %d packets", fmtBytes(s.bytesOut), s.packetsOut))
  UpdateProperty(
    "TCP Reads",
    string.format("%d (%d split packets, %d with several packets)", s.reads, s.splitReads, s.multiPacketReads)
  )
  UpdateProperty("Protocol Errors", tostring(s.protocolErrors))
  UpdateProperty("Last Protocol Error", broker.lastError or "")
  UpdateProperty("Socket Errors", tostring(extra.socketErrors))
  UpdateProperty("Last Socket Error", extra.lastSocketError)
  UpdateProperty("Keepalive Timeouts", tostring(s.keepaliveTimeouts))
  UpdateProperty("Slow Clients Dropped", tostring(s.slowClientsDropped))
  UpdateProperty("Driver Errors", tostring(extra.internalErrors))
  UpdateProperty("Last Driver Error", extra.lastInternalError)
  UpdateProperty("Timer Lag", string.format("%d ms now, %d ms max", lag.recentMax, lag.max))
  UpdateProperty("Lua Memory", string.format("%.0f KB", collectgarbage("count")))
  UpdateProperty("Running For", fmtDuration(nowMs() - driverStarted))
end

local function resetStats()
  broker:resetStats()
  extra.rejectedMaxClients = 0
  extra.socketErrors = 0
  extra.lastSocketError = ""
  extra.internalErrors = 0
  extra.lastInternalError = ""
  lag.max = 0
  lag.recentMax = 0
  rate.lastCount = 0
  rate.lastTime = nowMs()
  rate.perSecond = 0
  rate.peak = 0
  driverStarted = nowMs()
end

local function internalError(where, err)
  extra.internalErrors = extra.internalErrors + 1
  extra.lastInternalError = string.format("%s: %s", where, tostring(err):match("^[^\n]*"))
  log:error("%s failed: %s", where, err)
end

-----------------------------------------------------------------------
-- TCP server
-----------------------------------------------------------------------

local function onAccept(_, client)
  local ok, err = xpcall(function()
    local addr = client:GetRemoteAddress() or {}
    local conn = { address = string.format("%s:%s", tostring(addr.ip or "?"), tostring(addr.port or "?")) }
    local maxClients = tonumber(prop("Max Clients", "250")) or 250
    if broker:connectionCount() >= maxClients then
      extra.rejectedMaxClients = extra.rejectedMaxClients + 1
      log:warn("Refusing %s: Max Clients (%d) reached", conn.address, maxClients)
      client:Close(false)
      return
    end

    conn.send = function(bytes)
      if conn.tcpClosed then
        return
      end
      if client:Write(bytes) == nil then
        extra.socketErrors = extra.socketErrors + 1
        extra.lastSocketError = conn.address .. ": write refused"
        conn.close()
        broker:closed(conn, "write refused")
      end
    end
    conn.close = function()
      if conn.tcpClosed then
        return
      end
      conn.tcpClosed = true
      client:Close(true)
    end

    pcall(client.Option, client, "nodelay", true)
    pcall(client.Option, client, "keepalive", true)

    client
      :OnRead(function(cli, data)
        local readOk, readErr = xpcall(function()
          broker:data(conn, data)
        end, debug.traceback)
        if not readOk then
          internalError("read from " .. conn.address, readErr)
          broker:drop(conn, "driver error")
          return
        end
        if not conn.tcpClosed then
          cli:ReadUpTo(READ_SIZE)
        end
      end)
      :OnWrite(function()
        broker:writeComplete(conn)
      end)
      :OnDisconnect(function(_, code, msg)
        conn.tcpClosed = true
        local reason = (code == 0 or code == nil) and "closed by client"
          or string.format("socket error %s (%s)", tostring(code), tostring(msg))
        broker:closed(conn, reason)
      end)
      :OnError(function(_, code, msg, op)
        extra.socketErrors = extra.socketErrors + 1
        extra.lastSocketError =
          string.format("%s: %s error %s (%s)", conn.address, tostring(op), tostring(code), tostring(msg))
        log:debug("Socket error on %s", extra.lastSocketError)
        if not conn.tcpClosed then
          conn.close()
        end
        broker:closed(conn, "socket error " .. tostring(code))
      end)

    broker:accept(conn)
    log:debug("Accepted connection from %s", conn.address)
    client:ReadUpTo(READ_SIZE)
  end, debug.traceback)
  if not ok then
    internalError("accept", err)
    pcall(client.Close, client, false)
  end
end

local function stopServer(reason)
  if server ~= nil then
    pcall(server.Close, server)
    server = nil
  end
  if broker ~= nil then
    broker:closeAll(reason or "server stopped")
  end
  serverStatus = "Stopped"
end

local function startServer()
  stopServer("server restarting")
  local port = tonumber(prop("Listen Port", "3883")) or 3883
  serverStatus = string.format("Starting on port %d", port)
  log:info("Starting MQTT test server on port %d", port)

  local srv = C4:CreateTCPServer()
  if srv == nil then
    serverStatus = "Error: C4:CreateTCPServer() returned nothing"
    log:error(serverStatus)
    return
  end
  server = srv
  pcall(srv.Option, srv, "reuseaddr", true)
  srv
    :OnListen(function(s, endpoint)
      local addr = (s.GetLocalAddress and s:GetLocalAddress()) or endpoint or {}
      serverStatus = string.format("Listening on %s:%s", tostring(addr.ip or "*"), tostring(addr.port or port))
      log:print("MQTT test server: %s", serverStatus)
      updateStatsProperties()
    end)
    :OnError(function(_, code, msg)
      serverStatus = string.format("Error %s: %s (port %d)", tostring(code), tostring(msg), port)
      log:error("MQTT test server: %s", serverStatus)
      if server == srv then
        server = nil
      end
      updateStatsProperties()
    end)
    :OnAccept(onAccept)
  if srv:Listen("*", port) == nil then
    serverStatus = string.format("Error: Listen on port %d was refused", port)
    log:error(serverStatus)
    server = nil
  end
  updateStatsProperties()
end

-----------------------------------------------------------------------
-- Housekeeping: keepalive, timer lag, message rate
-----------------------------------------------------------------------

local function tick()
  local ok, err = xpcall(function()
    local now = nowMs()
    if lag.last ~= nil then
      local l = math.max(0, now - lag.last - 1000)
      if l > lag.max then
        lag.max = l
      end
      if l > lag.recentMax then
        lag.recentMax = l
      end
    end
    lag.last = now
    lag.ticks = lag.ticks + 1
    broker:checkTimeouts()

    if lag.ticks % (STATS_INTERVAL_MS / 1000) == 0 then
      local count = broker.stats.publishesIn
      if rate.lastTime ~= nil and now > rate.lastTime then
        rate.perSecond = (count - rate.lastCount) * 1000 / (now - rate.lastTime)
        if rate.perSecond > rate.peak then
          rate.peak = rate.perSecond
        end
      end
      rate.lastCount, rate.lastTime = count, now
      updateStatsProperties()
      lag.recentMax = 0
    end
  end, debug.traceback)
  if not ok then
    internalError("housekeeping", err)
  end
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
    now = nowMs,
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
  driverStarted = nowMs()
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
  resetStats()
  SetTimer("Housekeeping", 1000, tick, true)
  startServer()
end

function OnDriverDestroyed()
  CancelTimer("Housekeeping")
  stopServer("driver removed")
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
  local names = {
    "Controller OS",
    "Driver Version",
    "Server Status",
    "Test Summary",
    "Connected Clients",
    "Open Connections",
    "Peak Connections",
    "Total Connections",
    "Rejected Connections",
    "Client Takeovers",
    "Messages In",
    "Messages Delivered",
    "Messages per Second",
    "Retained Messages",
    "Wills Published",
    "Data In",
    "Data Out",
    "TCP Reads",
    "Protocol Errors",
    "Last Protocol Error",
    "Socket Errors",
    "Last Socket Error",
    "Keepalive Timeouts",
    "Slow Clients Dropped",
    "Driver Errors",
    "Last Driver Error",
    "Timer Lag",
    "Lua Memory",
    "Running For",
  }
  for _, name in ipairs(names) do
    lines[#lines + 1] = string.format("%-22s %s", name .. ":", tostring(Properties[name] or ""))
  end
  lines[#lines + 1] = "================================="
  print(table.concat(lines, "\n"))
end

function EC.PrintClients()
  local list = broker:clients()
  local lines = { string.format("==== %d connections ====", #list) }
  lines[#lines + 1] = string.format(
    "%-28s %-21s %5s %7s %5s %4s %6s %6s %4s",
    "Client ID",
    "Address",
    "KA",
    "Online",
    "Idle",
    "Subs",
    "In",
    "Out",
    "Will"
  )
  for _, c in ipairs(list) do
    lines[#lines + 1] = string.format(
      "%-28s %-21s %5d %6ds %4ds %4d %6d %6d %4s",
      c.clientId:sub(1, 28),
      c.address,
      c.keepAlive,
      c.connectedSeconds,
      c.idleSeconds,
      c.subscriptions,
      c.messagesIn,
      c.messagesOut,
      c.hasWill and "yes" or "no"
    )
  end
  print(table.concat(lines, "\n"))
end

function EC.PrintRetained()
  local topics = {}
  for topic in pairs(broker.retained) do
    topics[#topics + 1] = topic
  end
  table.sort(topics)
  local lines = { string.format("==== %d retained messages ====", #topics) }
  for _, topic in ipairs(topics) do
    local payload = broker.retained[topic].payload
    lines[#lines + 1] = string.format("%s = %s", topic, #payload > 120 and (payload:sub(1, 120) .. "...") or payload)
  end
  print(table.concat(lines, "\n"))
end

function EC.ResetStatistics()
  resetStats()
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
