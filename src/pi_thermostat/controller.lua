--- @module "pi_thermostat.controller"
--- The control loop of the PI Thermostat driver: which side (heat or cool)
--- is active, full power far from the setpoint, a PI controller near it, and
--- self-learning of the PI gains.
---
--- Everything is in degrees Celsius and seconds, and nothing here talks to
--- Control4: the driver passes the time and the inputs to update() and drives
--- the valves with the result, so the whole loop runs in tests.
---
--- Output is 0-100 % per side. The error is positive when the side has work
--- to do: heat setpoint - temperature for heating, temperature - cool
--- setpoint for cooling.
---
---   error > Full Power Threshold              -> full power (100 %)
---   full power and error < threshold - release -> PI, starting from 100 %
---                                                (bumpless: I = 100 - P)
---   otherwise                                 -> PI with anti-windup
---
--- Gains are kept per side (heating and cooling water differ). They come from
--- the defaults, from an auto-tune (relay test, see pi_thermostat.autotune),
--- and from continuous adaptation: every response to a setpoint step or
--- disturbance is an "episode"; at its end the gains are nudged by its
--- overshoot, oscillation and speed.

local Autotune = require("pi_thermostat.autotune")

local Controller = {}
Controller.__index = Controller

Controller.SIDES = { "heat", "cool" }

--- Starting gains: Kp in % output per °C of error, Ti in seconds.
Controller.DEFAULT_KP = 30
Controller.DEFAULT_TI = 1800

--- Limits for learned and entered gains.
Controller.KP_MIN, Controller.KP_MAX = 2, 300
Controller.TI_MIN, Controller.TI_MAX = 120, 14400

--- Response (user setting in Extras): multiplies Kp.
Controller.RESPONSE = { Slow = 0.6, Normal = 1, Fast = 1.5 }

--- Adaptation.
Controller.EPISODE_START = 0.5 -- °C of error that starts an episode
Controller.SETTLE_BAND = 0.2 -- °C: within this the response has settled
Controller.SETTLE_TIME = 1800 -- s within the band that ends an episode
Controller.EPISODE_MAX = 4 * 3600 -- s; longer when Ti is long (6 Ti)
Controller.SETPOINT_STEP = 0.3 -- °C: a setpoint change this big restarts the episode
Controller.MAX_DT = 300 -- s: longer gaps are not integrated

local function clamp(v, lo, hi)
  if v < lo then
    return lo
  elseif v > hi then
    return hi
  end
  return v
end

local function round(v, decimals)
  local m = 10 ^ (decimals or 0)
  return math.floor(v * m + 0.5) / m
end

function Controller.clampGains(kp, ti)
  kp = tonumber(kp) or Controller.DEFAULT_KP
  ti = tonumber(ti) or Controller.DEFAULT_TI
  return round(clamp(kp, Controller.KP_MIN, Controller.KP_MAX), 2),
    round(clamp(ti, Controller.TI_MIN, Controller.TI_MAX), 0)
end

-------------------------------------------------------------------------------
-- Construction, configuration, persistence
-------------------------------------------------------------------------------

--- @param opts table|nil { onGainsChanged = fn(side, gains, reason), onEvent = fn(name, detail) }
function Controller.new(opts)
  opts = opts or {}
  local self = setmetatable({}, Controller)
  self.onGainsChanged = opts.onGainsChanged
  self.onEvent = opts.onEvent
  self.cfg = {}
  self.gains = {}
  for _, side in ipairs(Controller.SIDES) do
    self.gains[side] = { kp = Controller.DEFAULT_KP, ti = Controller.DEFAULT_TI, source = "default", learned = 0 }
  end
  self.integral = { heat = 0, cool = 0 }
  self.side = nil
  self.full = false
  self.episode = nil
  self.autotune = nil
  self.lastTime = nil
  self.lastSetpoint = {}
  self.result = { state = "off", output = 0, heat = 0, cool = 0 }
  self:configure({})
  return self
end

--- cfg: valveCount (1|2), singleValveUse ("Heat"|"Cool"|"Changeover"),
--- fullThreshold, fullRelease (°C), response ("Slow"|"Normal"|"Fast"),
--- learning (bool), tuneHysteresis (°C).
function Controller:configure(cfg)
  cfg = cfg or {}
  local c = {}
  c.valveCount = tonumber(cfg.valveCount) == 1 and 1 or 2
  local use = tostring(cfg.singleValveUse or "Heat")
  c.singleValveUse = (use == "Cool" or use == "Changeover") and use or "Heat"
  c.fullThreshold = clamp(tonumber(cfg.fullThreshold) or 5, 0.5, 30)
  c.fullRelease = clamp(tonumber(cfg.fullRelease) or 0.5, 0, c.fullThreshold)
  c.response = Controller.RESPONSE[cfg.response] and cfg.response or "Normal"
  c.learning = cfg.learning ~= false
  c.tuneHysteresis = clamp(tonumber(cfg.tuneHysteresis) or 0.2, 0.05, 2)
  self.cfg = c
end

--- Which sides the valves can serve.
function Controller:sides()
  local c = self.cfg
  if c.valveCount == 2 or c.singleValveUse == "Changeover" then
    return { heat = true, cool = true }
  end
  return { heat = c.singleValveUse == "Heat", cool = c.singleValveUse == "Cool" }
end

--- HVAC modes Control4 may offer. Auto needs both valves: with one
--- changeover valve the water is hot or cold, so the mode says which.
function Controller:modes()
  local s = self:sides()
  local modes = { "Off" }
  if s.heat then
    modes[#modes + 1] = "Heat"
  end
  if s.cool then
    modes[#modes + 1] = "Cool"
  end
  if self.cfg.valveCount == 2 then
    modes[#modes + 1] = "Auto"
  end
  return modes
end

function Controller:isModeAllowed(mode)
  for _, m in ipairs(self:modes()) do
    if m == mode then
      return true
    end
  end
  return false
end

--- The gains in use for a side, with the Response multiplier: kp, ti.
function Controller:effectiveGains(side)
  local g = self.gains[side]
  return g.kp * (Controller.RESPONSE[self.cfg.response] or 1), g.ti
end

--- Set a side's gains (from a property, an auto-tune or learning).
function Controller:setGains(side, kp, ti, source)
  local g = self.gains[side]
  if g == nil then
    return
  end
  local newKp, newTi = Controller.clampGains(kp, ti)
  if newKp == g.kp and newTi == g.ti and source == g.source then
    return
  end
  g.kp, g.ti = newKp, newTi
  g.source = source or g.source
  if source == "learned" then
    g.learned = (g.learned or 0) + 1
  elseif source ~= nil and source ~= "learned" then
    -- A tune or a manual entry is a new starting point for learning
    g.learned = 0
  end
  if self.onGainsChanged then
    self.onGainsChanged(side, g, source)
  end
end

function Controller:resetGains()
  for _, side in ipairs(Controller.SIDES) do
    self:setGains(side, Controller.DEFAULT_KP, Controller.DEFAULT_TI, "default")
  end
  self.episode = nil
end

--- What is saved to disk.
function Controller:snapshot()
  local s = { gains = {}, integral = {} }
  for _, side in ipairs(Controller.SIDES) do
    local g = self.gains[side]
    s.gains[side] = { kp = g.kp, ti = g.ti, source = g.source, learned = g.learned, at = g.at }
    s.integral[side] = round(self.integral[side] or 0, 3)
  end
  return s
end

function Controller:restore(s)
  if type(s) ~= "table" then
    return
  end
  for _, side in ipairs(Controller.SIDES) do
    local g = type(s.gains) == "table" and s.gains[side]
    if type(g) == "table" then
      local kp, ti = Controller.clampGains(g.kp, g.ti)
      self.gains[side] = {
        kp = kp,
        ti = ti,
        source = tostring(g.source or "default"),
        learned = tonumber(g.learned) or 0,
        at = tonumber(g.at),
      }
    end
    local i = type(s.integral) == "table" and tonumber(s.integral[side])
    if i then
      self.integral[side] = clamp(i, 0, 100)
    end
  end
end

-------------------------------------------------------------------------------
-- Auto-tune
-------------------------------------------------------------------------------

--- Start a relay auto-tune for a side; nil, reason when it cannot start.
function Controller:startAutotune(side, now)
  if not self:sides()[side] then
    return nil, "this valve setup has no " .. (side == "heat" and "heating" or "cooling")
  end
  self.autotune = Autotune.new(side, now, { hysteresis = self.cfg.tuneHysteresis })
  self.episode = nil
  self:_event("autotune_started", side)
  return true
end

function Controller:stopAutotune(reason)
  if self.autotune == nil then
    return false
  end
  local side = self.autotune.side
  self.autotune = nil
  self:_event("autotune_failed", side, reason or "stopped")
  return true
end

function Controller:_event(name, side, detail)
  if self.onEvent then
    self.onEvent(name, side, detail)
  end
end

-------------------------------------------------------------------------------
-- The loop
-------------------------------------------------------------------------------

--- The side to run for a mode.
function Controller:_selectSide(mode, t, heatSp, coolSp)
  local sides = self:sides()
  local side
  if mode == "Heat" then
    side = "heat"
  elseif mode == "Cool" then
    side = "cool"
  elseif mode == "Auto" then
    if t < heatSp then
      side = "heat"
    elseif t > coolSp then
      side = "cool"
    else
      side = self.side -- between the setpoints the last side winds down
    end
  end
  if side ~= nil and not sides[side] then
    return nil
  end
  return side
end

local function errorFor(side, t, heatSp, coolSp)
  if side == "heat" then
    return heatSp - t
  end
  return t - coolSp
end

local function setpointFor(side, heatSp, coolSp)
  return side == "heat" and heatSp or coolSp
end

--- Change side: the old one stops at once and forgets its integral.
function Controller:_switchSide(side)
  if side == self.side then
    return
  end
  if self.side ~= nil then
    self.integral[self.side] = 0
  end
  self.side = side
  self.full = false
  self.episode = nil
end

--- Run the loop.
--- @param now number seconds
--- @param input table { temperature, sensorOk, mode, heatSetpoint, coolSetpoint }
--- @return table result { state, side, error, output, heat, cool, p, i, kp, ti, tune }
---   state: "off" | "sensor" | "idle" | "full" | "pi" | "autotune"
function Controller:update(now, input)
  local dt = self.lastTime and (now - self.lastTime) or 0
  self.lastTime = now
  if dt < 0 or dt > Controller.MAX_DT then
    dt = 0
  end
  local mode = input.mode or "Off"
  local t = tonumber(input.temperature)
  local heatSp, coolSp = tonumber(input.heatSetpoint) or 21, tonumber(input.coolSetpoint) or 24

  local result = { state = "off", output = 0, heat = 0, cool = 0 }
  self.result = result

  if mode == "Off" or not self:isModeAllowed(mode) then
    self:_switchSide(nil)
    if self.autotune then
      self:stopAutotune("the mode is Off")
    end
    return result
  end
  if not input.sensorOk or t == nil then
    -- Valves closed; the integral is kept for when the sensor returns
    result.state = "sensor"
    self.full = false
    self.episode = nil
    if self.autotune then
      self:stopAutotune("the temperature sensor stopped reporting")
    end
    return result
  end

  -- An auto-tune runs its side whatever Auto would pick.
  local side
  if self.autotune then
    side = self.autotune.side
    if (mode == "Heat" and side ~= "heat") or (mode == "Cool" and side ~= "cool") then
      self:stopAutotune("the mode changed")
      side = self:_selectSide(mode, t, heatSp, coolSp)
    end
  else
    side = self:_selectSide(mode, t, heatSp, coolSp)
  end
  self:_switchSide(side)
  if side == nil then
    result.state = "idle"
    return result
  end

  local e = errorFor(side, t, heatSp, coolSp)
  local sp = setpointFor(side, heatSp, coolSp)
  result.side, result.error = side, e

  -- A setpoint step restarts adaptation
  local lastSp = self.lastSetpoint[side]
  if lastSp ~= nil and math.abs(sp - lastSp) >= Controller.SETPOINT_STEP then
    self.episode = nil
  end
  self.lastSetpoint[side] = sp

  local kp, ti = self:effectiveGains(side)
  result.kp, result.ti = kp, ti

  -- Auto-tune: a relay test around the setpoint
  if self.autotune then
    local tune = self.autotune
    local out, done, res = tune:step(now, e)
    result.state, result.tune = "autotune", tune:progress()
    if done then
      self.autotune = nil
      if res and res.kp then
        self.gains[side].at = now
        self:setGains(side, res.kp, res.ti, "tuned")
        self.integral[side] = 0
        self:_event("autotune_finished", side, res)
        -- Hand over to the PI below
      else
        self:_event("autotune_failed", side, res and res.reason or "failed")
      end
    else
      result.output = out
      result[side] = out
      return result
    end
    kp, ti = self:effectiveGains(side)
    result.kp, result.ti = kp, ti
    result.state = nil
  end

  -- Full power far from the setpoint, with a release hysteresis
  local threshold, release = self.cfg.fullThreshold, self.cfg.fullRelease
  if e > threshold then
    if not self.full then
      self.full = true
      self.episode = nil
      self:_event("full_started", side, e)
    end
  elseif self.full and e < threshold - release then
    self.full = false
    -- Bumpless: the PI starts where full power was
    self.integral[side] = clamp(100 - kp * e, 0, 100)
    self:_event("full_ended", side, e)
  end
  if self.full then
    result.state, result.output, result[side] = "full", 100, 100
    result.p, result.i = 100, 0
    return result
  end

  -- PI with conditional integration (no wind-up against 0 or 100 %)
  local p = kp * e
  local i = self.integral[side] or 0
  if dt > 0 then
    local di = kp * e * dt / ti
    local unsat = p + i
    if not ((unsat >= 100 and di > 0) or (unsat <= 0 and di < 0)) then
      i = clamp(i + di, 0, 100)
    end
  end
  self.integral[side] = i
  local u = clamp(p + i, 0, 100)
  if u < 0.5 then
    u = 0
  end
  result.state = u > 0 and "pi" or "idle"
  result.output, result[side] = u, u
  result.p, result.i = p, i

  if self.cfg.learning then
    self:_learn(now, side, e, u, dt)
  else
    self.episode = nil
  end
  return result
end

-------------------------------------------------------------------------------
-- Continuous adaptation
-------------------------------------------------------------------------------

local function sign(v, dead)
  if v > dead then
    return 1
  elseif v < -dead then
    return -1
  end
  return 0
end

--- Track the current episode; adjust the gains when it ends.
function Controller:_learn(now, side, e, u, dt)
  local ep = self.episode
  if ep == nil then
    -- Only a deviation the controller works against: a room warmer than the
    -- heat setpoint (sun, the Auto deadband) is not a response to learn from.
    if e >= Controller.EPISODE_START then
      self.episode = {
        side = side,
        start = now,
        startErr = math.abs(e),
        dir = 1,
        lastSign = 1,
        crossings = 0,
        overshoot = 0,
        saturated = 0,
        reachedAt = nil,
        settledSince = nil,
      }
    end
    return
  end
  if ep.side ~= side then
    self.episode = nil
    return
  end

  -- Error measured towards the setpoint: past it is overshoot
  local towards = e * ep.dir
  local s = sign(e, 0.05)
  if s ~= 0 and s ~= ep.lastSign then
    ep.crossings = ep.crossings + 1
    ep.lastSign = s
    if ep.reachedAt == nil then
      ep.reachedAt = now
    end
  end
  if towards < 0 then
    ep.overshoot = math.max(ep.overshoot, -towards)
  end
  if u >= 99.5 then
    ep.saturated = ep.saturated + dt
  end
  if ep.reachedAt == nil and math.abs(e) <= Controller.SETTLE_BAND then
    ep.reachedAt = now
  end
  if math.abs(e) <= Controller.SETTLE_BAND then
    ep.settledSince = ep.settledSince or now
  else
    ep.settledSince = nil
  end

  local g = self.gains[side]
  local maxTime = math.max(Controller.EPISODE_MAX, 6 * g.ti)
  local settled = ep.reachedAt ~= nil and ep.settledSince ~= nil and now - ep.settledSince >= Controller.SETTLE_TIME
  if settled or now - ep.start >= maxTime then
    self.episode = nil
    self:_evaluate(now, ep)
  end
end

--- Nudge the gains from a finished episode.
--- @return string verdict
function Controller:_evaluate(now, ep)
  local side = ep.side
  local g = self.gains[side]
  local duration = math.max(now - ep.start, 1)
  local saturatedShare = ep.saturated / duration
  local overshootLimit = math.max(0.3, 0.2 * ep.startErr)
  local kpFactor, tiFactor, verdict = 1, 1, "good"
  if ep.overshoot > overshootLimit or ep.crossings >= 3 then
    kpFactor, tiFactor, verdict = 0.85, 1.15, "overshoot"
  elseif ep.reachedAt == nil then
    if saturatedShare > 0.5 then
      verdict = "capacity" -- the valve was open; more gain would not help
    else
      kpFactor, tiFactor, verdict = 1.15, 0.85, "slow"
    end
  elseif ep.overshoot < 0.1 and ep.reachedAt - ep.start > 2 * g.ti and saturatedShare < 0.5 then
    kpFactor, tiFactor, verdict = 1.1, 0.9, "sluggish"
  end
  self.lastVerdict = { side = side, verdict = verdict, at = now }
  if kpFactor ~= 1 or tiFactor ~= 1 then
    g.at = now
    self:setGains(side, g.kp * kpFactor, g.ti * tiFactor, "learned")
  end
  self:_event("learned", side, verdict)
  return verdict
end

return Controller
