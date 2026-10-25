--- Connect MQTT General and MQTT Light drivers to the MQTT Broker driver by
--- themselves, so nobody has to make the binding in Composer.
---
--- Composer's own autobind (the <autobind> flag in driver.xml) does not connect
--- these drivers, so both sides do it from Lua:
---   * a light or general driver, when it starts, binds itself to the broker;
---   * the broker, when it starts, binds every light and general driver that is
---     not connected yet (for drivers added before the broker).
--- A driver that is already connected, to any broker, is left alone. With more
--- than one broker driver in the project the one with the lowest device ID is
--- used, and only that one binds others.

local log = require("lib.logging")

local AutoBind = {}

AutoBind.CLASS = "CP_MQTT_BROKER"
AutoBind.BROKER_FILE = "cp_mqtt_broker.c4z"
AutoBind.BROKER_BINDING = 5001
--- Driver file -> its broker (consumer) binding
AutoBind.CONSUMERS = {
  ["cp_mqtt_general.c4z"] = 5001,
  ["cp_mqtt_light.c4z"] = 5002,
  ["cp_mqtt_shutter.c4z"] = 5002,
  ["cp_mqtt_thermostat.c4z"] = 5002,
}

--- Device IDs running a driver file, lowest first.
--- @param filename string
--- @return integer[]
function AutoBind.devices(filename)
  local ids = {}
  for id in pairs(C4:GetDevicesByC4iName(filename) or {}) do
    local n = tonumber(id)
    if n then
      ids[#ids + 1] = math.floor(n)
    end
  end
  table.sort(ids)
  return ids
end

--- The broker driver to connect to: the one with the lowest device ID.
--- @return integer|nil
function AutoBind.broker()
  return AutoBind.devices(AutoBind.BROKER_FILE)[1]
end

--- Whether a consumer binding is connected to anything.
--- @param deviceId integer
--- @param bindingId integer
--- @return boolean
function AutoBind.isBound(deviceId, bindingId)
  local provider = C4:GetBoundProviderDevice(deviceId, bindingId)
  if type(provider) == "table" then
    -- The documented form: { [id] = name }
    return next(provider) ~= nil
  end
  return (tonumber(provider) or 0) ~= 0
end

local function name(deviceId)
  return C4:GetDeviceDisplayName(deviceId) or ("device " .. tostring(deviceId))
end

--- From a light or general driver: connect this driver to the broker if it is
--- not connected.
--- @param bindingId integer this driver's broker binding
--- @return boolean bound true when a binding was made
function AutoBind.connectSelf(bindingId)
  local me = math.floor(tonumber(C4:GetDeviceID()) or 0)
  if AutoBind.isBound(me, bindingId) then
    return false
  end
  local broker = AutoBind.broker()
  if broker == nil then
    log:info("No MQTT Broker driver in the project yet; this driver connects when one is added")
    return false
  end
  C4:Bind(broker, AutoBind.BROKER_BINDING, me, bindingId, AutoBind.CLASS)
  log:print("Connected to MQTT Broker '%s' automatically", name(broker))
  return true
end

--- From the broker: connect every light and general driver that is not
--- connected. Only the broker with the lowest device ID does this.
--- @return integer count drivers connected
function AutoBind.connectAll()
  local me = math.floor(tonumber(C4:GetDeviceID()) or 0)
  if AutoBind.broker() ~= me then
    return 0
  end
  local count = 0
  local files = {}
  for file in pairs(AutoBind.CONSUMERS) do
    files[#files + 1] = file
  end
  table.sort(files)
  for _, file in ipairs(files) do
    local bindingId = AutoBind.CONSUMERS[file]
    for _, deviceId in ipairs(AutoBind.devices(file)) do
      if not AutoBind.isBound(deviceId, bindingId) then
        C4:Bind(me, AutoBind.BROKER_BINDING, deviceId, bindingId, AutoBind.CLASS)
        log:print("Connected '%s' to this broker automatically", name(deviceId))
        count = count + 1
      end
    end
  end
  return count
end

return AutoBind
