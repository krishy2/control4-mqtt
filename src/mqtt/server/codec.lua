--- @module "mqtt.server.codec"
--- MQTT 3.1 / 3.1.1 packet encoding and decoding for the built-in broker.
---
--- Pure Lua, no Control4 calls, so it runs the same on a controller and in
--- tests. A Reader turns an arbitrary stream of TCP reads into whole packets:
--- reads may split a packet or carry several.

local Codec = {}

Codec.CONNECT = 1
Codec.CONNACK = 2
Codec.PUBLISH = 3
Codec.PUBACK = 4
Codec.PUBREC = 5
Codec.PUBREL = 6
Codec.PUBCOMP = 7
Codec.SUBSCRIBE = 8
Codec.SUBACK = 9
Codec.UNSUBSCRIBE = 10
Codec.UNSUBACK = 11
Codec.PINGREQ = 12
Codec.PINGRESP = 13
Codec.DISCONNECT = 14

Codec.TYPE_NAMES = {
  "CONNECT",
  "CONNACK",
  "PUBLISH",
  "PUBACK",
  "PUBREC",
  "PUBREL",
  "PUBCOMP",
  "SUBSCRIBE",
  "SUBACK",
  "UNSUBSCRIBE",
  "UNSUBACK",
  "PINGREQ",
  "PINGRESP",
  "DISCONNECT",
}

-- CONNACK return codes
Codec.CONNACK_ACCEPTED = 0
Codec.CONNACK_BAD_PROTOCOL = 1
Codec.CONNACK_BAD_CLIENT_ID = 2

--- Largest packet accepted. Tasmota's default limit is 1200 bytes; discovery
--- configs stay well under this.
Codec.MAX_PACKET = 256 * 1024

local byte, char, sub = string.byte, string.char, string.sub
local floor = math.floor

-------------------------------------------------------------------------------
-- Encoding
-------------------------------------------------------------------------------

--- Encode the variable-length "remaining length" field.
--- @param n integer
--- @return string
function Codec.encodeLength(n)
  local out = {}
  repeat
    local digit = n % 128
    n = floor(n / 128)
    if n > 0 then
      digit = digit + 128
    end
    out[#out + 1] = char(digit)
  until n == 0
  return table.concat(out)
end

local function u16(n)
  return char(floor(n / 256) % 256, n % 256)
end

local function str(s)
  return u16(#s) .. s
end

local function packet(firstByte, body)
  return char(firstByte) .. Codec.encodeLength(#body) .. body
end

--- @param sessionPresent boolean
--- @param returnCode integer
function Codec.connack(sessionPresent, returnCode)
  return packet(0x20, char(sessionPresent and 1 or 0, returnCode))
end

--- @param topic string
--- @param payload string
--- @param opts table|nil { qos?, retain?, dup?, packetId? }
function Codec.publish(topic, payload, opts)
  opts = opts or {}
  local qos = opts.qos or 0
  local flags = (opts.dup and 0x08 or 0) + qos * 2 + (opts.retain and 1 or 0)
  local body = str(topic)
  if qos > 0 then
    body = body .. u16(opts.packetId or 1)
  end
  return packet(0x30 + flags, body .. (payload or ""))
end

function Codec.puback(packetId)
  return packet(0x40, u16(packetId))
end

function Codec.pubrec(packetId)
  return packet(0x50, u16(packetId))
end

function Codec.pubrel(packetId)
  return packet(0x62, u16(packetId))
end

function Codec.pubcomp(packetId)
  return packet(0x70, u16(packetId))
end

--- @param packetId integer
--- @param codes integer[] granted QoS per filter, or 0x80 for failure
function Codec.suback(packetId, codes)
  local parts = { u16(packetId) }
  for _, c in ipairs(codes) do
    parts[#parts + 1] = char(c)
  end
  return packet(0x90, table.concat(parts))
end

function Codec.unsuback(packetId)
  return packet(0xB0, u16(packetId))
end

function Codec.pingresp()
  return char(0xD0, 0)
end

-- Client-side packets, used by tests and the load simulator's Lua twin.

--- @param opts table { clientId, keepAlive?, clean?, will?, username?, password?, level? }
function Codec.connect(opts)
  local level = opts.level or 4
  local name = level == 3 and "MQIsdp" or "MQTT"
  local flags = 0
  if opts.clean ~= false then
    flags = flags + 0x02
  end
  local payload = str(opts.clientId or "")
  if opts.will then
    flags = flags + 0x04 + (opts.will.qos or 0) * 8 + (opts.will.retain and 0x20 or 0)
    payload = payload .. str(opts.will.topic) .. str(opts.will.payload or "")
  end
  if opts.username then
    flags = flags + 0x80
    payload = payload .. str(opts.username)
  end
  if opts.password then
    flags = flags + 0x40
    payload = payload .. str(opts.password)
  end
  local body = str(name) .. char(level, flags) .. u16(opts.keepAlive or 60) .. payload
  return packet(0x10, body)
end

--- @param packetId integer
--- @param filters table[] { { filter, qos } }
function Codec.subscribe(packetId, filters)
  local parts = { u16(packetId) }
  for _, f in ipairs(filters) do
    parts[#parts + 1] = str(f[1]) .. char(f[2] or 0)
  end
  return packet(0x82, table.concat(parts))
end

function Codec.unsubscribe(packetId, filters)
  local parts = { u16(packetId) }
  for _, f in ipairs(filters) do
    parts[#parts + 1] = str(f)
  end
  return packet(0xA2, table.concat(parts))
end

function Codec.pingreq()
  return char(0xC0, 0)
end

function Codec.disconnect()
  return char(0xE0, 0)
end

-------------------------------------------------------------------------------
-- Decoding
-------------------------------------------------------------------------------

--- Cursor over a packet body.
local Cursor = {}
Cursor.__index = Cursor

local function cursor(s)
  return setmetatable({ s = s, i = 1 }, Cursor)
end

function Cursor:remaining()
  return #self.s - self.i + 1
end

function Cursor:u8()
  if self:remaining() < 1 then
    error("truncated", 0)
  end
  local b = byte(self.s, self.i)
  self.i = self.i + 1
  return b
end

function Cursor:u16()
  if self:remaining() < 2 then
    error("truncated", 0)
  end
  local hi, lo = byte(self.s, self.i, self.i + 1)
  self.i = self.i + 2
  return hi * 256 + lo
end

function Cursor:bytes(n)
  if self:remaining() < n then
    error("truncated", 0)
  end
  local v = sub(self.s, self.i, self.i + n - 1)
  self.i = self.i + n
  return v
end

function Cursor:str()
  return self:bytes(self:u16())
end

function Cursor:rest()
  local v = sub(self.s, self.i)
  self.i = #self.s + 1
  return v
end

--- Decode one packet from its first byte and body.
--- @param first integer
--- @param body string
--- @return table|nil packet
--- @return string|nil err
function Codec.decode(first, body)
  local ptype = floor(first / 16)
  local flags = first % 16
  local c = cursor(body)
  local ok, result = pcall(function()
    local p = { type = ptype, flags = flags }
    if ptype == Codec.CONNECT then
      p.protocolName = c:str()
      p.protocolLevel = c:u8()
      local f = c:u8()
      p.keepAlive = c:u16()
      p.cleanSession = floor(f / 2) % 2 == 1
      p.reservedFlag = f % 2 == 1
      local willFlag = floor(f / 4) % 2 == 1
      local willQos = floor(f / 8) % 4
      local willRetain = floor(f / 32) % 2 == 1
      local hasPassword = floor(f / 64) % 2 == 1
      local hasUsername = floor(f / 128) % 2 == 1
      p.clientId = c:str()
      if willFlag then
        p.will = { topic = c:str(), payload = c:str(), qos = willQos, retain = willRetain }
      end
      if hasUsername then
        p.username = c:str()
      end
      if hasPassword then
        p.password = c:str()
      end
    elseif ptype == Codec.PUBLISH then
      p.dup = floor(flags / 8) % 2 == 1
      p.qos = floor(flags / 2) % 4
      p.retain = flags % 2 == 1
      p.topic = c:str()
      if p.qos > 0 then
        p.packetId = c:u16()
      end
      p.payload = c:rest()
    elseif ptype == Codec.PUBACK or ptype == Codec.PUBREC or ptype == Codec.PUBREL or ptype == Codec.PUBCOMP then
      p.packetId = c:u16()
    elseif ptype == Codec.SUBSCRIBE then
      p.packetId = c:u16()
      p.filters = {}
      while c:remaining() > 0 do
        local filter = c:str()
        local qos = c:u8()
        p.filters[#p.filters + 1] = { filter = filter, qos = qos }
      end
    elseif ptype == Codec.UNSUBSCRIBE then
      p.packetId = c:u16()
      p.filters = {}
      while c:remaining() > 0 do
        p.filters[#p.filters + 1] = c:str()
      end
    elseif ptype == Codec.CONNACK then
      p.sessionPresent = c:u8() % 2 == 1
      p.returnCode = c:u8()
    elseif ptype == Codec.SUBACK then
      p.packetId = c:u16()
      p.codes = {}
      while c:remaining() > 0 do
        p.codes[#p.codes + 1] = c:u8()
      end
    elseif ptype == Codec.UNSUBACK then
      p.packetId = c:u16()
    elseif ptype == Codec.PINGREQ or ptype == Codec.PINGRESP or ptype == Codec.DISCONNECT then
      -- no body
      local _ = p
    else
      error("unknown packet type " .. tostring(ptype), 0)
    end
    return p
  end)
  if not ok then
    return nil, tostring(result)
  end
  return result
end

-------------------------------------------------------------------------------
-- Stream reader
-------------------------------------------------------------------------------

--- @class MqttReader
--- @field buffer string
--- @field stats table
local Reader = {}
Reader.__index = Reader

--- Create a stream reader.
--- @param maxPacket integer|nil
--- @return MqttReader
function Codec.reader(maxPacket)
  return setmetatable({
    buffer = "",
    maxPacket = maxPacket or Codec.MAX_PACKET,
    -- framing statistics, for the step 0 hardware test
    stats = { reads = 0, splitReads = 0, multiPacketReads = 0 },
  }, Reader)
end

--- Feed bytes from one TCP read; returns the whole packets now available.
--- @param data string
--- @return table[] packets each { first, body }
--- @return string|nil err fatal framing error (oversized or malformed length)
function Reader:feed(data)
  local stats = self.stats
  stats.reads = stats.reads + 1
  local hadPartial = #self.buffer > 0
  local buf = self.buffer .. data
  local out = {}
  local pos = 1
  local len = #buf
  while true do
    if len - pos + 1 < 2 then
      break
    end
    -- remaining length: up to 4 bytes
    local mult, value, i = 1, 0, pos + 1
    local complete = false
    for _ = 1, 4 do
      if i > len then
        break
      end
      local b = byte(buf, i)
      value = value + (b % 128) * mult
      mult = mult * 128
      i = i + 1
      if b < 128 then
        complete = true
        break
      end
    end
    if not complete then
      if i - (pos + 1) >= 4 then
        return out, "malformed remaining length"
      end
      break -- need more bytes for the length
    end
    if value > self.maxPacket then
      return out, string.format("packet of %d bytes exceeds the %d byte limit", value, self.maxPacket)
    end
    if len - i + 1 < value then
      break -- body not complete yet
    end
    out[#out + 1] = { first = byte(buf, pos), body = sub(buf, i, i + value - 1) }
    pos = i + value
  end
  self.buffer = sub(buf, pos)
  if hadPartial and #out > 0 then
    stats.splitReads = stats.splitReads + 1
  end
  if #out > 1 then
    stats.multiPacketReads = stats.multiPacketReads + 1
  end
  return out
end

-------------------------------------------------------------------------------
-- Topics
-------------------------------------------------------------------------------

--- Split a topic or filter into levels.
--- @param topic string
--- @return string[]
function Codec.levels(topic)
  local out = {}
  local start = 1
  while true do
    local slash = string.find(topic, "/", start, true)
    if not slash then
      out[#out + 1] = sub(topic, start)
      return out
    end
    out[#out + 1] = sub(topic, start, slash - 1)
    start = slash + 1
  end
end

--- Is this a valid topic name for PUBLISH?
function Codec.validTopic(topic)
  return type(topic) == "string" and #topic > 0 and not topic:find("[+#]") and not topic:find("%z")
end

--- Is this a valid topic filter for SUBSCRIBE?
function Codec.validFilter(filter)
  if type(filter) ~= "string" or #filter == 0 or filter:find("%z") then
    return false
  end
  local levels = Codec.levels(filter)
  for i, level in ipairs(levels) do
    if level:find("#", 1, true) and (level ~= "#" or i ~= #levels) then
      return false
    end
    if level:find("+", 1, true) and level ~= "+" then
      return false
    end
  end
  return true
end

--- Does a filter match a topic? Both given as level arrays.
--- @param filterLevels string[]
--- @param topicLevels string[]
--- @return boolean
function Codec.matchLevels(filterLevels, topicLevels)
  -- Wildcards at the first level never match topics starting with "$".
  local first = filterLevels[1]
  if (first == "+" or first == "#") and sub(topicLevels[1] or "", 1, 1) == "$" then
    return false
  end
  local nf, nt = #filterLevels, #topicLevels
  for i = 1, nf do
    local f = filterLevels[i]
    if f == "#" then
      return true
    end
    if i > nt then
      return false
    end
    if f ~= "+" and f ~= topicLevels[i] then
      return false
    end
  end
  return nf == nt
end

--- Convenience: does a filter string match a topic string?
function Codec.matches(filter, topic)
  return Codec.matchLevels(Codec.levels(filter), Codec.levels(topic))
end

return Codec
