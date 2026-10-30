--- @module "pi_thermostat.ui"
--- What the PI Thermostat shows in Control4: the user settings in Extras,
--- the controller status in the proxy Message, and the preset fields for
--- preset scheduling. Pure text in, text out; the driver sends it.

local Ui = {}

local function xmlEscape(s)
  return (
    tostring(s or ""):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"):gsub("'", "&apos;")
  )
end
Ui.xmlEscape = xmlEscape

local function xmlUnescape(s)
  return (
    tostring(s or ""):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&apos;", "'"):gsub("&amp;", "&")
  )
end

--- A number as text without float noise ("0.5", "5", "0.75").
function Ui.num(v, decimals)
  local s = string.format("%." .. (decimals or 2) .. "f", tonumber(v) or 0):gsub("0+$", ""):gsub("%.$", "")
  if s == "-0" then
    return "0"
  end
  return s
end

local function numbers(list, suffix)
  local items = {}
  for _, v in ipairs(list) do
    items[#items + 1] = { text = Ui.num(v) .. suffix, value = Ui.num(v) }
  end
  return items
end

local function range(from, to, step)
  local list, v = {}, from
  while v <= to + 1e-9 do
    list[#list + 1] = v
    v = v + step
  end
  return list
end

-------------------------------------------------------------------------------
-- Extras (user settings)
-------------------------------------------------------------------------------

--- The user settings. Numbers are stored as numbers; minutes are minutes.
Ui.SETTINGS = {
  {
    id = "response",
    section = "Controller",
    label = "Response",
    kind = "list",
    default = "Normal",
    items = {
      { text = "Slow", value = "Slow" },
      { text = "Normal", value = "Normal" },
      { text = "Fast", value = "Fast" },
    },
  },
  { id = "learning", section = "Controller", label = "Self-Learning", kind = "checkbox", default = true },
  {
    id = "full_threshold",
    section = "Full Power",
    label = "Full Power Above (°C from Setpoint)",
    kind = "list",
    number = true,
    default = 5,
    items = numbers(range(2, 10, 0.5), " °C"),
  },
  {
    id = "full_release",
    section = "Full Power",
    label = "Back to PI Control (°C Below That)",
    kind = "list",
    number = true,
    default = 0.5,
    items = numbers({ 0.2, 0.3, 0.5, 0.75, 1, 1.5, 2 }, " °C"),
  },
  {
    id = "cycle_time",
    section = "Valves",
    label = "Valve Cycle Time",
    kind = "list",
    number = true,
    default = 10,
    items = numbers({ 3, 5, 10, 15, 20, 30 }, " min"),
  },
  {
    id = "min_valve_time",
    section = "Valves",
    label = "Minimum Valve Open/Closed Time",
    kind = "list",
    number = true,
    default = 2,
    items = numbers({ 0, 1, 2, 3, 5 }, " min"),
  },
  {
    id = "sensor_timeout",
    section = "Sensor",
    label = "Close Valves If No Reading For",
    kind = "list",
    number = true,
    default = 15,
    items = numbers({ 5, 10, 15, 20, 30, 60 }, " min"),
  },
}

--- Buttons: id -> label, shown in the "Learning" section.
Ui.BUTTONS = {
  { id = "tune_heat", label = "Auto-Tune Heating", text = "Start", side = "heat" },
  { id = "tune_cool", label = "Auto-Tune Cooling", text = "Start", side = "cool" },
  { id = "tune_stop", label = "Stop Auto-Tune", text = "Stop" },
  { id = "reset_gains", label = "Reset Learned Gains", text = "Reset" },
}

--- The command an Extras object sends: PI_<ID>.
function Ui.command(id)
  return "PI_" .. id:upper()
end

local BY_COMMAND = {}
for _, s in ipairs(Ui.SETTINGS) do
  BY_COMMAND[Ui.command(s.id)] = s
end
for _, b in ipairs(Ui.BUTTONS) do
  BY_COMMAND[Ui.command(b.id)] = b
end

--- Settings with every missing or invalid value at its default.
function Ui.normalizeSettings(saved)
  local out = {}
  saved = type(saved) == "table" and saved or {}
  for _, s in ipairs(Ui.SETTINGS) do
    local v = saved[s.id]
    local ok = false
    if s.kind == "checkbox" then
      ok = type(v) == "boolean"
    elseif s.number then
      v = tonumber(v)
      if v ~= nil then
        for _, item in ipairs(s.items) do
          ok = ok or math.abs(tonumber(item.value) - v) < 1e-6
        end
      end
    else
      for _, item in ipairs(s.items) do
        ok = ok or item.value == v
      end
    end
    out[s.id] = ok and v or s.default
  end
  return out
end

local function truthy(v)
  local s = tostring(v or ""):lower()
  return s == "true" or s == "1" or s == "on" or s == "yes" or s == "checked"
end

--- The value an Extras command carries. The proxy sends it as "value";
--- other spellings are accepted too.
function Ui.commandValue(params)
  if type(params) ~= "table" then
    return nil
  end
  for _, k in ipairs({ "value", "VALUE", "Value", "STATE", "state" }) do
    if params[k] ~= nil then
      return params[k]
    end
  end
  local only, count = nil, 0
  for _, v in pairs(params) do
    only, count = v, count + 1
  end
  return count == 1 and only or nil
end

--- Handle an Extras command.
--- @return table|nil action { setting = id, value = v } or { button = id }; nil when not ours
function Ui.parseCommand(command, params)
  local def = BY_COMMAND[tostring(command or "")]
  if def == nil then
    return nil
  end
  if def.kind == nil then
    return { button = def.id }
  end
  local raw = Ui.commandValue(params)
  if def.kind == "checkbox" then
    return { setting = def.id, value = truthy(raw) }
  end
  if raw == nil then
    return { setting = def.id, invalid = true }
  end
  local norm = Ui.normalizeSettings({ [def.id] = def.number and tonumber(raw) or tostring(raw) })[def.id]
  local valid = def.number and tonumber(raw) ~= nil and math.abs(norm - tonumber(raw)) < 1e-6 or norm == raw
  if not valid then
    return { setting = def.id, invalid = true }
  end
  return { setting = def.id, value = norm }
end

local function valueText(def, v)
  if def.kind == "checkbox" then
    return v and "True" or "False"
  elseif def.number then
    return Ui.num(v)
  end
  return tostring(v)
end

--- The Extras setup XML.
--- @param settings table normalized settings
--- @param sides table { heat = bool, cool = bool } for the tune buttons
function Ui.extrasSetup(settings, sides)
  local sections, order = {}, {}
  local function section(name)
    if sections[name] == nil then
      sections[name] = {}
      order[#order + 1] = name
    end
    return sections[name]
  end
  for _, def in ipairs(Ui.SETTINGS) do
    local lines = section(def.section)
    local value = xmlEscape(valueText(def, settings[def.id]))
    local attrs = string.format(
      'type="%s" id="%s" label="%s" command="%s" value="%s"',
      def.kind,
      def.id,
      xmlEscape(def.label),
      Ui.command(def.id),
      value
    )
    if def.kind == "checkbox" then
      lines[#lines + 1] = "<object " .. attrs .. "/>"
    else
      local items = {}
      for _, item in ipairs(def.items) do
        items[#items + 1] = string.format('<item text="%s" value="%s"/>', xmlEscape(item.text), xmlEscape(item.value))
      end
      lines[#lines + 1] = "<object "
        .. attrs
        .. '><list maxselections="1" minselections="1">'
        .. table.concat(items)
        .. "</list></object>"
    end
  end
  local learning = section("Learning")
  for _, b in ipairs(Ui.BUTTONS) do
    if b.side == nil or (sides or {})[b.side] then
      learning[#learning + 1] = string.format(
        '<object type="button" id="%s" label="%s" command="%s"><buttontext>%s</buttontext></object>',
        b.id,
        xmlEscape(b.label),
        Ui.command(b.id),
        xmlEscape(b.text)
      )
    end
  end
  local out = { "<extras_setup><extra>" }
  for _, name in ipairs(order) do
    out[#out + 1] = string.format('<section label="%s">', xmlEscape(name))
    out[#out + 1] = table.concat(sections[name])
    out[#out + 1] = "</section>"
  end
  out[#out + 1] = "</extra></extras_setup>"
  return table.concat(out)
end

--- The Extras state XML: the current value of every setting.
function Ui.extrasState(settings)
  local objects = {}
  for _, def in ipairs(Ui.SETTINGS) do
    objects[#objects + 1] =
      string.format('<object id="%s" value="%s"/>', def.id, xmlEscape(valueText(def, settings[def.id])))
  end
  return "<extras_state><extra>" .. table.concat(objects) .. "</extra></extras_state>"
end

-------------------------------------------------------------------------------
-- Preset scheduling
-------------------------------------------------------------------------------

--- The preset fields template: HVAC mode and the setpoints.
--- @param modes string[] the allowed HVAC modes
--- @param limits table { min, max } in °C, { minF, maxF } in °F
function Ui.presetFields(modes, limits)
  local items = {}
  for _, m in ipairs(modes) do
    items[#items + 1] = string.format('<item text="%s" value="%s"/>', m, m)
  end
  local function setpoint(id, label, min, max, res)
    return string.format(
      '<field id="%s" type="number" label="%s" min="%s" max="%s" res="%s"/>',
      id,
      label,
      Ui.num(min),
      Ui.num(max),
      Ui.num(res)
    )
  end
  local hasHeat, hasCool = false, false
  for _, m in ipairs(modes) do
    hasHeat = hasHeat or m == "Heat" or m == "Auto"
    hasCool = hasCool or m == "Cool" or m == "Auto"
  end
  local out = {
    "<preset_fields>",
    '<field id="hvac_mode" type="list" label="HVAC Mode"><list>' .. table.concat(items) .. "</list></field>",
  }
  if hasHeat then
    out[#out + 1] = setpoint("heat_setpoint_c", "Heat Setpoint", limits.min, limits.max, 0.5)
    out[#out + 1] = setpoint("heat_setpoint_f", "Heat Setpoint", limits.minF, limits.maxF, 1)
  end
  if hasCool then
    out[#out + 1] = setpoint("cool_setpoint_c", "Cool Setpoint", limits.min, limits.max, 0.5)
    out[#out + 1] = setpoint("cool_setpoint_f", "Cool Setpoint", limits.minF, limits.maxF, 1)
  end
  out[#out + 1] = "</preset_fields>"
  return table.concat(out)
end

--- Read <field id="..." value="..."/> pairs from preset XML.
--- @return table fields id -> value
function Ui.parseFields(xml)
  local fields = {}
  for tag in tostring(xml or ""):gmatch("<field%s[^>]*>") do
    local id = tag:match('id%s*=%s*"([^"]*)"') or tag:match("id%s*=%s*'([^']*)'")
    local value = tag:match('value%s*=%s*"([^"]*)"') or tag:match("value%s*=%s*'([^']*)'")
    if id and value then
      fields[xmlUnescape(id)] = xmlUnescape(value)
    end
  end
  return fields
end

--- Read presets from the XML the proxy sends with SET_PRESETS.
--- @return table name -> fields
function Ui.parsePresets(xml)
  local presets = {}
  for attrs, body in tostring(xml or ""):gmatch("<preset(%s[^>]-)>(.-)</preset>") do
    local name = attrs:match('name%s*=%s*"([^"]*)"') or attrs:match("name%s*=%s*'([^']*)'")
    if name then
      presets[xmlUnescape(name)] = Ui.parseFields(body)
    end
  end
  return presets
end

--- Turn preset fields into thermostat changes: { mode, heat, cool } (°C).
function Ui.presetChanges(fields)
  local function temp(prefix)
    local c = tonumber(fields[prefix .. "_c"])
    if c then
      return c
    end
    local f = tonumber(fields[prefix .. "_f"])
    if f then
      return (f - 32) * 5 / 9
    end
    return nil
  end
  local changes = {}
  local mode = fields.hvac_mode
  if mode ~= nil and mode ~= "" then
    changes.mode = mode
  end
  changes.heat = temp("heat_setpoint")
  changes.cool = temp("cool_setpoint")
  -- doublenumber auto setpoints: "heat,cool"
  local auto = fields.auto_setpoints_c or fields.auto_setpoints_f
  if auto then
    local h, c = tostring(auto):match("^%s*([%d%.%-]+)%s*[,;]%s*([%d%.%-]+)")
    h, c = tonumber(h), tonumber(c)
    if h and c then
      if fields.auto_setpoints_c == nil then
        h, c = (h - 32) * 5 / 9, (c - 32) * 5 / 9
      end
      changes.heat = changes.heat or h
      changes.cool = changes.cool or c
    end
  end
  return changes
end

-------------------------------------------------------------------------------
-- Message (controller status for the proxy)
-------------------------------------------------------------------------------

local SIDE_WORD = { heat = "heating", cool = "cooling" }

local function delta(c, scale)
  if scale == "F" then
    return Ui.num(c * 9 / 5, 1) .. " °F"
  end
  return Ui.num(c, 1) .. " °C"
end

local function minutes(s)
  return Ui.num((tonumber(s) or 0) / 60, 1) .. " min"
end

local SOURCE_TEXT = { default = "default", tuned = "auto-tuned", learned = "learned", manual = "entered" }

--- The message lines (Control4 shows up to four).
--- @param r table controller result
--- @param ctx table { scale, valves = {heat=bool,cool=bool}, valveCount, singleValveUse, gains = {heat=..., cool=...}, mode }
function Ui.message(r, ctx)
  ctx = ctx or {}
  local scale = ctx.scale == "F" and "F" or "C"
  local lines = {}
  local word = SIDE_WORD[r.side or ""] or ""
  if r.state == "off" then
    lines[1] = "Off: valves closed"
  elseif r.state == "sensor" then
    lines[1] = "No temperature reading: valves closed"
  elseif r.state == "autotune" then
    local p = r.tune or {}
    lines[1] = string.format(
      "Auto-tune %s: cycle %s of %s, valve %s",
      word,
      tostring(p.cycle or 1),
      tostring(p.cycles or 2),
      p.open and "open" or "closed"
    )
  elseif r.state == "full" then
    local where = r.side == "heat" and "below" or "above"
    lines[1] = string.format("Full %s: %s %s setpoint", word, delta(r.error or 0, scale), where)
  elseif r.state == "pi" then
    lines[1] = string.format("PI %s: %s %%", word, Ui.num(r.output or 0, 0))
  elseif ctx.mode == "Auto" and r.side == nil then
    lines[1] = "Idle: between the setpoints"
  else
    lines[1] = "Idle: at setpoint"
  end

  local side = r.side
  if side == nil and ctx.mode == "Heat" then
    side = "heat"
  elseif side == nil and ctx.mode == "Cool" then
    side = "cool"
  end
  local g = side and (ctx.gains or {})[side]
  if g then
    local learned = (g.learned or 0) > 0 and string.format(", %d adjustments", g.learned) or ""
    lines[#lines + 1] = string.format(
      "Kp %s %%/°C, Ti %s (%s%s)",
      Ui.num(r.kp or g.kp, 1),
      minutes(r.ti or g.ti),
      SOURCE_TEXT[g.source] or tostring(g.source),
      learned
    )
  end

  if r.state == "pi" and r.p ~= nil then
    local sign = (r.error or 0) >= 0 and "" or "-"
    lines[#lines + 1] = string.format(
      "P %s %% + I %s %%, deviation %s%s",
      Ui.num(r.p, 0),
      Ui.num(r.i or 0, 0),
      sign,
      delta(math.abs(r.error or 0), scale)
    )
  end

  local v = ctx.valves or {}
  if ctx.valveCount == 1 then
    lines[#lines + 1] = "Valve " .. ((v.heat or v.cool) and "open" or "closed")
  else
    lines[#lines + 1] =
      string.format("Heat valve %s, cool valve %s", v.heat and "open" or "closed", v.cool and "open" or "closed")
  end
  while #lines > 4 do
    table.remove(lines)
  end
  return table.concat(lines, "\n")
end

return Ui
