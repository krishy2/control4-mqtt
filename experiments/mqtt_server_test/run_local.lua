--- Run the MQTT Server Test driver on a computer instead of a controller.
---
--- Stands in for Control4's C4:CreateTCPServer with luasocket, runs the
--- driver's event loop, and prints the driver's report at the end. Used to
--- check the driver against mqtt_load_test.py before trying real hardware.
---
--- Needs LuaJIT and luasocket. From the repo root:
---   LUA_PATH="test/?.lua;src/?.lua;vendor/?.lua;;" \
---     luajit experiments/mqtt_server_test/run_local.lua [port] [seconds]

local socket = require("socket")
io.stdout:setvbuf("no")
require("c4_shim")

local PORT = tonumber(arg[1]) or 3883
local SECONDS = tonumber(arg[2]) or 600

-------------------------------------------------------------------------------
-- C4LuaTcpServer / C4LuaTcpClient stand-ins (the subset the driver uses)
-------------------------------------------------------------------------------

local servers, clients = {}, {}

local Client = {}
Client.__index = Client

local function newClient(sock)
  local ip, port = sock:getpeername()
  local c = setmetatable({ sock = sock, out = {}, ip = ip, port = port }, Client)
  sock:settimeout(0)
  clients[c] = true
  return c
end

for _, name in ipairs({ "OnRead", "OnWrite", "OnDisconnect", "OnError" }) do
  Client[name] = function(self, fn)
    self[name] = fn
    return self
  end
end

function Client:ReadUpTo(max)
  self.want = max
  return self
end

function Client:Write(data)
  if self.dead or self.closing then
    return nil
  end
  self.out[#self.out + 1] = data
  return self
end

function Client:Option()
  return self
end

function Client:GetRemoteAddress()
  return { ip = self.ip, port = self.port }
end

function Client:_kill()
  if not self.dead then
    self.dead = true
    clients[self] = nil
    self.sock:close()
  end
end

function Client:Close(flush)
  self.closing = true
  self.want = nil
  if not flush or #self.out == 0 then
    self:_kill()
  end
  return self
end

local Server = {}
Server.__index = Server

for _, name in ipairs({ "OnListen", "OnError", "OnAccept", "OnResolve" }) do
  Server[name] = function(self, fn)
    self[name] = fn
    return self
  end
end

function Server:Option()
  return self
end

function Server:Listen(host, port)
  local sock = socket.tcp4()
  sock:setoption("reuseaddr", true)
  local ok, err = sock:bind(host == "*" and "0.0.0.0" or host, port)
  if not ok then
    C4:SetTimer(1, function()
      if self.OnError then
        self.OnError(self, 98, tostring(err))
      end
    end)
    return self
  end
  sock:listen(1024)
  sock:settimeout(0)
  self.sock = sock
  servers[self] = true
  C4:SetTimer(1, function()
    if self.OnListen then
      self.OnListen(self, self:GetLocalAddress())
    end
  end)
  return self
end

function Server:GetLocalAddress()
  local ip, port = self.sock:getsockname()
  return { ip = ip, port = tonumber(port) }
end

function Server:Close()
  if self.sock then
    self.sock:close()
    self.sock = nil
  end
  servers[self] = nil
  return self
end

function C4:CreateTCPServer()
  return setmetatable({}, Server)
end

--- One pass of the event loop.
local function pump(timeout)
  local rd, wr, owner = {}, {}, {}
  for srv in pairs(servers) do
    rd[#rd + 1] = srv.sock
    owner[srv.sock] = srv
  end
  for c in pairs(clients) do
    if c.want and not c.dead then
      rd[#rd + 1] = c.sock
    end
    if #c.out > 0 then
      wr[#wr + 1] = c.sock
    end
    owner[c.sock] = c
  end
  local readable, writable = socket.select(rd, wr, timeout)

  for _, sock in ipairs(writable or {}) do
    local c = owner[sock]
    if c and not c.dead and #c.out > 0 then
      local buf = table.concat(c.out)
      local sent, err, partial = sock:send(buf)
      local n = sent or partial or 0
      if err == "closed" then
        c:_kill()
        if c.OnDisconnect then
          c.OnDisconnect(c, 104, "connection reset")
        end
      else
        c.out = n < #buf and { buf:sub(n + 1) } or {}
        if #c.out == 0 then
          if c.OnWrite then
            c.OnWrite(c)
          end
          if c.closing then
            c:_kill()
          end
        end
      end
    end
  end

  for _, sock in ipairs(readable or {}) do
    local o = owner[sock]
    if servers[o] then
      while true do
        local s = sock:accept()
        if not s then
          break
        end
        local c = newClient(s)
        if o.OnAccept then
          o.OnAccept(o, c)
        end
      end
    elseif o and clients[o] and o.want then
      local data, err, partial = sock:receive(o.want)
      data = data or partial
      if data and #data > 0 then
        o.want = nil
        o.OnRead(o, data)
      end
      if err == "closed" and not o.dead then
        o:_kill()
        if o.OnDisconnect then
          o.OnDisconnect(o, 0, "")
        end
      end
    end
  end
  C4:ProcessTimers()
end

-------------------------------------------------------------------------------
-- Load and run the driver
-------------------------------------------------------------------------------

local dir = os.getenv("DRIVER_DIR") or "experiments/mqtt_server_test/"
local xml = assert(io.open(dir .. "driver.xml")):read("*a")
for block in xml:gmatch("<property>(.-)</property>") do
  Properties[block:match("<name>(.-)</name>")] = block:match("<default>(.-)</default>") or ""
end
Properties["Listen Port"] = tostring(PORT)
Properties["Max Clients"] = os.getenv("MAX_CLIENTS") or Properties["Max Clients"]
Properties["Log Mode"] = "Print"
Properties["Log Level"] = os.getenv("LOG_LEVEL") or "2 - Warning"
-- Extra properties, e.g. PROPS="Broker Mode=Built-in;Automatic Updates=Off"
for pair in (os.getenv("PROPS") or ""):gmatch("[^;]+") do
  local k, v = pair:match("^%s*(.-)%s*=%s*(.-)%s*$")
  if k then
    Properties[k] = v
  end
end
-- C4:UpdateProperty is a stub in the shim; keep the values so the report shows them.
C4.UpdateProperty = function(_, name, value)
  Properties[name] = value
end
-- The shim has no driver config; drivers check the OS version against it.
local realConfigInfo = C4.GetDriverConfigInfo
C4.GetDriverConfigInfo = function(c4, section)
  if section == "minimum_os_version" then
    return "3.3.0"
  end
  return realConfigInfo(c4, section)
end
C4.FireEvent = C4.FireEvent or function(_, name)
  print("run_local: event " .. tostring(name))
end

dofile(dir .. "driver.lua")
OnDriverInit()
OnDriverLateInit()

local stopAt = socket.gettime() + SECONDS
local reportFile = os.getenv("REPORT_FILE")
print(string.format("run_local: serving for %ds on port %d", SECONDS, PORT))
while socket.gettime() < stopAt do
  local ok, err = xpcall(pump, debug.traceback, 0.005)
  if not ok then
    print("run_local: event loop error: " .. tostring(err))
  end
  if reportFile and io.open(reportFile .. ".request") then
    os.remove(reportFile .. ".request")
    EC.PrintReport()
  end
end
EC.PrintReport()
EC.PrintClients()
