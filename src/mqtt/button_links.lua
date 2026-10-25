--- @module "mqtt.button_links"
--- The MQTT Light's On, Off and Toggle button links: BUTTON_LINK connections a
--- keypad button binds to, like a Control4 dimmer's Top, Bottom and Toggle
--- links.
---
--- A bound keypad button sends DO_PUSH, then DO_CLICK (a tap) or DO_RELEASE
--- (the end of a hold). The light answers on the same link with
--- MATCH_LED_STATE (LED lit or not) and BUTTON_COLORS (the LED's colors), so
--- the keypad LED shows the light's state in the colors set in Properties.
---
--- Pure Lua: no Control4 calls.

local ButtonLinks = {}

--- light_v2 button IDs: 0 top (on), 1 bottom (off), 2 toggle.
ButtonLinks.LINKS = {
  { binding = 200, button = 0, name = "On", litWhenOn = true, defaultOn = "0,0,255", defaultOff = "0,0,0" },
  { binding = 201, button = 1, name = "Off", litWhenOn = false, defaultOn = "0,0,0", defaultOff = "0,0,255" },
  { binding = 202, button = 2, name = "Toggle", litWhenOn = true, defaultOn = "0,0,255", defaultOff = "0,0,0" },
}

ButtonLinks.CLASS = "BUTTON_LINK"

--- light_v2 BUTTON_ACTION actions for each keypad command.
ButtonLinks.ACTIONS = { DO_PUSH = 1, DO_CLICK = 2, DO_RELEASE = 0 }

--- The link on a binding, or nil.
function ButtonLinks.byBinding(bindingId)
  bindingId = tonumber(bindingId)
  for _, link in ipairs(ButtonLinks.LINKS) do
    if link.binding == bindingId then
      return link
    end
  end
  return nil
end

--- Property names for a link's LED colors.
--- @return string whenOn, string whenOff
function ButtonLinks.propertyNames(link)
  return link.name .. " Button LED When Light On", link.name .. " Button LED When Light Off"
end

--- A color from a COLOR_SELECTOR property ("r,g,b") or hex ("RRGGBB",
--- "#RRGGBB"), as Control4's lowercase "rrggbb"; nil when unreadable.
--- @param value any
--- @return string|nil
function ButtonLinks.color(value)
  local s = tostring(value or ""):match("^%s*(.-)%s*$")
  local r, g, b = s:match("^(%d+)%s*,%s*(%d+)%s*,%s*(%d+)$")
  if r then
    r, g, b = tonumber(r), tonumber(g), tonumber(b)
    if r > 255 or g > 255 or b > 255 then
      return nil
    end
    return string.format("%02x%02x%02x", r, g, b)
  end
  local hex = s:gsub("^#", ""):gsub("^0[xX]", "")
  if hex:match("^%x%x%x%x%x%x$") then
    return hex:lower()
  end
  return nil
end

--- What to tell keypads on a link.
--- @param link table one of LINKS
--- @param lightOn boolean
--- @param whenOn string|nil color while the light is on ("rrggbb")
--- @param whenOff string|nil color while the light is off
--- @return table led { lit, state, colors = { BUTTON_ID, ON_COLOR, OFF_COLOR, CURRENT_COLOR } }
function ButtonLinks.ledMessages(link, lightOn, whenOn, whenOff)
  whenOn = whenOn or ButtonLinks.color(link.defaultOn)
  whenOff = whenOff or ButtonLinks.color(link.defaultOff)
  local lit = (lightOn == link.litWhenOn)
  -- A keypad's ON_COLOR is its LED lit, OFF_COLOR unlit. The Off link is lit
  -- while the light is off, so its colors swap.
  local litColor, unlitColor = whenOn, whenOff
  if not link.litWhenOn then
    litColor, unlitColor = whenOff, whenOn
  end
  return {
    lit = lit,
    state = lit and "1" or "0",
    colors = {
      BUTTON_ID = tostring(link.button),
      ON_COLOR = litColor,
      OFF_COLOR = unlitColor,
      CURRENT_COLOR = lightOn and whenOn or whenOff,
    },
  }
end

return ButtonLinks
