--- @module "mqtt.server.c4_server"
--- Control4 glue for the built-in MQTT broker.
---
--- Listens with C4:CreateTCPServer, turns every accepted socket into a broker
--- connection, and measures controller load (timer lag, message rate). Used
--- by the MQTT Broker driver (Built-in mode) and the MQTT Server Test driver.
---
--- C4:CreateTCPServer must not be called during OnDriverInit; call start()
--- from OnDriverLateInit or later.

local C4Server = {}
C4Server.__index = C4Server

local READ_SIZE = 16384

--- @param opts table { broker, log?, maxClients?: fun():integer, onStatus?: fun(server) }
function C4Server.new(opts)
  local self = setmetatable({}, C4Server)
  self.broker = opts.broker
  self.log = opts.log
  self.maxClients = opts.maxClients or function()
    return 250
  end
  self.onStatus = opts.onStatus
  self.server = nil
  self.listening = false
  self.port = nil
  self.status = "Stopped"
  self:resetStats()
  return self
end

function C4Server:resetStats()
  self.stats = {
    rejectedMaxClients = 0,
    socketErrors = 0,
    lastSocketError = "",
    internalErrors = 0,
    lastInternalError = "",
  }
  self.lag = { last = nil, max = 0, recentMax = 0, ticks = 0 }
  self.rate = { lastCount = 0, lastTime = nil, perSecond = 0, peak = 0 }
  self.startedAt = C4:GetTime()
end

function C4Server:_log(level, fmt, ...)
  if self.log and self.log[level] then
    self.log[level](self.log, fmt, ...)
  end
end

function C4Server:_setStatus(status, listening)
  self.status = status
  self.listening = listening and true or false
  if self.onStatus then
    self.onStatus(self)
  end
end

function C4Server:_internalError(where, err)
  self.stats.internalErrors = self.stats.internalErrors + 1
  self.stats.lastInternalError = string.format("%s: %s", where, tostring(err):match("^[^\n]*"))
  self:_log("error", "%s failed: %s", where, err)
end

--- Errors of any kind since the last reset.
function C4Server:problemCount()
  local s = self.broker.stats
  return s.protocolErrors + s.slowClientsDropped + self.stats.socketErrors + self.stats.internalErrors
end

function C4Server:_accept(client)
  local broker = self.broker
  local addr = client:GetRemoteAddress() or {}
  local conn = { address = string.format("%s:%s", tostring(addr.ip or "?"), tostring(addr.port or "?")) }
  local maxClients = self.maxClients()
  if broker:connectionCount() >= maxClients then
    self.stats.rejectedMaxClients = self.stats.rejectedMaxClients + 1
    self:_log("warn", "Refusing %s: Max Clients (%d) reached", conn.address, maxClients)
    client:Close(false)
    return
  end

  conn.close = function()
    if conn.tcpClosed then
      return
    end
    conn.tcpClosed = true
    client:Close(true)
  end
  conn.send = function(bytes)
    if conn.tcpClosed then
      return
    end
    if client:Write(bytes) == nil then
      self.stats.socketErrors = self.stats.socketErrors + 1
      self.stats.lastSocketError = conn.address .. ": write refused"
      conn.close()
      broker:closed(conn, "write refused")
    end
  end

  pcall(client.Option, client, "nodelay", true)
  pcall(client.Option, client, "keepalive", true)

  client
    :OnRead(function(cli, data)
      local ok, err = xpcall(function()
        broker:data(conn, data)
      end, debug.traceback)
      if not ok then
        self:_internalError("read from " .. conn.address, err)
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
      self.stats.socketErrors = self.stats.socketErrors + 1
      self.stats.lastSocketError =
        string.format("%s: %s error %s (%s)", conn.address, tostring(op), tostring(code), tostring(msg))
      self:_log("debug", "Socket error on %s", self.stats.lastSocketError)
      if not conn.tcpClosed then
        conn.close()
      end
      broker:closed(conn, "socket error " .. tostring(code))
    end)

  broker:accept(conn)
  self:_log("debug", "Accepted connection from %s", conn.address)
  client:ReadUpTo(READ_SIZE)
end

--- Start listening (restarts if already running).
--- @param port integer
function C4Server:start(port)
  self:stop("server restarting")
  self.port = port
  self:_setStatus(string.format("Starting on port %d", port), false)
  self:_log("info", "Starting MQTT broker on port %d", port)

  local srv = C4:CreateTCPServer()
  if srv == nil then
    self:_setStatus("Error: C4:CreateTCPServer() returned nothing", false)
    self:_log("error", self.status)
    return
  end
  self.server = srv
  pcall(srv.Option, srv, "reuseaddr", true)
  srv
    :OnListen(function(s, endpoint)
      if self.server ~= srv then
        return
      end
      local addr = (s.GetLocalAddress and s:GetLocalAddress()) or endpoint or {}
      self:_setStatus(string.format("Listening on %s:%s", tostring(addr.ip or "*"), tostring(addr.port or port)), true)
      self:_log("info", "MQTT broker %s", self.status)
    end)
    :OnError(function(_, code, msg)
      if self.server ~= srv then
        return
      end
      self.server = nil
      self:_setStatus(string.format("Error %s: %s (port %d)", tostring(code), tostring(msg), port), false)
      self:_log("error", "MQTT broker: %s", self.status)
    end)
    :OnAccept(function(_, client)
      if self.server ~= srv then
        pcall(client.Close, client, false)
        return
      end
      local ok, err = xpcall(function()
        self:_accept(client)
      end, debug.traceback)
      if not ok then
        self:_internalError("accept", err)
        pcall(client.Close, client, false)
      end
    end)
  if srv:Listen("*", port) == nil then
    self.server = nil
    self:_setStatus(string.format("Error: listening on port %d was refused", port), false)
    self:_log("error", self.status)
  end
end

--- Stop listening and close every client (wills are not published).
--- @param reason string|nil
function C4Server:stop(reason)
  if self.server ~= nil then
    local srv = self.server
    self.server = nil
    pcall(srv.Close, srv)
  end
  self.broker:closeAll(reason or "server stopped")
  if self.status ~= "Stopped" then
    self:_setStatus("Stopped", false)
  end
end

--- Housekeeping; call once a second. Returns true every `statsEvery` ticks,
--- when the message rate was recalculated.
--- @param statsEvery integer|nil default 5
--- @return boolean statsDue
function C4Server:tick(statsEvery)
  statsEvery = statsEvery or 5
  local now = C4:GetTime()
  local lag = self.lag
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
  self.broker:checkTimeouts()

  if lag.ticks % statsEvery ~= 0 then
    return false
  end
  local rate = self.rate
  local count = self.broker.stats.publishesIn
  if rate.lastTime ~= nil and now > rate.lastTime then
    rate.perSecond = (count - rate.lastCount) * 1000 / (now - rate.lastTime)
    if rate.perSecond > rate.peak then
      rate.peak = rate.perSecond
    end
  end
  rate.lastCount, rate.lastTime = count, now
  return true
end

--- Forget the short-term timer lag (call after showing it).
function C4Server:clearRecentLag()
  self.lag.recentMax = 0
end

-------------------------------------------------------------------------------
-- Reports
-------------------------------------------------------------------------------

local function fmtBytes(n)
  if n >= 1024 * 1024 then
    return string.format("%.1f MB", n / 1024 / 1024)
  elseif n >= 1024 then
    return string.format("%.1f KB", n / 1024)
  end
  return string.format("%d B", n)
end
C4Server.fmtBytes = fmtBytes

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

--- Statistics as ordered { name, value } pairs.
--- @return table[]
function C4Server:report()
  local s = self.broker.stats
  local x = self.stats
  return {
    { "Server Status", self.status },
    { "Connected Clients", tostring(self.broker:clientCount()) },
    { "Open Connections", tostring(self.broker:connectionCount()) },
    { "Peak Connections", tostring(s.peakClients) },
    { "Total Connections", tostring(s.connectionsTotal) },
    { "Rejected Connections", tostring(s.connectsRejected + x.rejectedMaxClients) },
    { "Client Takeovers", tostring(s.takeovers) },
    { "Keepalive Timeouts", tostring(s.keepaliveTimeouts) },
    { "Slow Clients Dropped", tostring(s.slowClientsDropped) },
    { "Messages In", tostring(s.publishesIn) },
    { "Messages Delivered", tostring(s.messagesDelivered) },
    { "Messages per Second", string.format("%.1f (peak %.1f)", self.rate.perSecond, self.rate.peak) },
    { "Retained Messages", tostring(self.broker.retainedCount) },
    { "Wills Published", tostring(s.willsPublished) },
    { "Data In", string.format("%s in %d packets", fmtBytes(s.bytesIn), s.packetsIn) },
    { "Data Out", string.format("%s in %d packets", fmtBytes(s.bytesOut), s.packetsOut) },
    {
      "TCP Reads",
      string.format("%d (%d split packets, %d with several packets)", s.reads, s.splitReads, s.multiPacketReads),
    },
    { "Protocol Errors", tostring(s.protocolErrors) },
    { "Last Protocol Error", self.broker.lastError or "" },
    { "Socket Errors", tostring(x.socketErrors) },
    { "Last Socket Error", x.lastSocketError },
    { "Driver Errors", tostring(x.internalErrors) },
    { "Last Driver Error", x.lastInternalError },
    { "Timer Lag", string.format("%d ms now, %d ms max", self.lag.recentMax, self.lag.max) },
    { "Lua Memory", string.format("%.0f KB", collectgarbage("count")) },
    { "Running For", fmtDuration(C4:GetTime() - self.startedAt) },
  }
end

--- One line per connection, for printing.
--- @return string
function C4Server:clientsText()
  local list = self.broker:clients()
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
  return table.concat(lines, "\n")
end

--- All retained messages, for printing.
--- @return string
function C4Server:retainedText()
  local topics = {}
  for topic in pairs(self.broker.retained) do
    topics[#topics + 1] = topic
  end
  table.sort(topics)
  local lines = { string.format("==== %d retained messages ====", #topics) }
  for _, topic in ipairs(topics) do
    local payload = self.broker.retained[topic].payload
    lines[#lines + 1] = string.format("%s = %s", topic, #payload > 120 and (payload:sub(1, 120) .. "...") or payload)
  end
  return table.concat(lines, "\n")
end

return C4Server
