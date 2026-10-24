--- @module "mqtt.server.broker"
--- A small MQTT 3.1 / 3.1.1 broker for a trusted home network.
---
--- Transport-agnostic: the driver creates one connection object per TCP
--- client with `send(bytes)` and `close()` functions, then feeds the broker
--- events. Nothing here calls Control4 APIs, so it is unit tested directly.
---
--- Scope (what Tasmota needs, see the step 0 notes):
---   - CONNECT / CONNACK for protocol levels 3 (MQIsdp) and 4 (MQTT)
---   - no authentication: username and password are accepted and ignored
---   - SUBSCRIBE / UNSUBSCRIBE with + and # wildcards, granted at QoS 0
---   - PUBLISH in at QoS 0, 1 (PUBACK) and 2 (PUBREC/PUBCOMP); out at QoS 0
---   - retained messages (in memory), Last Will, keepalive timeout
---   - a second connection with the same client id replaces the first
---   - no persistent sessions: every session starts clean

local Codec = require("mqtt.server.codec")

local Broker = {}
Broker.__index = Broker

--- Close a client whose unsent output exceeds this many bytes.
Broker.MAX_PENDING_OUTPUT = 1024 * 1024

--- @param opts table|nil { now?: fun():number (ms), log?: table, onPublish?: fun(topic, payload, retain, clientId) }
function Broker.new(opts)
  opts = opts or {}
  local self = setmetatable({}, Broker)
  self.now = opts.now or function()
    return os.time() * 1000
  end
  self.log = opts.log
  self.onPublish = opts.onPublish
  self.onClientsChanged = opts.onClientsChanged
  self.connections = {} -- conn -> true
  self.byClientId = {} -- clientId -> conn
  self.retained = {} -- topic -> { payload, levels }
  self.retainedCount = 0
  self.exactSubs = {} -- topic -> { conn -> true }
  self.wildSubs = {} -- filter -> { levels, conns = { conn -> true } }
  self.generatedIds = 0
  self:resetStats()
  return self
end

function Broker:resetStats()
  self.stats = {
    connectionsTotal = 0,
    connectsAccepted = 0,
    connectsRejected = 0,
    takeovers = 0,
    peakClients = 0,
    packetsIn = 0,
    packetsOut = 0,
    bytesIn = 0,
    bytesOut = 0,
    publishesIn = 0,
    messagesDelivered = 0,
    willsPublished = 0,
    keepaliveTimeouts = 0,
    protocolErrors = 0,
    slowClientsDropped = 0,
    reads = 0,
    splitReads = 0,
    multiPacketReads = 0,
  }
  self.lastError = nil
end

function Broker:_log(level, fmt, ...)
  local log = self.log
  if log and log[level] then
    log[level](log, fmt, ...)
  end
end

--- Number of connections that completed CONNECT.
function Broker:clientCount()
  local n = 0
  for conn in pairs(self.connections) do
    if conn.clientId then
      n = n + 1
    end
  end
  return n
end

--- Number of open TCP connections (including ones that have not sent CONNECT).
function Broker:connectionCount()
  local n = 0
  for _ in pairs(self.connections) do
    n = n + 1
  end
  return n
end

-------------------------------------------------------------------------------
-- Connection lifecycle
-------------------------------------------------------------------------------

--- Register a new TCP connection.
--- @param conn table { send = fun(bytes), close = fun(), address? = string }
function Broker:accept(conn)
  conn.reader = Codec.reader()
  conn.subs = {}
  conn.lastActivity = self.now()
  conn.connectedAt = conn.lastActivity
  conn.pendingOutput = 0
  conn.qos2 = {}
  conn.messagesIn = 0
  conn.messagesOut = 0
  self.connections[conn] = true
  self.stats.connectionsTotal = self.stats.connectionsTotal + 1
  local n = self:connectionCount()
  if n > self.stats.peakClients then
    self.stats.peakClients = n
  end
  self:_clientsChanged()
end

function Broker:_clientsChanged()
  if self.onClientsChanged then
    self.onClientsChanged(self)
  end
end

--- Write bytes to a connection.
function Broker:_send(conn, bytes)
  if conn.closed then
    return
  end
  self.stats.packetsOut = self.stats.packetsOut + 1
  self.stats.bytesOut = self.stats.bytesOut + #bytes
  conn.pendingOutput = (conn.pendingOutput or 0) + #bytes
  if conn.pendingOutput > Broker.MAX_PENDING_OUTPUT then
    self.stats.slowClientsDropped = self.stats.slowClientsDropped + 1
    self:_log("warn", "Dropping %s: %d bytes waiting to be sent", self:describe(conn), conn.pendingOutput)
    self:drop(conn, "slow client")
    return
  end
  conn.send(bytes)
end

--- The transport reports everything queued for a connection was written.
function Broker:writeComplete(conn)
  conn.pendingOutput = 0
end

--- Human-readable name for logs.
function Broker:describe(conn)
  return string.format("%s (%s)", conn.clientId or "?", conn.address or "?")
end

--- Remove a connection's subscriptions.
function Broker:_unsubscribeAll(conn)
  for filter in pairs(conn.subs) do
    self:_removeSub(conn, filter)
  end
  conn.subs = {}
end

--- Tear down a connection. Publishes its Will unless it said DISCONNECT.
--- @param conn table
--- @param reason string
--- @param publishWill boolean|nil default true
function Broker:_teardown(conn, reason, publishWill)
  if conn.closed then
    return
  end
  conn.closed = true
  self.connections[conn] = nil
  if conn.clientId and self.byClientId[conn.clientId] == conn then
    self.byClientId[conn.clientId] = nil
  end
  self:_unsubscribeAll(conn)
  if conn.clientId then
    self:_log("info", "Client %s disconnected: %s", self:describe(conn), reason)
  end
  local will = conn.will
  conn.will = nil
  if will and publishWill ~= false then
    self.stats.willsPublished = self.stats.willsPublished + 1
    self:_log("debug", "Publishing will of %s to %s", self:describe(conn), will.topic)
    self:_publish(will.topic, will.payload, will.retain, conn.clientId)
  end
  self:_clientsChanged()
end

--- Close a connection from the broker side (protocol error, timeout, takeover).
function Broker:drop(conn, reason)
  if conn.closed then
    return
  end
  self:_teardown(conn, reason, true)
  conn.close()
end

--- The transport reports the TCP connection closed.
function Broker:closed(conn, reason)
  self:_teardown(conn, reason or "connection closed", true)
end

-------------------------------------------------------------------------------
-- Incoming data
-------------------------------------------------------------------------------

--- Feed bytes read from a connection.
--- @param conn table
--- @param data string
function Broker:data(conn, data)
  if conn.closed then
    return
  end
  local stats = self.stats
  stats.bytesIn = stats.bytesIn + #data
  conn.lastActivity = self.now()

  local reader = conn.reader
  local beforeSplit, beforeMulti = reader.stats.splitReads, reader.stats.multiPacketReads
  local packets, err = reader:feed(data)
  stats.reads = stats.reads + 1
  stats.splitReads = stats.splitReads + (reader.stats.splitReads - beforeSplit)
  stats.multiPacketReads = stats.multiPacketReads + (reader.stats.multiPacketReads - beforeMulti)

  for _, raw in ipairs(packets) do
    if conn.closed then
      return
    end
    stats.packetsIn = stats.packetsIn + 1
    local p, decodeErr = Codec.decode(raw.first, raw.body)
    if p == nil then
      self:_protocolError(conn, "undecodable packet: " .. tostring(decodeErr))
      return
    end
    self:_handle(conn, p)
  end
  if err and not conn.closed then
    self:_protocolError(conn, err)
  end
end

function Broker:_protocolError(conn, err)
  self.stats.protocolErrors = self.stats.protocolErrors + 1
  self.lastError = string.format("%s: %s", self:describe(conn), err)
  self:_log("warn", "Protocol error from %s: %s", self:describe(conn), err)
  self:drop(conn, "protocol error")
end

function Broker:_handle(conn, p)
  local T = Codec
  if conn.clientId == nil and p.type ~= T.CONNECT then
    return self:_protocolError(conn, "first packet was " .. (T.TYPE_NAMES[p.type] or "?") .. ", not CONNECT")
  end
  if p.type == T.CONNECT then
    return self:_onConnect(conn, p)
  elseif p.type == T.PUBLISH then
    return self:_onPublish(conn, p)
  elseif p.type == T.SUBSCRIBE then
    return self:_onSubscribe(conn, p)
  elseif p.type == T.UNSUBSCRIBE then
    return self:_onUnsubscribe(conn, p)
  elseif p.type == T.PINGREQ then
    return self:_send(conn, Codec.pingresp())
  elseif p.type == T.PUBREL then
    conn.qos2[p.packetId] = nil
    return self:_send(conn, Codec.pubcomp(p.packetId))
  elseif p.type == T.DISCONNECT then
    conn.will = nil
    self:_teardown(conn, "client disconnected", false)
    conn.close()
    return
  elseif p.type == T.PUBACK or p.type == T.PUBREC or p.type == T.PUBCOMP then
    return -- we only send QoS 0, nothing to acknowledge
  end
  return self:_protocolError(conn, "unexpected " .. (T.TYPE_NAMES[p.type] or tostring(p.type)))
end

function Broker:_onConnect(conn, p)
  if conn.clientId ~= nil then
    return self:_protocolError(conn, "second CONNECT")
  end
  local level = p.protocolLevel
  if not ((p.protocolName == "MQTT" and level == 4) or (p.protocolName == "MQIsdp" and level == 3)) then
    self.stats.connectsRejected = self.stats.connectsRejected + 1
    self:_log("warn", "Rejected connection from %s: protocol %s level %s", conn.address or "?", p.protocolName, level)
    -- MQTT 5 clients would expect a v5 CONNACK; a v3 code 1 is the closest answer.
    self:_send(conn, Codec.connack(false, Codec.CONNACK_BAD_PROTOCOL))
    self:_teardown(conn, "unsupported protocol", false)
    conn.close()
    return
  end
  local clientId = p.clientId
  if clientId == "" then
    if not p.cleanSession then
      self.stats.connectsRejected = self.stats.connectsRejected + 1
      self:_send(conn, Codec.connack(false, Codec.CONNACK_BAD_CLIENT_ID))
      self:_teardown(conn, "empty client id without clean session", false)
      conn.close()
      return
    end
    self.generatedIds = self.generatedIds + 1
    clientId = string.format("auto-%d", self.generatedIds)
  end

  -- Same client id already connected: the new connection replaces it.
  local existing = self.byClientId[clientId]
  if existing and existing ~= conn then
    self.stats.takeovers = self.stats.takeovers + 1
    self:_log("info", "Client %s reconnected, closing its previous connection", clientId)
    self:drop(existing, "replaced by a new connection")
  end

  conn.clientId = clientId
  conn.protocolLevel = level
  conn.keepAlive = p.keepAlive or 0
  conn.will = p.will
  self.byClientId[clientId] = conn
  self.stats.connectsAccepted = self.stats.connectsAccepted + 1
  self:_log(
    "info",
    "Client %s connected (MQTT %s, keepalive %ds)",
    self:describe(conn),
    level == 4 and "3.1.1" or "3.1",
    conn.keepAlive
  )
  self:_send(conn, Codec.connack(false, Codec.CONNACK_ACCEPTED))
  self:_clientsChanged()
end

function Broker:_onPublish(conn, p)
  if not Codec.validTopic(p.topic) then
    return self:_protocolError(conn, "invalid publish topic '" .. tostring(p.topic) .. "'")
  end
  if p.qos > 2 then
    return self:_protocolError(conn, "QoS 3")
  end
  if p.qos == 1 then
    self:_send(conn, Codec.puback(p.packetId))
  elseif p.qos == 2 then
    -- Deliver now; a duplicate PUBLISH with the same id before PUBREL is ignored.
    self:_send(conn, Codec.pubrec(p.packetId))
    if conn.qos2[p.packetId] then
      return
    end
    conn.qos2[p.packetId] = true
  end
  self.stats.publishesIn = self.stats.publishesIn + 1
  conn.messagesIn = conn.messagesIn + 1
  self:_publish(p.topic, p.payload, p.retain, conn.clientId)
end

function Broker:_onSubscribe(conn, p)
  if p.flags ~= 2 then
    return self:_protocolError(conn, "SUBSCRIBE with flags " .. p.flags)
  end
  if #p.filters == 0 then
    return self:_protocolError(conn, "SUBSCRIBE without filters")
  end
  local codes, added = {}, {}
  for i, f in ipairs(p.filters) do
    if Codec.validFilter(f.filter) and f.qos <= 2 then
      self:_addSub(conn, f.filter)
      codes[i] = 0 -- granted QoS 0
      added[#added + 1] = f.filter
    else
      codes[i] = 0x80
      self:_log("warn", "Client %s sent an invalid filter '%s'", self:describe(conn), tostring(f.filter))
    end
  end
  self:_send(conn, Codec.suback(p.packetId, codes))
  self:_log("debug", "Client %s subscribed to %s", self:describe(conn), table.concat(added, ", "))
  -- Retained messages matching the new filters
  for _, filter in ipairs(added) do
    local flevels = Codec.levels(filter)
    for topic, msg in pairs(self.retained) do
      if Codec.matchLevels(flevels, msg.levels) then
        conn.messagesOut = conn.messagesOut + 1
        self.stats.messagesDelivered = self.stats.messagesDelivered + 1
        self:_send(conn, Codec.publish(topic, msg.payload, { retain = true }))
      end
    end
  end
end

function Broker:_onUnsubscribe(conn, p)
  if p.flags ~= 2 then
    return self:_protocolError(conn, "UNSUBSCRIBE with flags " .. p.flags)
  end
  for _, filter in ipairs(p.filters) do
    self:_removeSub(conn, filter)
  end
  self:_send(conn, Codec.unsuback(p.packetId))
end

-------------------------------------------------------------------------------
-- Subscriptions and routing
-------------------------------------------------------------------------------

local function isWild(filter)
  return filter:find("[+#]") ~= nil
end

function Broker:_addSub(conn, filter)
  if conn.subs[filter] then
    return
  end
  conn.subs[filter] = true
  if isWild(filter) then
    local entry = self.wildSubs[filter]
    if not entry then
      entry = { levels = Codec.levels(filter), conns = {} }
      self.wildSubs[filter] = entry
    end
    entry.conns[conn] = true
  else
    local set = self.exactSubs[filter]
    if not set then
      set = {}
      self.exactSubs[filter] = set
    end
    set[conn] = true
  end
end

function Broker:_removeSub(conn, filter)
  conn.subs[filter] = nil
  if isWild(filter) then
    local entry = self.wildSubs[filter]
    if entry then
      entry.conns[conn] = nil
      if next(entry.conns) == nil then
        self.wildSubs[filter] = nil
      end
    end
  else
    local set = self.exactSubs[filter]
    if set then
      set[conn] = nil
      if next(set) == nil then
        self.exactSubs[filter] = nil
      end
    end
  end
end

--- Connections subscribed to a topic (each once, however many filters match).
--- @param topic string
--- @return table<table, boolean>
function Broker:subscribersOf(topic)
  local out = {}
  local exact = self.exactSubs[topic]
  if exact then
    for conn in pairs(exact) do
      out[conn] = true
    end
  end
  if next(self.wildSubs) then
    local tlevels = Codec.levels(topic)
    for _, entry in pairs(self.wildSubs) do
      if Codec.matchLevels(entry.levels, tlevels) then
        for conn in pairs(entry.conns) do
          out[conn] = true
        end
      end
    end
  end
  return out
end

--- Route a message to subscribers and update retained state.
--- @param topic string
--- @param payload string
--- @param retain boolean
--- @param fromClientId string|nil
function Broker:_publish(topic, payload, retain, fromClientId)
  payload = payload or ""
  if retain then
    if payload == "" then
      if self.retained[topic] then
        self.retained[topic] = nil
        self.retainedCount = self.retainedCount - 1
      end
    else
      if not self.retained[topic] then
        self.retainedCount = self.retainedCount + 1
      end
      self.retained[topic] = { payload = payload, levels = Codec.levels(topic) }
    end
  end
  -- Forwarded copies carry retain = false (MQTT 3.1.1, 3.3.1.3)
  local bytes = nil
  for conn in pairs(self:subscribersOf(topic)) do
    bytes = bytes or Codec.publish(topic, payload)
    conn.messagesOut = conn.messagesOut + 1
    self.stats.messagesDelivered = self.stats.messagesDelivered + 1
    self:_send(conn, bytes)
  end
  if self.onPublish then
    self.onPublish(topic, payload, retain, fromClientId)
  end
end

--- Publish from inside the driver (step 1: messages from bound drivers).
function Broker:publish(topic, payload, retain)
  if not Codec.validTopic(topic) then
    return false
  end
  self:_publish(topic, payload, retain, nil)
  return true
end

-------------------------------------------------------------------------------
-- Housekeeping
-------------------------------------------------------------------------------

--- Close connections that went quiet. Call about once a second.
--- MQTT allows 1.5 x keepalive; connections that never sent CONNECT get 30s.
function Broker:checkTimeouts()
  local now = self.now()
  local expired = {}
  for conn in pairs(self.connections) do
    local limit
    if conn.clientId == nil then
      limit = 30000
    elseif (conn.keepAlive or 0) > 0 then
      limit = conn.keepAlive * 1500
    end
    if limit and now - conn.lastActivity > limit then
      expired[#expired + 1] = conn
    end
  end
  for _, conn in ipairs(expired) do
    self.stats.keepaliveTimeouts = self.stats.keepaliveTimeouts + 1
    self:_log("warn", "Client %s timed out", self:describe(conn))
    self:drop(conn, "keepalive timeout")
  end
end

--- Close every connection (server stop). Wills are not published.
function Broker:closeAll(reason)
  local all = {}
  for conn in pairs(self.connections) do
    all[#all + 1] = conn
  end
  for _, conn in ipairs(all) do
    conn.will = nil
    self:_teardown(conn, reason or "server stopped", false)
    conn.close()
  end
end

--- Snapshot of connected clients, sorted by client id.
--- @return table[]
function Broker:clients()
  local list = {}
  local now = self.now()
  for conn in pairs(self.connections) do
    local subs = 0
    for _ in pairs(conn.subs) do
      subs = subs + 1
    end
    list[#list + 1] = {
      clientId = conn.clientId or "(no CONNECT yet)",
      address = conn.address or "?",
      keepAlive = conn.keepAlive or 0,
      connectedSeconds = math.floor((now - conn.connectedAt) / 1000),
      idleSeconds = math.floor((now - conn.lastActivity) / 1000),
      subscriptions = subs,
      messagesIn = conn.messagesIn,
      messagesOut = conn.messagesOut,
      hasWill = conn.will ~= nil,
    }
  end
  table.sort(list, function(a, b)
    return a.clientId < b.clientId
  end)
  return list
end

return Broker
