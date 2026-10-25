--- @module "mqtt.button_links"
--- The MQTT Light's ON, OFF and Toggle button links and their LED colors, as
--- Control4's own light_v2 drivers do them (control4_light_relay.c4z):
---
---   * Connections 300 + button: 300 ON (top), 301 OFF (bottom), 302 Toggle,
---     class BUTTON_LINK. A bound keypad button sends DO_PUSH, DO_CLICK and
---     DO_RELEASE on the link, and REQUEST_BUTTON_COLORS.
---   * With has_leds the light_v2 proxy shows "Button and Button Connection
---     Status LED Colors" on its Brightness tab. A color chosen there arrives
---     as SET_BUTTON_COLOR { BUTTON_ID, ON_COLOR, OFF_COLOR, CURRENT_COLOR }
---     (or SET_ALL_LED { COLOR }) on the proxy binding. The driver keeps it,
---     answers BUTTON_INFO to the proxy, and sends BUTTON_COLORS
---     { ON_COLOR, OFF_COLOR } on the bound link.
---   * MATCH_LED_STATE { STATE } on each bound link tells keypads whether the
---     light is on: they show ON_COLOR while it is, OFF_COLOR while not.
---
--- Pure Lua: no Control4 calls.

local ButtonLinks = {}

ButtonLinks.BINDING_BASE = 300
ButtonLinks.CLASS = "BUTTON_LINK"
ButtonLinks.COUNT = 3

ButtonLinks.LINKS = {
  { binding = 300, button = 0, name = "ON" },
  { binding = 301, button = 1, name = "OFF" },
  { binding = 302, button = 2, name = "Toggle" },
}

--- light_v2 BUTTON_ACTION actions for each keypad command.
ButtonLinks.ACTIONS = { DO_PUSH = 1, DO_CLICK = 2, DO_RELEASE = 0 }

--- Colors before any are chosen in Composer: ON and Toggle blue while the light
--- is on, OFF blue while it is off.
ButtonLinks.DEFAULT_COLORS = {
  [0] = { onColor = "0000ff", offColor = "000000" },
  [1] = { onColor = "000000", offColor = "0000ff" },
  [2] = { onColor = "0000ff", offColor = "000000" },
}

--- The link on a binding, or nil.
function ButtonLinks.byBinding(bindingId)
  local button = (tonumber(bindingId) or -1) - ButtonLinks.BINDING_BASE
  return ButtonLinks.LINKS[button + 1]
end

--- A valid button ID (0-2), or nil.
function ButtonLinks.buttonId(value)
  local n = tonumber(value)
  if n and n >= 0 and n < ButtonLinks.COUNT and n == math.floor(n) then
    return n
  end
  return nil
end

--- A Control4 color ("rrggbb", also accepting "#rrggbb"), lowercase; nil when unreadable.
function ButtonLinks.color(value)
  local s = tostring(value or ""):match("^%s*#?(%x%x%x%x%x%x)%s*$")
  return s and s:lower() or nil
end

--- Colors for every button, from what was saved (missing ones get the defaults).
--- @param saved table|nil { [buttonId] = { onColor, offColor } }, keys may be strings after persisting
--- @return table colors
function ButtonLinks.load(saved)
  local colors = {}
  for id = 0, ButtonLinks.COUNT - 1 do
    local s = type(saved) == "table" and (saved[id] or saved[tostring(id)]) or nil
    local d = ButtonLinks.DEFAULT_COLORS[id]
    colors[id] = {
      onColor = ButtonLinks.color(s and s.onColor) or d.onColor,
      offColor = ButtonLinks.color(s and s.offColor) or d.offColor,
    }
  end
  return colors
end

--- Apply SET_BUTTON_COLOR (or SET_ALL_LED) parameters.
--- @param colors table from load()
--- @param buttonId number
--- @param onColor any
--- @param offColor any
--- @return boolean changed
function ButtonLinks.set(colors, buttonId, onColor, offColor)
  local c = colors[buttonId]
  if c == nil then
    return false
  end
  local on, off = ButtonLinks.color(onColor), ButtonLinks.color(offColor)
  local changed = false
  if on and on ~= c.onColor then
    c.onColor, changed = on, true
  end
  if off and off ~= c.offColor then
    c.offColor, changed = off, true
  end
  return changed
end

--- The color a button's LED shows now.
function ButtonLinks.current(colors, buttonId, lightOn)
  local c = colors[buttonId]
  return c and (lightOn and c.onColor or c.offColor) or nil
end

return ButtonLinks
