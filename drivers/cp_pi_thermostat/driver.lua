--- PI Thermostat Driver
--- A Control4 thermostat that runs its own PI controller: the temperature comes
--- from a bound temperature sensor (TEMPERATURE_VALUE), the setpoints are kept
--- in the driver, and the output drives one or two water valves through
--- Control4 relays (time-proportional).
---
--- No MQTT: this driver does not connect to the MQTT Broker. It belongs to the
--- cp_ suite for its naming, code and versioning.
---
--- Far from the setpoint (more than Full Power Above, 5 °C by default) the valve
--- is fully open; nearer, the PI controller takes over, starting where full
--- power left off. The PI gains are learned per side (heating, cooling): an
--- auto-tune started from Extras, then continuous adaptation. Settings, setpoints
--- and learned gains are saved to the controller's disk (persist).
---
--- The proxy's Message shows what the controller is doing; user settings are in
--- Extras; preset scheduling is the thermostat proxy's own.

require("lib.utils")
require("drivers-common-public.global.handlers")
require("drivers-common-public.global.lib")
require("drivers-common-public.global.timer")

local log = require("lib.logging")
local persist = require("lib.persist")
local constants = require("constants")

local Controller = require("pi_thermostat.controller")
local Valves = require("pi_thermostat.valves")
local Ui = require("pi_thermostat.ui")

-- Binding IDs
local PROXY_BINDING = 5001
local SENSOR_BINDING = 1
local HEAT_VALVE_BINDING = 2
local COOL_VALVE_BINDING = 3

-- Persist keys
local STATE_KEY = "ThermostatState"
local SETTINGS_KEY = "Settings"
local CONTROLLER_KEY = "Controller"
local PRESETS_KEY = "Presets"

local LOOP_INTERVAL = 10 -- seconds
local SENSOR_POLL = 5 * 60 -- seconds between GET_SENSOR_VALUE
local MESSAGE_MIN_INTERVAL = 60 -- seconds between message updates with the same headline
local PROXY_READY_DELAY = 3 * ONE_SECOND

--- @type table
local controller
--- @type table
local valves
--- User settings (Extras), normalized
local settings = {}
--- Thermostat state: mode, heat, cool (°C), scale, preset
local state = {}
--- Temperature input: celsius, at (os.time of the last reading), available
local sensor = { available = false }
--- Presets the proxy sent: name -> fields
local presets = {}
--- What the proxy was last told: command -> signature
local sent = {}
--- Relay commands last sent: binding -> "OPEN"|"CLOSE"
local relaySent = {}
--- Relay feedback: binding -> "Closed"|"Opened"
local relayFeedback = {}
local lastResult = nil
local lastSide = nil
local lastSensorOk = nil
local lastMessage = { text = nil, headline = nil, at = 0 }
local lastSensorPoll = 0

local function now()
  return os.time()
end

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

local function prop(name)
  local v = Properties[name]
  if v == nil then
    return ""
  end
  return v
end

local function round(v, step)
  step = step or 0.1
  return math.floor(v / step + 0.5) * step
end

local function toScale(c, scale)
  return scale == "F" and c * 9 / 5 + 32 or c
end

local function fireEvent(name)
  if C4.FireEvent then
    C4:FireEvent(name)
  end
end

local function setVariable(name, value)
  if Variables and Variables[name] ~= nil and Variables[name] ~= tostring(value) then
    C4:SetVariable(name, tostring(value))
  end
end

--- True when something is bound to one of our consumer connections.
local function isBound(binding)
  local id = tonumber(C4:GetBoundProviderDevice(0, binding))
  return id ~= nil and id ~= 0
end

local function scale()
  return state.scale == "F" and "F" or "C"
end

--- Setpoint limits in °C: min, max, deadband
local function limits()
  local min = tonumber(prop("Setpoint Minimum")) or 5
  local max = tonumber(prop("Setpoint Maximum")) or 35
  if max < min then
    min, max = max, min
  end
  local deadband = tonumber(prop("Heat Cool Deadband")) or 1
  return min, max, deadband
end

-------------------------------------------------------------------------------
-- Persistence
-------------------------------------------------------------------------------

local function saveState()
  persist:set(STATE_KEY, {
    mode = state.mode,
    heat = state.heat,
    cool = state.cool,
    scale = state.scale,
    preset = state.preset,
  })
end

local function saveController(now_)
  local snap = controller:snapshot()
  snap.savedAt = now_ or now()
  persist:set(CONTROLLER_KEY, snap)
end

-------------------------------------------------------------------------------
-- Proxy notifications
-------------------------------------------------------------------------------

local function notify(command, params)
  SendToProxy(PROXY_BINDING, command, params or {}, "NOTIFY")
end

--- Notify only when the parameters changed (or force).
local function notifyChanged(command, params, force)
  local keys = {}
  for k in pairs(params) do
    keys[#keys + 1] = k
  end
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do
    parts[#parts + 1] = k .. "=" .. tostring(params[k])
  end
  local sig = table.concat(parts, ";")
  if not force and sent[command] == sig then
    return
  end
  sent[command] = sig
  notify(command, params)
end

local function tempText(c)
  return Ui.num(round(toScale(c, scale()), 0.1), 1)
end

local function sendCapabilities()
  local min, max, deadband = limits()
  local sides = controller:sides()
  local caps = {
    CAN_HEAT = tostring(sides.heat),
    CAN_COOL = tostring(sides.cool),
    CAN_DO_AUTO = "false",
    HAS_SINGLE_SETPOINT = "false",
    HAS_HUMIDITY = "false",
    HAS_EXTRAS = "true",
    CAN_PRESET = "true",
    CAN_PRESET_SCHEDULE = "true",
    SETPOINT_HEATCOOL_DEADBAND_C = Ui.num(deadband),
    SETPOINT_HEATCOOL_DEADBAND_F = Ui.num(math.floor(deadband * 9 / 5 + 0.5)),
  }
  for _, p in ipairs({ "HEAT", "COOL" }) do
    caps[p .. "_SETPOINT_MIN_C"] = Ui.num(min)
    caps[p .. "_SETPOINT_MAX_C"] = Ui.num(max)
    caps[p .. "_SETPOINT_MIN_F"] = Ui.num(math.floor(toScale(min, "F") + 0.5))
    caps[p .. "_SETPOINT_MAX_F"] = Ui.num(math.floor(toScale(max, "F") + 0.5))
    caps[p .. "_SETPOINT_RESOLUTION_C"] = "0.5"
    caps[p .. "_SETPOINT_RESOLUTION_F"] = "1"
  end
  notify("DYNAMIC_CAPABILITIES_CHANGED", caps)
  notify("ALLOWED_HVAC_MODES_CHANGED", { MODES = table.concat(controller:modes(), ",") })
  notify("SCALE_CHANGED", { SCALE = scale() })
  notify("CONNECTION", { CONNECTED = "true" })
  notify("PRESET_FIELDS_CHANGED", {
    XML = Ui.presetFields(controller:modes(), {
      min = min,
      max = max,
      minF = math.floor(toScale(min, "F") + 0.5),
      maxF = math.floor(toScale(max, "F") + 0.5),
    }),
  })
end

local function sendExtras()
  notify("EXTRAS_SETUP_CHANGED", { XML = Ui.extrasSetup(settings, controller:sides()) })
  notify("EXTRAS_STATE_CHANGED", { XML = Ui.extrasState(settings) })
end

--- Temperature, setpoints and mode.
local function reportState(force)
  local s = scale()
  if sensor.celsius ~= nil then
    notifyChanged("TEMPERATURE_CHANGED", { TEMPERATURE = tempText(sensor.celsius), SCALE = s }, force)
  end
  notifyChanged("HEAT_SETPOINT_CHANGED", { SETPOINT = tempText(state.heat), SCALE = s }, force)
  notifyChanged("COOL_SETPOINT_CHANGED", { SETPOINT = tempText(state.cool), SCALE = s }, force)
  notifyChanged("HVAC_MODE_CHANGED", { MODE = state.mode }, force)
  if state.preset ~= nil then
    notifyChanged("PRESET_CHANGED", { NAME = state.preset }, force)
  end
  UpdateProperty(
    "Temperature",
    sensor.celsius ~= nil and (tempText(sensor.celsius) .. " °" .. s .. (sensor.available and "" or " (unavailable)"))
      or "No reading"
  )
end

-------------------------------------------------------------------------------
-- Valves (relays)
-------------------------------------------------------------------------------

local function relayCommand(open)
  local closeOpens = prop("Valve Opens When Relay Is") ~= "Opened"
  if open == closeOpens then
    return "CLOSE"
  end
  return "OPEN"
end

local function setRelay(binding, open, force)
  local command = relayCommand(open)
  if not force and relaySent[binding] == command then
    return
  end
  relaySent[binding] = command
  log:debug("Relay %s: %s (valve %s)", binding, command, open and "open" or "closed")
  SendToProxy(binding, command, {})
end

--- Which relay connections each channel drives, for the valve setup.
local function relayMap()
  local c = controller.cfg
  if c.valveCount == 2 then
    return { [HEAT_VALVE_BINDING] = { "heat" }, [COOL_VALVE_BINDING] = { "cool" } }
  elseif c.singleValveUse == "Heat" then
    return { [HEAT_VALVE_BINDING] = { "heat" }, [COOL_VALVE_BINDING] = {} }
  elseif c.singleValveUse == "Cool" then
    return { [HEAT_VALVE_BINDING] = {}, [COOL_VALVE_BINDING] = { "cool" } }
  end
  -- Changeover: one valve; it is driven on whichever connection is bound
  return { [HEAT_VALVE_BINDING] = { "heat", "cool" }, [COOL_VALVE_BINDING] = { "heat", "cool" } }
end

local function relayOpen(binding)
  for _, channel in ipairs(relayMap()[binding] or {}) do
    if valves:isOpen(channel) then
      return true
    end
  end
  return false
end

local function valveText(binding)
  local open = relayOpen(binding)
  local text = open and "Open" or "Closed"
  if #(relayMap()[binding] or {}) == 0 then
    text = "Not used"
  elseif not isBound(binding) then
    text = text .. " (not bound)"
  elseif relayFeedback[binding] ~= nil then
    text = text .. " (relay " .. relayFeedback[binding]:lower() .. ")"
  end
  return text
end

local function driveRelays(force)
  for _, binding in ipairs({ HEAT_VALVE_BINDING, COOL_VALVE_BINDING }) do
    setRelay(binding, relayOpen(binding), force)
  end
  UpdateProperty("Heat Valve", valveText(HEAT_VALVE_BINDING))
  UpdateProperty("Cool Valve", valveText(COOL_VALVE_BINDING))
  setVariable("HEAT_VALVE_OPEN", relayOpen(HEAT_VALVE_BINDING) and "1" or "0")
  setVariable("COOL_VALVE_OPEN", relayOpen(COOL_VALVE_BINDING) and "1" or "0")
end

-------------------------------------------------------------------------------
-- The loop
-------------------------------------------------------------------------------

local STATE_TEXT = {
  off = "Off",
  sensor = "No temperature reading",
  idle = "Idle",
  full = "Full power",
  pi = "PI control",
  autotune = "Auto-tune",
}

local function sensorOk(t)
  if not sensor.available or sensor.celsius == nil or sensor.at == nil then
    return false
  end
  return t - sensor.at <= (settings.sensor_timeout or 15) * 60
end

local function hvacState(r)
  if state.mode == "Off" then
    return "Off"
  end
  if (r.output or 0) > 0 and r.side ~= nil then
    return r.side == "heat" and "Heating" or "Cooling"
  end
  return "Idle"
end

local function sendMessage(r, t, force)
  local text = Ui.message(r, {
    scale = scale(),
    mode = state.mode,
    valveCount = controller.cfg.valveCount,
    valves = { heat = valves:isOpen("heat"), cool = valves:isOpen("cool") },
    gains = controller.gains,
  })
  local headline = text:match("^[^\n:]*")
  if text == lastMessage.text then
    return
  end
  if not force and headline == lastMessage.headline and t - lastMessage.at < MESSAGE_MIN_INTERVAL then
    return
  end
  lastMessage = { text = text, headline = headline, at = t }
  notify("MESSAGE_CHANGED", { MESSAGE = text })
end

--- One pass of the controller; called every LOOP_INTERVAL and on changes.
local function tick(force)
  if controller == nil then
    return
  end
  local t = now()
  local ok = sensorOk(t)
  if lastSensorOk ~= nil and ok ~= lastSensorOk then
    if ok then
      log:info("Temperature reading back")
      fireEvent("Sensor Restored")
    else
      log:warn("No temperature reading: closing the valves")
      fireEvent("Sensor Lost")
    end
  end
  lastSensorOk = ok

  local r = controller:update(t, {
    temperature = sensor.celsius,
    sensorOk = ok,
    mode = state.mode,
    heatSetpoint = state.heat,
    coolSetpoint = state.cool,
  })
  local immediate = r.state == "off" or r.state == "sensor" or r.side ~= lastSide
  lastSide = r.side
  local _, changed = valves:update(t, { heat = r.heat or 0, cool = r.cool or 0 }, immediate)
  driveRelays(force)
  lastResult = r

  notifyChanged("HVAC_STATE_CHANGED", { STATE = hvacState(r) }, force)
  sendMessage(r, t, force or changed ~= nil)

  local stateText = STATE_TEXT[r.state] or tostring(r.state)
  if r.side ~= nil and (r.state == "pi" or r.state == "full" or r.state == "autotune") then
    stateText = stateText .. (r.side == "heat" and " (heating)" or " (cooling)")
  end
  UpdateProperty("Controller State", stateText)
  UpdateProperty("Controller Output", Ui.num(r.output or 0, 0) .. " %")
  setVariable("CONTROLLER_STATE", stateText)
  setVariable("CONTROLLER_OUTPUT", Ui.num(r.output or 0, 0))

  -- The integral changes every pass: write-behind keeps disk writes rare
  saveController(t)

  if t - lastSensorPoll >= SENSOR_POLL and isBound(SENSOR_BINDING) then
    lastSensorPoll = t
    SendToProxy(SENSOR_BINDING, "GET_SENSOR_VALUE", {})
  end
end

-------------------------------------------------------------------------------
-- Configuration
-------------------------------------------------------------------------------

local function controllerConfig()
  local use = prop("Single Valve Use")
  return {
    valveCount = prop("Valve Count") == "1 Valve" and 1 or 2,
    singleValveUse = use == "Cool Only" and "Cool" or (use == "Changeover" and "Changeover" or "Heat"),
    fullThreshold = settings.full_threshold,
    fullRelease = settings.full_release,
    response = settings.response,
    learning = settings.learning,
  }
end

local function updatePropertyVisibility()
  local single = prop("Valve Count") == "1 Valve"
  C4:SetPropertyAttribs("Single Valve Use", single and constants.SHOW_PROPERTY or constants.HIDE_PROPERTY)
  local sides = controller:sides()
  for _, name in ipairs({ "Heating Kp", "Heating Ti" }) do
    C4:SetPropertyAttribs(name, sides.heat and constants.SHOW_PROPERTY or constants.HIDE_PROPERTY)
  end
  for _, name in ipairs({ "Cooling Kp", "Cooling Ti" }) do
    C4:SetPropertyAttribs(name, sides.cool and constants.SHOW_PROPERTY or constants.HIDE_PROPERTY)
  end
end

--- Keep the setpoints within the limits and the deadband. `moved` is the one
--- the user changed; the other one gives way.
local function fitSetpoints(moved)
  local min, max, deadband = limits()
  local heat = math.max(min, math.min(max, round(tonumber(state.heat) or 21, 0.1)))
  local cool = math.max(min, math.min(max, round(tonumber(state.cool) or 24, 0.1)))
  if cool - heat < deadband - 1e-6 then
    if moved == "cool" then
      heat = cool - deadband
      if heat < min then
        heat = min
        cool = min + deadband
      end
    else
      cool = heat + deadband
      if cool > max then
        cool = max
        heat = max - deadband
      end
    end
  end
  state.heat, state.cool = round(heat, 0.1), round(cool, 0.1)
end

local function applyConfig()
  controller:configure(controllerConfig())
  valves:configure({ cycle = (settings.cycle_time or 10) * 60, minTime = (settings.min_valve_time or 2) * 60 })
  if not controller:isModeAllowed(state.mode) then
    log:info("Mode %s is not possible with this valve setup; switching Off", tostring(state.mode))
    state.mode = "Off"
  end
  fitSetpoints(nil)
  saveState()
  updatePropertyVisibility()
end

--- Show the gains in their properties (Ti in minutes).
local function showGains()
  local function show(side, kpName, tiName)
    local g = controller.gains[side]
    UpdateProperty(kpName, Ui.num(g.kp, 2))
    UpdateProperty(tiName, Ui.num(g.ti / 60, 1))
  end
  show("heat", "Heating Kp", "Heating Ti")
  show("cool", "Cooling Kp", "Cooling Ti")
end

-------------------------------------------------------------------------------
-- Commands
-------------------------------------------------------------------------------

local function setMode(mode)
  if not controller:isModeAllowed(mode) then
    log:warn("HVAC mode '%s' is not available with this valve setup", tostring(mode))
    reportState(true)
    return
  end
  if state.mode ~= mode then
    log:info("HVAC mode: %s", mode)
  end
  state.mode = mode
  saveState()
  reportState(false)
  tick(false)
end

local function setSetpoint(which, celsius)
  if celsius == nil then
    return
  end
  state[which] = celsius
  fitSetpoints(which)
  log:info("Setpoints: heat %s °C, cool %s °C", Ui.num(state.heat, 1), Ui.num(state.cool, 1))
  saveState()
  reportState(false)
  tick(false)
end

local function stepSetpoint(which, direction)
  local step = scale() == "F" and 5 / 9 or 0.5
  local target = (state[which] or 21) + direction * step
  if scale() == "F" then
    target = (math.floor(toScale(target, "F") + 0.5) - 32) * 5 / 9
  end
  setSetpoint(which, target)
end

local function startAutotune(side)
  if state.mode == "Off" then
    log:warn("Auto-tune needs a mode other than Off")
    notify("MESSAGE_CHANGED", { MESSAGE = "Auto-tune needs the thermostat on (Heat, Cool or Auto)" })
    return
  end
  local ok, err = controller:startAutotune(side, now())
  if not ok then
    log:warn("Auto-tune not started: %s", tostring(err))
    return
  end
  log:info("Auto-tune %s started", side == "heat" and "heating" or "cooling")
  tick(true)
end

local function resetGains()
  controller:resetGains()
  log:info("Learned gains reset to the defaults")
  UpdateProperty("Last Learning", "Gains reset " .. os.date("%Y-%m-%d %H:%M"))
  tick(true)
end

--- Apply preset fields (from SET_PRESET, SET_EVENT or SET_PRESETS).
local function applyPresetFields(name, fields)
  local changes = Ui.presetChanges(fields or {})
  log:info("Running preset '%s'", tostring(name))
  if changes.heat ~= nil then
    state.heat = changes.heat
    fitSetpoints("heat")
  end
  if changes.cool ~= nil then
    state.cool = changes.cool
    fitSetpoints("cool")
  end
  if changes.mode ~= nil and controller:isModeAllowed(changes.mode) then
    state.mode = changes.mode
  end
  if name ~= nil and name ~= "" then
    state.preset = name
  end
  saveState()
  reportState(false)
  tick(false)
end

--- Every XML preset list or field set in the parameters.
local function presetsFromParams(tParams)
  local found, fields = false, {}
  for _, v in pairs(tParams or {}) do
    if type(v) == "string" and v:find("<", 1, true) then
      local list = Ui.parsePresets(v)
      for name, f in pairs(list) do
        presets[name] = f
        found = true
      end
      for k, f in pairs(Ui.parseFields(v)) do
        fields[k] = f
      end
    end
  end
  if found then
    persist:set(PRESETS_KEY, presets)
  end
  return fields
end

local function onSettingChanged(id, value)
  if settings[id] == value then
    return
  end
  log:info("Setting %s: %s", id, tostring(value))
  settings[id] = value
  persist:set(SETTINGS_KEY, settings)
  applyConfig()
  sendExtras()
  tick(true)
end

local function handleExtras(command, tParams)
  local action = Ui.parseCommand(command, tParams)
  if action == nil then
    return false
  end
  if action.invalid then
    log:warn("Extras %s: value not understood (%s)", command, tParams)
    sendExtras()
  elseif action.setting then
    onSettingChanged(action.setting, action.value)
  elseif action.button == "tune_heat" then
    startAutotune("heat")
  elseif action.button == "tune_cool" then
    startAutotune("cool")
  elseif action.button == "tune_stop" then
    if controller:stopAutotune("stopped from Extras") then
      tick(true)
    end
  elseif action.button == "reset_gains" then
    resetGains()
  end
  return true
end

--- Commands from the thermostat proxy.
RFP[PROXY_BINDING] = function(idBinding, strCommand, tParams, _args)
  tParams = tParams or {}
  log:debug("Thermostat command %s %s", strCommand, tParams)
  if handleExtras(strCommand, tParams) then
    return
  end
  if strCommand == "SET_SETPOINT_HEAT" or strCommand == "SET_SETPOINT_COOL" or strCommand == "SET_SETPOINT_SINGLE" then
    local c = CelsiusFromParams(tParams, scale())
    if c == nil then
      c = tonumber(Select(tParams, "SETPOINT"))
      c = c and ToCelsius(c, Select(tParams, "SCALE") ~= "" and Select(tParams, "SCALE") or scale())
    end
    local which = strCommand == "SET_SETPOINT_COOL" and "cool" or "heat"
    if strCommand == "SET_SETPOINT_SINGLE" and state.mode == "Cool" then
      which = "cool"
    end
    setSetpoint(which, c)
  elseif strCommand:match("^INC_SETPOINT_") or strCommand:match("^DEC_SETPOINT_") then
    local which = strCommand:match("COOL$") and "cool" or "heat"
    stepSetpoint(which, strCommand:match("^INC") and 1 or -1)
  elseif strCommand == "SET_MODE_HVAC" then
    setMode(Select(tParams, "MODE"))
  elseif strCommand == "SET_MODE_OFF" then
    setMode("Off")
  elseif strCommand == "SET_MODE_HEAT" then
    setMode("Heat")
  elseif strCommand == "SET_MODE_COOL" then
    setMode("Cool")
  elseif strCommand == "SET_MODE_AUTO" then
    setMode("Auto")
  elseif strCommand == "SET_SCALE" then
    local s = tostring(Select(tParams, "SCALE") or ""):upper():sub(1, 1)
    if s == "C" or s == "F" then
      state.scale = s
      saveState()
      notify("SCALE_CHANGED", { SCALE = s })
      reportState(true)
    end
  elseif strCommand == "SET_PRESETS" or strCommand == "SET_EVENTS" then
    presetsFromParams(tParams)
  elseif strCommand == "SET_PRESET" or strCommand == "SET_EVENT" then
    log:info("%s %s", strCommand, tParams)
    local fields = presetsFromParams(tParams)
    local name = Select(tParams, "NAME")
    if IsEmpty(name) then
      name = Select(tParams, "PRESET")
    end
    if IsEmpty(name) then
      name = nil
    end
    if next(fields) == nil and name ~= nil then
      fields = presets[name] or {}
    end
    applyPresetFields(name, fields)
  else
    log:debug("Unhandled thermostat command: %s", strCommand)
  end
end

--- The temperature sensor.
RFP[SENSOR_BINDING] = function(idBinding, strCommand, tParams, _args)
  tParams = tParams or {}
  if strCommand == "VALUE_CHANGED" or strCommand == "VALUE_INITIALIZED" or strCommand == "VALUE_INITIALIZE" then
    local c = CelsiusFromParams(tParams, "C")
    if c ~= nil then
      local first = sensor.celsius == nil
      sensor.celsius, sensor.at, sensor.available = c, now(), true
      if first then
        log:info("Temperature sensor: %s °C", Ui.num(c, 1))
      end
      reportState(false)
      tick(false)
    elseif strCommand ~= "VALUE_CHANGED" and tostring(Select(tParams, "STATUS")):lower() == "offline" then
      sensor.available = false
      tick(false)
    end
  elseif strCommand == "VALUE_UNAVAILABLE" then
    log:warn("Temperature sensor unavailable (%s)", Select(tParams, "STATUS") or "")
    sensor.available = false
    reportState(false)
    tick(false)
  end
end

OBC[SENSOR_BINDING] = function(idBinding, strClass, bIsBound)
  if bIsBound then
    SendToProxy(SENSOR_BINDING, "GET_SENSOR_VALUE", {})
  else
    sensor.available = false
    tick(false)
  end
end

for _, binding in ipairs({ HEAT_VALVE_BINDING, COOL_VALVE_BINDING }) do
  RFP[binding] = function(idBinding, strCommand)
    local cmd = tostring(strCommand or ""):upper()
    if cmd == "CLOSED" or cmd == "STATE_CLOSED" then
      relayFeedback[binding] = "Closed"
    elseif cmd == "OPENED" or cmd == "STATE_OPENED" then
      relayFeedback[binding] = "Opened"
    end
    UpdateProperty(binding == HEAT_VALVE_BINDING and "Heat Valve" or "Cool Valve", valveText(binding))
  end
  OBC[binding] = function(idBinding, strClass, bIsBound)
    relayFeedback[binding] = nil
    if bIsBound then
      setRelay(binding, relayOpen(binding), true)
    end
    UpdateProperty(binding == HEAT_VALVE_BINDING and "Heat Valve" or "Cool Valve", valveText(binding))
  end
end

-------------------------------------------------------------------------------
-- Controller callbacks
-------------------------------------------------------------------------------

local SIDE_WORD = { heat = "heating", cool = "cooling" }

local function onGainsChanged(side, g, source)
  log:info(
    "%s gains (%s): Kp %s %%/°C, Ti %s min",
    SIDE_WORD[side],
    tostring(source),
    Ui.num(g.kp, 2),
    Ui.num(g.ti / 60, 1)
  )
  if gInitialized then
    showGains()
  end
  saveController()
  persist:flush(CONTROLLER_KEY)
end

local function onControllerEvent(name, side, detail)
  local word = SIDE_WORD[side] or ""
  if name == "full_started" then
    log:info("Full %s: %s °C from the setpoint", word, Ui.num(detail or 0, 1))
    fireEvent("Full Power Started")
  elseif name == "full_ended" then
    log:info("PI control (%s)", word)
    fireEvent("Full Power Ended")
  elseif name == "autotune_finished" then
    UpdateProperty(
      "Last Learning",
      string.format(
        "Auto-tune %s %s: Kp %s, Ti %s min",
        word,
        os.date("%Y-%m-%d %H:%M"),
        Ui.num(detail.kp, 1),
        Ui.num(detail.ti / 60, 1)
      )
    )
    fireEvent("Auto-Tune Finished")
  elseif name == "autotune_failed" then
    log:warn("Auto-tune %s stopped: %s", word, tostring(detail))
    UpdateProperty("Last Learning", string.format("Auto-tune %s stopped: %s", word, tostring(detail)))
    fireEvent("Auto-Tune Failed")
  elseif name == "learned" then
    log:info("Learning (%s): %s", word, tostring(detail))
    if detail == "overshoot" or detail == "slow" or detail == "sluggish" then
      local g = controller.gains[side]
      UpdateProperty(
        "Last Learning",
        string.format(
          "%s %s (%s): Kp %s, Ti %s min",
          word:gsub("^%l", string.upper),
          os.date("%Y-%m-%d %H:%M"),
          detail,
          Ui.num(g.kp, 1),
          Ui.num(g.ti / 60, 1)
        )
      )
      fireEvent("Gains Learned")
    end
  end
end

-------------------------------------------------------------------------------
-- Driver lifecycle
-------------------------------------------------------------------------------

function OnDriverInit()
  C4:AllowExecute(true)
  gInitialized = false
  log:setLogName(C4:GetDeviceData(C4:GetDeviceID(), "name"))
  log:setLogLevel(Properties["Log Level"])
  log:setLogMode(Properties["Log Mode"])
  log:trace("OnDriverInit()")
  controller = Controller.new({ onGainsChanged = onGainsChanged, onEvent = onControllerEvent })
  valves = Valves.new()
  persist:setWriteBehind(CONTROLLER_KEY, 60 * ONE_SECOND)
  C4:AddVariable("CONTROLLER_STATE", "", "STRING", true, false)
  C4:AddVariable("CONTROLLER_OUTPUT", "0", "NUMBER", true, false)
  C4:AddVariable("HEAT_VALVE_OPEN", "0", "BOOL", true, false)
  C4:AddVariable("COOL_VALVE_OPEN", "0", "BOOL", true, false)
end

local function sendEverything()
  sent = {}
  lastMessage = { at = 0 }
  sendCapabilities()
  sendExtras()
  reportState(true)
  tick(true)
end

function OnDriverLateInit()
  log:trace("OnDriverLateInit()")
  if not CheckMinimumVersion("Driver Status") then
    return
  end
  UpdateProperty("Driver Status", "Initializing")
  for p, _ in pairs(Properties) do
    local status, err = pcall(OnPropertyChanged, p)
    if not status and err ~= nil then
      log:error(err)
    end
  end

  settings = Ui.normalizeSettings(persist:get(SETTINGS_KEY, nil))
  local saved = persist:get(STATE_KEY, nil)
  saved = type(saved) == "table" and saved or {}
  state = {
    mode = saved.mode or "Off",
    heat = tonumber(saved.heat) or 21,
    cool = tonumber(saved.cool) or 24,
    scale = saved.scale == "F" and "F" or "C",
    preset = saved.preset,
  }
  local savedPresets = persist:get(PRESETS_KEY, nil)
  presets = type(savedPresets) == "table" and savedPresets or {}
  controller:restore(persist:get(CONTROLLER_KEY, nil))
  applyConfig()
  showGains()
  gInitialized = true

  -- Valves closed until the controller has run
  valves:closeAll(now())
  driveRelays(true)

  sendEverything()
  -- The proxy may not be ready this early: tell it again
  SetTimer("ProxyReady", PROXY_READY_DELAY, sendEverything)
  SetTimer("Loop", LOOP_INTERVAL * ONE_SECOND, function()
    tick(false)
  end, true)
  if isBound(SENSOR_BINDING) then
    SendToProxy(SENSOR_BINDING, "GET_SENSOR_VALUE", {})
  end
  UpdateProperty("Driver Status", "Running")
end

function OnDriverDestroyed()
  persist:flush()
end

-------------------------------------------------------------------------------
-- Property change handlers
-------------------------------------------------------------------------------

function OPC.Driver_Version()
  C4:UpdateProperty("Driver Version", C4:GetDriverConfigInfo("version"))
end

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
  local debug = log:getLogLevel() >= 6 and log:isPrintEnabled()
  DEBUGPRINT, DEBUG_TIMER, DEBUG_RFN, DEBUG_URL = debug, debug, debug, debug
end

local function onValveSetupChanged()
  if not gInitialized then
    return
  end
  applyConfig()
  sendCapabilities()
  sendExtras()
  reportState(true)
  tick(true)
end

OPC.Valve_Count = onValveSetupChanged
OPC.Single_Valve_Use = onValveSetupChanged
OPC.Valve_Opens_When_Relay_Is = function()
  if gInitialized then
    driveRelays(true)
  end
end
OPC.Setpoint_Minimum = onValveSetupChanged
OPC.Setpoint_Maximum = onValveSetupChanged
OPC.Heat_Cool_Deadband = onValveSetupChanged

local function onGainProperty(side, kpName, tiName)
  return function()
    if not gInitialized then
      return
    end
    local kp, ti = tonumber(prop(kpName)), tonumber(prop(tiName))
    if kp == nil or ti == nil or kp <= 0 or ti <= 0 then
      log:warn("%s / %s must be positive numbers", kpName, tiName)
      showGains()
      return
    end
    controller:setGains(side, kp, ti * 60, "manual")
    showGains()
    tick(true)
  end
end

OPC.Heating_Kp = onGainProperty("heat", "Heating Kp", "Heating Ti")
OPC.Heating_Ti = OPC.Heating_Kp
OPC.Cooling_Kp = onGainProperty("cool", "Cooling Kp", "Cooling Ti")
OPC.Cooling_Ti = OPC.Cooling_Kp

-------------------------------------------------------------------------------
-- Actions (Execute Command)
-------------------------------------------------------------------------------

function EC.StartAutoTuneHeating()
  startAutotune("heat")
end

function EC.StartAutoTuneCooling()
  startAutotune("cool")
end

function EC.StopAutoTune()
  if controller:stopAutotune("stopped from Composer") then
    tick(true)
  end
end

function EC.ResetLearnedGains()
  resetGains()
end

function EC.RequestTemperature()
  SendToProxy(SENSOR_BINDING, "GET_SENSOR_VALUE", {})
end
