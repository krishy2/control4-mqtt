--- @module "pi_thermostat.valves"
--- Time-proportional valve outputs for the PI Thermostat.
---
--- Each channel (heat, cool) turns a 0-100 % demand into an open/closed
--- valve: within a cycle of Cycle Time seconds the valve is open for
--- demand % of it (60 % of 10 min = 6 min open, 4 min closed). The relay is
--- kept in each state for at least Minimum Valve Time, to spare the actuator:
--- an open time shorter than that becomes 0 or the minimum, a closed time
--- shorter than that becomes 0 or the minimum, and a switch is held off until
--- the relay has been in its state that long. A close that is "immediate"
--- (mode Off, sensor lost, side changed) ignores the minimum.
---
--- A channel that goes from no demand to some starts a new cycle, so the
--- valve opens at once instead of waiting for the next cycle.

local Valves = {}
Valves.__index = Valves

Valves.CHANNELS = { "heat", "cool" }

function Valves.new()
  local self = setmetatable({}, Valves)
  self.cycle = 600
  self.minTime = 120
  self.ch = {}
  for _, name in ipairs(Valves.CHANNELS) do
    self.ch[name] = { open = false, lastSwitch = nil, cycleStart = nil, demand = 0 }
  end
  return self
end

--- cfg: cycle (s), minTime (s)
function Valves:configure(cfg)
  cfg = cfg or {}
  self.cycle = math.max(60, tonumber(cfg.cycle) or 600)
  self.minTime = math.max(0, math.min(tonumber(cfg.minTime) or 120, self.cycle / 2))
end

--- The open time within a cycle for a demand, after the minimum times.
function Valves:openTime(demand)
  local cycle, min = self.cycle, self.minTime
  if demand <= 0 then
    return 0
  elseif demand >= 100 then
    return cycle
  end
  local open = demand / 100 * cycle
  if open < min then
    open = open >= min / 2 and min or 0
  end
  local closed = cycle - open
  if closed > 0 and closed < min then
    open = closed >= min / 2 and cycle - min or cycle
  end
  return open
end

--- Update the channels.
--- @param now number seconds
--- @param demand table { heat = 0-100, cool = 0-100 }
--- @param immediate boolean|nil close without waiting for the minimum time
--- @return table { heat = bool, cool = bool } valve open
--- @return table|nil changed { heat = bool, cool = bool } channels that switched
function Valves:update(now, demand, immediate)
  local changed = nil
  for _, name in ipairs(Valves.CHANNELS) do
    local c = self.ch[name]
    local d = math.max(0, math.min(100, tonumber(demand[name]) or 0))
    if c.cycleStart == nil or now - c.cycleStart >= self.cycle or (c.demand <= 0 and d > 0) then
      c.cycleStart = now
    end
    c.demand = d
    local want = (now - c.cycleStart) < self:openTime(d)
    if want ~= c.open then
      local held = c.lastSwitch ~= nil and now - c.lastSwitch < self.minTime
      local closeNow = immediate and d <= 0 and not want
      if not held or closeNow then
        c.open = want
        c.lastSwitch = now
        changed = changed or {}
        changed[name] = true
      end
    end
  end
  return { heat = self.ch.heat.open, cool = self.ch.cool.open }, changed
end

--- Close everything at once (driver start, Off).
function Valves:closeAll(now)
  for _, name in ipairs(Valves.CHANNELS) do
    local c = self.ch[name]
    if c.open then
      c.lastSwitch = now
    end
    c.open = false
    c.demand = 0
    c.cycleStart = nil
  end
end

function Valves:isOpen(name)
  return self.ch[name] and self.ch[name].open or false
end

return Valves
