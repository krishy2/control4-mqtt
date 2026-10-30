--- @module "pi_thermostat.autotune"
--- Relay auto-tune (Astrom-Hagglund) for one side of the PI Thermostat.
---
--- The valve is driven fully open while the error is above +h and fully
--- closed while it is below -h, so the room oscillates around the setpoint.
--- After the first (transient) phase, CYCLES full cycles are measured:
---
---   a  = half the peak-to-peak of the error (amplitude)
---   Pu = time from one valve opening to the next (period)
---   Ku = 4 d / (pi * sqrt(a^2 - h^2)), d = 50 % (the relay swings 0-100 %)
---
--- and the PI gains follow Tyreus-Luyben, which is gentler than
--- Ziegler-Nichols and suits slow water-based systems:
---
---   Kp = Ku / 3.2      Ti = 2.2 Pu
---
--- The error is positive when the side has work to do, so the same logic
--- tunes heating and cooling.

local Autotune = {}
Autotune.__index = Autotune

Autotune.CYCLES = 2
Autotune.MAX_DURATION = 8 * 3600
Autotune.RELAY_AMPLITUDE = 50

function Autotune.new(side, now, opts)
  opts = opts or {}
  local self = setmetatable({}, Autotune)
  self.side = side
  self.start = now
  self.h = tonumber(opts.hysteresis) or 0.2
  self.maxDuration = tonumber(opts.maxDuration) or Autotune.MAX_DURATION
  self.cycles = tonumber(opts.cycles) or Autotune.CYCLES
  self.on = nil
  self.switches = 0
  self.onTimes = {} -- valve openings after the first switch
  self.maxima = {} -- error peaks while open (recorded on closing)
  self.minima = {} -- error troughs while closed (recorded on opening)
  self.extreme = nil
  self.now = now
  return self
end

local function mean(list, n)
  local sum, count = 0, 0
  for k = math.max(1, #list - n + 1), #list do
    sum = sum + list[k]
    count = count + 1
  end
  return count > 0 and sum / count or nil
end

function Autotune:measuredCycles()
  return math.max(0, #self.onTimes - 1)
end

function Autotune:progress()
  return {
    side = self.side,
    cycle = math.min(self:measuredCycles() + 1, self.cycles),
    cycles = self.cycles,
    open = self.on == true,
    elapsed = (self.now or self.start) - self.start,
  }
end

--- The gains from what was measured, or nil and a reason.
function Autotune:result()
  local n = self.cycles
  local period = nil
  if #self.onTimes >= n + 1 then
    period = (self.onTimes[#self.onTimes] - self.onTimes[#self.onTimes - n]) / n
  end
  local hi, lo = mean(self.maxima, n), mean(self.minima, n)
  if period == nil or hi == nil or lo == nil or #self.maxima < n or #self.minima < n then
    return nil
  end
  local a = (hi - lo) / 2
  if a <= 0 or period <= 0 then
    return { reason = "the temperature did not swing around the setpoint" }
  end
  local h = self.h
  local denominator = math.sqrt(math.max(a * a - h * h, 0))
  denominator = math.max(denominator, 0.3 * a)
  local ku = 4 * Autotune.RELAY_AMPLITUDE / (math.pi * denominator)
  return { kp = ku / 3.2, ti = 2.2 * period, ku = ku, pu = period, amplitude = a }
end

--- One step.
--- @param now number seconds
--- @param e number error, positive when the side has work to do
--- @return number output 0 or 100
--- @return boolean done
--- @return table|nil result { kp, ti, ku, pu, amplitude } or { reason }
function Autotune:step(now, e)
  self.now = now
  if now - self.start > self.maxDuration then
    return 0, true, { reason = "no steady swing within " .. math.floor(self.maxDuration / 3600) .. " h" }
  end
  if self.on == nil then
    self.on = e > 0
  end
  -- Track the extreme of the phase: troughs while closed, peaks while open
  if self.on then
    self.extreme = self.extreme and math.max(self.extreme, e) or e
  else
    self.extreme = self.extreme and math.min(self.extreme, e) or e
  end

  local switchTo = nil
  if self.on and e < -self.h then
    switchTo = false
  elseif not self.on and e > self.h then
    switchTo = true
  end
  if switchTo ~= nil then
    self.switches = self.switches + 1
    if self.switches > 1 then
      -- The first phase is the approach to the setpoint, not a swing
      if switchTo then
        self.minima[#self.minima + 1] = self.extreme
      else
        self.maxima[#self.maxima + 1] = self.extreme
      end
    end
    if switchTo then
      self.onTimes[#self.onTimes + 1] = now
    end
    self.on = switchTo
    self.extreme = e
    local res = self:result()
    if res then
      return 0, true, res
    end
  end
  return self.on and 100 or 0, false, nil
end

return Autotune
