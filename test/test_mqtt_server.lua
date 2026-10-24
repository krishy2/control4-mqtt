-- Tests for the built-in MQTT broker core (src/mqtt/server): packet codec,
-- stream framing, topic matching and broker behaviour.
--
-- Run from the repo root:
--   make test
-- or:
--   ./test/run_test.sh test_mqtt_server.lua

local T = require("testlib")
local Codec = require("mqtt.server.codec")
local Broker = require("mqtt.server.broker")

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

local clock = 0
local function newBroker()
  clock = 0
  return Broker.new({
    now = function()
      return clock
    end,
  })
end

--- A fake connection that decodes everything the broker sends it.
local function newConn(broker, address)
  local conn = { address = address or "10.0.0.1:5000", sent = {}, closedByBroker = false }
  local reader = Codec.reader()
  conn.send = function(bytes)
    for _, raw in ipairs((reader:feed(bytes))) do
      conn.sent[#conn.sent + 1] = Codec.decode(raw.first, raw.body)
    end
  end
  conn.close = function()
    conn.closedByBroker = true
  end
  broker:accept(conn)
  return conn
end

local function take(conn)
  local out = conn.sent
  conn.sent = {}
  return out
end

local function connect(broker, clientId, opts)
  opts = opts or {}
  local conn = newConn(broker, opts.address)
  opts.clientId = clientId
  broker:data(conn, Codec.connect(opts))
  return conn
end

local function types(packets)
  local out = {}
  for _, p in ipairs(packets) do
    out[#out + 1] = Codec.TYPE_NAMES[p.type]
  end
  return out
end

local function publishes(packets)
  local out = {}
  for _, p in ipairs(packets) do
    if p.type == Codec.PUBLISH then
      out[#out + 1] = p.topic .. "=" .. p.payload .. (p.retain and " (r)" or "")
    end
  end
  return out
end

-------------------------------------------------------------------------------
T.section("Remaining length encoding")
-------------------------------------------------------------------------------
for _, case in ipairs({ { 0, 1 }, { 127, 1 }, { 128, 2 }, { 16383, 2 }, { 16384, 3 }, { 2097152, 4 } }) do
  T.eq(string.format("%d takes %d bytes", case[1], case[2]), #Codec.encodeLength(case[1]), case[2])
end
local r = Codec.reader()
local big = string.rep("x", 20000)
local pkts = r:feed(Codec.publish("a/b", big))
T.eq("a 20 KB publish round-trips", pkts[1] and Codec.decode(pkts[1].first, pkts[1].body).payload == big, true)

-------------------------------------------------------------------------------
T.section("Stream framing")
-------------------------------------------------------------------------------
local stream = Codec.connect({ clientId = "c1", keepAlive = 30 })
  .. Codec.subscribe(1, { { "cmnd/c1/#", 1 } })
  .. Codec.publish("tele/c1/STATE", '{"POWER":"ON"}')
  .. Codec.pingreq()
r = Codec.reader()
local got = {}
for i = 1, #stream do
  for _, p in ipairs((r:feed(stream:sub(i, i)))) do
    got[#got + 1] = Codec.TYPE_NAMES[Codec.decode(p.first, p.body).type]
  end
end
T.eq("byte-by-byte reads give every packet", got, { "CONNECT", "SUBSCRIBE", "PUBLISH", "PINGREQ" })
T.check("split packets are counted", r.stats.splitReads >= 3, tostring(r.stats.splitReads))

r = Codec.reader()
got = r:feed(stream)
T.eq("one read with four packets", #got, 4)
T.eq("multi-packet read is counted", r.stats.multiPacketReads, 1)

r = Codec.reader(100)
local _, err = r:feed(Codec.publish("a", string.rep("x", 200)))
T.check("oversized packet is refused", err ~= nil and err:find("limit") ~= nil, tostring(err))
_, err = Codec.reader():feed(string.char(0x30, 0xFF, 0xFF, 0xFF, 0xFF, 0x01))
T.check("a 5-byte length is malformed", err ~= nil, tostring(err))

local p = Codec.decode(0x10, ("\0\4MQTT\4\2\0\30\0\3abc"):sub(1, 10))
T.eq("a truncated CONNECT does not decode", p, nil)

-------------------------------------------------------------------------------
T.section("Topic filters")
-------------------------------------------------------------------------------
local matchCases = {
  { "cmnd/light/#", "cmnd/light/POWER", true },
  { "cmnd/light/#", "cmnd/light", true },
  { "cmnd/+/POWER", "cmnd/light/POWER", true },
  { "cmnd/+/POWER", "cmnd/light/x/POWER", false },
  { "+/+", "a/b", true },
  { "+", "a/b", false },
  { "#", "a/b/c", true },
  { "#", "$SYS/broker", false },
  { "+/broker", "$SYS/broker", false },
  { "$SYS/#", "$SYS/broker", true },
  { "a/b", "a/b", true },
  { "a/b", "a/b/", false },
  { "a/+", "a/", true },
}
for _, c in ipairs(matchCases) do
  T.eq(string.format("%s vs %s", c[1], c[2]), Codec.matches(c[1], c[2]), c[3])
end
T.eq("valid filter a/#", Codec.validFilter("a/#"), true)
T.eq("invalid filter a/#/b", Codec.validFilter("a/#/b"), false)
T.eq("invalid filter a/b#", Codec.validFilter("a/b#"), false)
T.eq("invalid filter a+/b", Codec.validFilter("a+/b"), false)
T.eq("publish topic may not hold wildcards", Codec.validTopic("a/+"), false)

-------------------------------------------------------------------------------
T.section("CONNECT")
-------------------------------------------------------------------------------
local broker = newBroker()
local c1 = connect(broker, "tasmota_1", { keepAlive = 30 })
local ack = take(c1)[1]
T.eq("MQTT 3.1.1 is accepted", { ack and ack.type, ack and ack.returnCode }, { Codec.CONNACK, 0 })
T.eq("client is counted", broker:clientCount(), 1)

local v31 = connect(broker, "old_client", { level = 3 })
T.eq("MQTT 3.1 (MQIsdp) is accepted", take(v31)[1].returnCode, 0)

local conn5 = newConn(broker)
broker:data(conn5, Codec.connect({ clientId = "v5" }):gsub("\4\2", "\5\2", 1))
T.eq("MQTT 5 is refused with code 1", take(conn5)[1].returnCode, 1)
T.eq("and closed", conn5.closedByBroker, true)

local anon = connect(broker, "")
T.eq("an empty client id with clean session gets an id", take(anon)[1].returnCode, 0)
local anon2 = connect(broker, "", { clean = false })
T.eq("an empty client id without clean session is refused", take(anon2)[1].returnCode, 2)

local early = newConn(broker)
broker:data(early, Codec.pingreq())
T.eq("a packet before CONNECT closes the connection", early.closedByBroker, true)
T.eq("and counts as a protocol error", broker.stats.protocolErrors, 1)

local creds = connect(broker, "with_login", { username = "DVES_USER", password = "secret" })
T.eq("username and password are ignored, not refused", take(creds)[1].returnCode, 0)

-------------------------------------------------------------------------------
T.section("Subscribe, publish, retained")
-------------------------------------------------------------------------------
broker = newBroker()
local dev = connect(broker, "kitchen", { will = { topic = "tele/kitchen/LWT", payload = "Offline", retain = true } })
local ctl = connect(broker, "controller")
take(dev)
take(ctl)

broker:data(dev, Codec.publish("tele/kitchen/LWT", "Online", { retain = true }))
broker:data(dev, Codec.subscribe(7, { { "cmnd/kitchen/#", 1 }, { "bad/#/topic", 0 } }))
local sub = take(dev)
T.eq("SUBACK keeps the packet id", sub[1].packetId, 7)
T.eq("granted QoS 0, invalid filter fails", sub[1].codes, { 0, 0x80 })

broker:data(ctl, Codec.subscribe(1, { { "tele/+/LWT", 0 }, { "stat/#", 0 } }))
T.eq("a new subscriber gets the retained message", publishes(take(ctl)), { "tele/kitchen/LWT=Online (r)" })

broker:data(ctl, Codec.publish("cmnd/kitchen/POWER", "TOGGLE"))
T.eq("a command reaches the device", publishes(take(dev)), { "cmnd/kitchen/POWER=TOGGLE" })
broker:data(dev, Codec.publish("stat/kitchen/RESULT", '{"POWER":"ON"}'))
T.eq("the device's answer reaches the controller", publishes(take(ctl)), { 'stat/kitchen/RESULT={"POWER":"ON"}' })

broker:data(ctl, Codec.subscribe(2, { { "stat/kitchen/RESULT", 0 } }))
take(ctl)
broker:data(dev, Codec.publish("stat/kitchen/RESULT", "x"))
T.eq("overlapping filters deliver once", #publishes(take(ctl)), 1)

broker:data(dev, Codec.publish("tele/kitchen/STATE", "1", { qos = 1, packetId = 42 }))
local acks = take(dev)
T.eq("QoS 1 is acknowledged", { acks[1].type, acks[1].packetId }, { Codec.PUBACK, 42 })

broker:data(dev, Codec.publish("tele/kitchen/STATE", "2", { qos = 2, packetId = 9 }))
broker:data(dev, Codec.publish("tele/kitchen/STATE", "2", { qos = 2, packetId = 9, dup = true }))
broker:data(dev, Codec.pubrel(9))
T.eq("QoS 2 handshake", types(take(dev)), { "PUBREC", "PUBREC", "PUBCOMP" })
T.eq("a duplicate QoS 2 publish is delivered once", broker.stats.publishesIn, 6)

broker:data(ctl, Codec.unsubscribe(3, { "stat/#", "stat/kitchen/RESULT" }))
T.eq("UNSUBACK", take(ctl)[1].type, Codec.UNSUBACK)
broker:data(dev, Codec.publish("stat/kitchen/RESULT", "y"))
T.eq("nothing after unsubscribing", #take(ctl), 0)

broker:data(dev, Codec.publish("tele/kitchen/LWT", "", { retain = true }))
T.eq("an empty retained publish clears it", broker.retainedCount, 0)

broker:data(dev, Codec.pingreq())
T.eq("PINGREQ gets PINGRESP", types(take(dev)), { "PINGRESP" })

-------------------------------------------------------------------------------
T.section("Last Will")
-------------------------------------------------------------------------------
broker:data(ctl, Codec.subscribe(4, { { "tele/+/LWT", 0 } }))
take(ctl)
broker:closed(dev, "network lost")
T.eq("a dropped client's will is published", publishes(take(ctl)), { "tele/kitchen/LWT=Offline" })
T.eq("and retained", broker.retained["tele/kitchen/LWT"].payload, "Offline")

local polite = connect(broker, "polite", { will = { topic = "tele/polite/LWT", payload = "Offline" } })
broker:data(polite, Codec.disconnect())
T.eq("no will after DISCONNECT", #take(ctl), 0)
T.eq("DISCONNECT closes the socket", polite.closedByBroker, true)

-------------------------------------------------------------------------------
T.section("Reconnect with the same client id")
-------------------------------------------------------------------------------
local first = connect(broker, "bulb", { will = { topic = "tele/bulb/LWT", payload = "Offline" } })
local second = connect(broker, "bulb")
T.eq("the old connection is closed", first.closedByBroker, true)
T.eq("the new one is accepted", take(second)[1].returnCode, 0)
T.eq("takeover is counted", broker.stats.takeovers, 1)
T.eq("only one client with that id", broker.byClientId["bulb"], second)
T.eq("the old connection's will is published", publishes(take(ctl)), { "tele/bulb/LWT=Offline" })

-------------------------------------------------------------------------------
T.section("Keepalive")
-------------------------------------------------------------------------------
broker = newBroker()
local quiet = connect(broker, "quiet", { keepAlive = 10 })
local silentTcp = newConn(broker)
local chatty = connect(broker, "chatty", { keepAlive = 10 })
clock = 14000
broker:data(chatty, Codec.pingreq())
broker:checkTimeouts()
T.eq("within 1.5 x keepalive nothing happens", quiet.closedByBroker, false)
clock = 15001
broker:checkTimeouts()
T.eq("after 1.5 x keepalive the client is closed", quiet.closedByBroker, true)
T.eq("an active client stays", chatty.closedByBroker, false)
clock = 30001
broker:checkTimeouts()
T.eq("a connection that never sends CONNECT is closed after 30s", silentTcp.closedByBroker, true)
T.eq("timeouts are counted", broker.stats.keepaliveTimeouts, 3)

-------------------------------------------------------------------------------
T.section("Slow clients and server stop")
-------------------------------------------------------------------------------
broker = newBroker()
local slow = connect(broker, "slow")
local pub = connect(broker, "pub")
broker:data(slow, Codec.subscribe(1, { { "big/#", 0 } }))
local chunk = string.rep("x", 64 * 1024)
for _ = 1, 20 do
  broker:data(pub, Codec.publish("big/data", chunk))
end
T.eq("a client that stops reading is dropped", slow.closedByBroker, true)
T.eq("and counted", broker.stats.slowClientsDropped, 1)

broker = newBroker()
local a = connect(broker, "a", { will = { topic = "w/a", payload = "gone" } })
local b = connect(broker, "b")
broker:data(b, Codec.subscribe(1, { { "w/#", 0 } }))
take(b)
broker:closeAll("test")
T.eq("closeAll closes everyone", { a.closedByBroker, b.closedByBroker }, { true, true })
T.eq("without publishing wills", #take(b), 0)
T.eq("nobody left", broker:connectionCount(), 0)

-------------------------------------------------------------------------------
T.section("100 clients")
-------------------------------------------------------------------------------
broker = newBroker()
local devices = {}
local controller = connect(broker, "controller")
broker:data(controller, Codec.subscribe(1, { { "stat/+/RESULT", 0 } }))
take(controller)
for i = 1, 100 do
  local id = string.format("tasmota_%03d", i)
  local d = connect(broker, id, { will = { topic = "tele/" .. id .. "/LWT", payload = "Offline", retain = true } })
  broker:data(d, Codec.subscribe(1, { { "cmnd/" .. id .. "/#", 0 } }))
  take(d)
  devices[i] = { id = id, conn = d }
end
T.eq("100 devices plus the controller are connected", broker:clientCount(), 101)
local ok = true
for i, d in ipairs(devices) do
  broker:data(controller, Codec.publish("cmnd/" .. d.id .. "/POWER", tostring(i)))
  local msgs = publishes(take(d.conn))
  if msgs[1] ~= "cmnd/" .. d.id .. "/POWER=" .. i then
    ok = false
  end
  -- nobody else got it
  for j, other in ipairs(devices) do
    if j ~= i and #other.conn.sent > 0 then
      ok = false
    end
  end
end
T.check("each command reaches only its device", ok)

T.finish()
