--- @module "mqtt.espsomfy"
--- ESPSomfy-RTS (github.com/rstrouse/ESPSomfy-RTS) discovery over MQTT, and
--- the MQTT Shutter settings that follow from it.
---
--- An ESPSomfy-RTS controller publishes under its Root Topic (empty by
--- default, so topics start at "shades/..."), retained:
---
---   <root>/status                 online / offline (last will)
---   <root>/host, <root>/ipAddress the controller's host name and address
---   <root>/shades                 [1,2,5]   the shade ids
---   <root>/shades/<id>/name       the shade's name
---   <root>/shades/<id>/shadeType  0 roller, 1 blind, 2 left drapery, 3 awning,
---                                 4 shutter, 5/6 garage, 7/8 drapery,
---                                 9/10 dry contact, 11-16 gates
---   <root>/shades/<id>/tiltType   0 none, 1 tilt motor, 2 integrated,
---                                 3 tilt only, 4 euromode
---   <root>/shades/<id>/flipPosition  true / false
---   <root>/shades/<id>/position   0-100, target 0-100, direction -1/0/1,
---                                 tiltPosition, tiltTarget
---   <root>/groups, <root>/groups/<id>/name, .../direction
---
--- Commands: <root>/shades/<id>/target/set 0-100 (moves; position/set only
--- tells the controller where the shade is), direction/set -1 (Up), 1 (Down),
--- 0 (My), tiltTarget/set 0-100; groups take direction/set only.
---
--- Positions are ESPSomfy's own: 0 fully up, 100 fully down; Flip Position
--- only mirrors the numbers it reports and takes. Up opens every type but an
--- awning, which opens (extends) going down. Direction is never flipped.
--- My stops a moving shade but sends an idle one to its favorite position,
--- so Stop goes out only while the shade moves.
---
--- Pure Lua: no Control4 calls.

local ESPSomfy = {}

--- Device keys (the broker's "mac" field) start with this.
ESPSomfy.KEY_PREFIX = "espsomfy:"

ESPSomfy.SHADE_ATTRIBUTES = { "name", "shadeType", "tiltType", "flipPosition" }
ESPSomfy.GROUP_ATTRIBUTES = { "name" }

local TYPE_AWNING = 3
local DRY_CONTACTS = { [9] = true, [10] = true }
--- One-button devices: ESPSomfy toggles them whatever the command.
local TOGGLES = { [5] = true, [14] = true, [15] = true, [16] = true }
local TILT_NONE, TILT_ONLY = 0, 3

local TYPE_NAMES = {
  [0] = "Roller Shade",
  [1] = "Blind",
  [2] = "Drapery",
  [3] = "Awning",
  [4] = "Shutter",
  [5] = "Garage Door",
  [6] = "Garage Door",
  [7] = "Drapery",
  [8] = "Drapery",
  [11] = "Gate",
  [12] = "Gate",
  [13] = "Gate",
  [14] = "Gate",
  [15] = "Gate",
  [16] = "Gate",
}

--- Root topics of zero, one or two levels.
local PREFIXES = { "", "+/", "+/+/" }

--- Subscriptions for an external broker: the id lists, each shade's and
--- group's attributes, and the controller's host name and address.
ESPSomfy.EXTERNAL_FILTERS = (function()
  local out = {}
  for _, p in ipairs(PREFIXES) do
    out[#out + 1] = p .. "shades"
    out[#out + 1] = p .. "groups"
    for _, a in ipairs(ESPSomfy.SHADE_ATTRIBUTES) do
      out[#out + 1] = p .. "shades/+/" .. a
    end
    for _, a in ipairs(ESPSomfy.GROUP_ATTRIBUTES) do
      out[#out + 1] = p .. "groups/+/" .. a
    end
    out[#out + 1] = p .. "host"
    out[#out + 1] = p .. "ipAddress"
  end
  return out
end)()

local function trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function isAttribute(list, a)
  for _, v in ipairs(list) do
    if v == a then
      return true
    end
  end
  return false
end

--- Split a topic into root and the part after it, for a tail pattern that
--- must match the whole of that part.
local function split(topicName, pattern)
  local a, b = topicName:match("^" .. pattern .. "$")
  if a ~= nil then
    return "", a, b
  end
  local root, x, y = topicName:match("^(.+)/" .. pattern .. "$")
  if root ~= nil then
    return root, x, y
  end
  return nil
end

--- What an ESPSomfy topic is, or nil.
--- @param topicName string
--- @return table|nil { root, kind = "shade"|"group"|"shades"|"groups"|"host"|"ipAddress", id?, attr? }
function ESPSomfy.parseTopic(topicName)
  topicName = trim(topicName)
  if topicName == "" then
    return nil
  end
  for _, kind in ipairs({ "shade", "group" }) do
    local root, id, attr = split(topicName, kind .. "s/(%d+)/(%w+)")
    if root ~= nil then
      local attrs = kind == "shade" and ESPSomfy.SHADE_ATTRIBUTES or ESPSomfy.GROUP_ATTRIBUTES
      if isAttribute(attrs, attr) then
        return { root = root, kind = kind, id = tostring(tonumber(id)), attr = attr }
      end
      return nil
    end
  end
  for _, kind in ipairs({ "shades", "groups", "host", "ipAddress" }) do
    if topicName == kind then
      return { root = "", kind = kind }
    end
    local root = topicName:match("^(.+)/" .. kind .. "$")
    if root ~= nil then
      return { root = root, kind = kind }
    end
  end
  return nil
end

--- The id list in a shades or groups message ("[1,2,5]"), or nil.
function ESPSomfy.parseIds(payload)
  local s = trim(payload)
  if not s:match("^%[[%d,%s]*%]$") then
    return nil
  end
  local ids = {}
  for id in s:gmatch("%d+") do
    ids[#ids + 1] = tostring(tonumber(id))
  end
  return ids
end

function ESPSomfy.key(root)
  return ESPSomfy.KEY_PREFIX .. root
end

--- A new, empty controller.
function ESPSomfy.newDevice(root)
  return {
    type = "espsomfy",
    mac = ESPSomfy.key(root),
    root = root,
    topic = root ~= "" and root or "(no root topic)",
    name = "ESPSomfy-RTS",
    shades = {},
    groups = {},
  }
end

--- Apply one discovery message to a controller.
--- @param dev table from newDevice
--- @param info table from parseTopic
--- @param payload string
--- @return boolean changed
function ESPSomfy.update(dev, info, payload)
  local value = trim(payload)
  if info.kind == "host" or info.kind == "ipAddress" then
    local field = info.kind == "host" and "name" or "ip"
    if value == "" or dev[field] == value then
      return false
    end
    dev[field] = value
    return true
  end
  if info.kind == "shades" or info.kind == "groups" then
    local ids = ESPSomfy.parseIds(value)
    if ids == nil then
      return false
    end
    local set = {}
    for _, id in ipairs(ids) do
      set[id] = true
    end
    local changed = false
    for id in pairs(dev[info.kind]) do
      if not set[id] then
        dev[info.kind][id] = nil
        changed = true
      end
    end
    return changed
  end
  local list = info.kind == "shade" and dev.shades or dev.groups
  local entry = list[info.id]
  if value == "" then
    -- A shade or group removed on the controller: its topics are cleared.
    if entry ~= nil and info.attr == "name" then
      list[info.id] = nil
      return true
    end
    return false
  end
  if entry == nil then
    entry = { id = tonumber(info.id) }
    list[info.id] = entry
  end
  local new
  if info.attr == "name" then
    new = value
  elseif info.attr == "flipPosition" then
    new = value == "true" or value == "1"
  else
    new = tonumber(value)
    if new == nil then
      return false
    end
  end
  if entry[info.attr] == new then
    return false
  end
  entry[info.attr] = new
  return true
end

--- Whether a shade can be a Control4 blind (dry contacts are switches).
local function isCover(s)
  return s.shadeType ~= nil and not DRY_CONTACTS[s.shadeType]
end

local function sortedIds(list)
  local ids = {}
  for id in pairs(list or {}) do
    ids[#ids + 1] = id
  end
  table.sort(ids, function(a, b)
    return (tonumber(a) or 0) < (tonumber(b) or 0)
  end)
  return ids
end

--- Shades and groups, in the shape of Tasmota.shutters: { id, label, tilt, name }.
--- Ids are "shade:<n>" and "group:<n>".
function ESPSomfy.shutters(dev)
  local out = {}
  local hasShade = false
  for _, id in ipairs(sortedIds(dev.shades)) do
    local s = dev.shades[id]
    if isCover(s) then
      out[#out + 1] = {
        id = "shade:" .. id,
        label = s.name or ("Shade " .. id),
        name = s.name,
        tilt = s.tiltType ~= nil and s.tiltType ~= TILT_NONE,
        tiltOnly = s.tiltType == TILT_ONLY,
      }
      hasShade = true
    end
  end
  -- Groups only with a shade: a "groups/<n>/name" topic alone could be anything.
  for _, id in ipairs(hasShade and sortedIds(dev.groups) or {}) do
    local g = dev.groups[id]
    if g.name ~= nil then
      out[#out + 1] = { id = "group:" .. id, label = g.name .. " (group)", name = g.name, tilt = false, group = true }
    end
  end
  return out
end

--- Compact entry for lists sent to child drivers.
function ESPSomfy.summary(dev)
  return {
    type = "espsomfy",
    mac = dev.mac,
    topic = dev.topic,
    name = dev.name,
    ip = dev.ip,
    loads = {},
    buttons = 0,
    shutters = ESPSomfy.shutters(dev),
  }
end

--- The topic for a path under the controller's root.
function ESPSomfy.topicFor(dev, path)
  local root = dev.root or ""
  return root ~= "" and (root .. "/" .. path) or path
end

local function find(dev, id)
  local kind, n = tostring(id or ""):match("^(%a+):(%d+)$")
  if kind == "shade" then
    local s = (dev.shades or {})[n]
    if s ~= nil and isCover(s) then
      return s, "shades/" .. n, false
    end
  elseif kind == "group" then
    local g = (dev.groups or {})[n]
    if g ~= nil then
      return g, "groups/" .. n, true
    end
  end
  return nil
end

--- MQTT Shutter property values for one shade or group.
function ESPSomfy.shutterProperties(dev, id)
  local s, base, group = find(dev, id)
  if s == nil then
    return nil, "no such shade or group on " .. tostring(dev.topic)
  end
  local function t(path)
    return ESPSomfy.topicFor(dev, base .. "/" .. path)
  end
  -- Up opens everything but an awning; a group is taken as opening going up.
  local upOpens = group or s.shadeType ~= TYPE_AWNING
  -- Control4's 100 is open. Unflipped, ESPSomfy's 0 is up: invert when up opens.
  local invert = (upOpens and not s.flipPosition) or (not upOpens and s.flipPosition == true)
  local tilt = not group and s.tiltType ~= nil and s.tiltType ~= TILT_NONE
  local positions = not group and s.tiltType ~= TILT_ONLY
  return {
    ["Payload Mode"] = "Separate Topics",
    ["Position State Topic"] = positions and t("position") or "",
    ["Position Value Path"] = "",
    ["Position Command Topic"] = positions and t("target/set") or "",
    ["Target State Topic"] = positions and t("target") or "",
    ["Target Value Path"] = "",
    -- A group's direction is set by its commands and never returns to 0 when
    -- the shades arrive: a group goes by its Travel Time instead.
    ["Movement State Topic"] = group and "" or t("direction"),
    ["Movement Value Path"] = "",
    -- ESPSomfy reports -1 going up: opening, unless it is an awning.
    ["Invert Movement"] = upOpens and "Yes" or "No",
    ["Open Command Topic"] = t("direction/set"),
    ["Open Payload"] = upOpens and "-1" or "1",
    ["Close Command Topic"] = t("direction/set"),
    ["Close Payload"] = upOpens and "1" or "-1",
    ["Stop Command Topic"] = t("direction/set"),
    ["Stop Payload"] = "0",
    ["Stop Only While Moving"] = "Yes",
    ["Tilt State Topic"] = tilt and t("tiltPosition") or "",
    ["Tilt Value Path"] = "",
    ["Tilt Command Topic"] = tilt and t("tiltTarget/set") or "",
    ["Tilt Min"] = "0",
    ["Tilt Max"] = "100",
    ["Invert Position"] = invert and "Yes" or "No",
    ["State Request Topic"] = "",
    ["State Request Payload"] = "",
    ["Availability Topic"] = ESPSomfy.topicFor(dev, "status"),
    ["Availability Value Path"] = "",
    ["Payload Available"] = "online",
    ["Payload Not Available"] = "offline",
  }
end

--- A Control4 name for a shade or group: its ESPSomfy name.
function ESPSomfy.shutterName(dev, id)
  local s = find(dev, id)
  if s == nil then
    return nil
  end
  return s.name
end

--- What to tell the installer about a shade or group, for the driver's
--- Device Notes. control: the shutter's Control (Position or Tilt).
function ESPSomfy.notes(dev, id, control)
  local s, _, group = find(dev, id)
  local notes = {}
  if s == nil then
    return notes
  end
  local tiltControl = control == "Tilt"
  if group then
    notes[#notes + 1] = "ESPSomfy groups only take Up, Down and My and do not report when they arrive: "
      .. "the shutter opens and closes, without positions, and counts a move as done after its Travel Time."
    if tiltControl then
      notes[#notes + 1] = "Groups have no tilt; set Control to Position."
    end
    return notes
  end
  if s.tiltType == TILT_ONLY and not tiltControl then
    notes[#notes + 1] = "This shade only tilts; set Control to Tilt."
  elseif tiltControl and (s.tiltType == nil or s.tiltType == TILT_NONE) then
    notes[#notes + 1] = "This shade has no tilt in ESPSomfy; set Control to Position."
  end
  if tiltControl and s.flipPosition then
    notes[#notes + 1] =
      "ESPSomfy flips reported tilt with Flip Position but not tilt commands; turn Flip Position off for this shade."
  end
  if TOGGLES[s.shadeType] then
    notes[#notes + 1] = "A one-button device: ESPSomfy toggles it, so Open, Close and Stop each start or stop it."
  end
  return notes
end

--- A one-line description of a shade, for the broker's Print action.
function ESPSomfy.describe(s)
  local parts = { TYPE_NAMES[s.shadeType] or ("type " .. tostring(s.shadeType)) }
  if s.tiltType ~= nil and s.tiltType ~= TILT_NONE then
    parts[#parts + 1] = s.tiltType == TILT_ONLY and "tilt only" or "tilt"
  end
  if s.flipPosition then
    parts[#parts + 1] = "flipped"
  end
  return table.concat(parts, ", ")
end

--- Number of shades (covers) and groups on a controller.
function ESPSomfy.counts(dev)
  local shades, groups = 0, 0
  for _, s in ipairs(ESPSomfy.shutters(dev)) do
    if s.group then
      groups = groups + 1
    else
      shades = shades + 1
    end
  end
  return shades, groups
end

return ESPSomfy
