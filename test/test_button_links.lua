-- Tests for the MQTT Light's On, Off and Toggle button links
-- (src/mqtt/button_links.lua): colors from the properties, and what keypads
-- are told on each link.
--
-- Run from the repo root:
--   make test
-- or:
--   ./test/run_test.sh test_button_links.lua

local T = require("testlib")
require("c4_shim")
local ButtonLinks = require("mqtt.button_links")

T.section("Colors")
T.eq("COLOR_SELECTOR r,g,b", ButtonLinks.color("0,0,255"), "0000ff")
T.eq("with spaces", ButtonLinks.color(" 255, 128 ,0 "), "ff8000")
T.eq("hex", ButtonLinks.color("FF00AA"), "ff00aa")
T.eq("hex with #", ButtonLinks.color("#00ff00"), "00ff00")
T.eq("out of range", ButtonLinks.color("256,0,0"), nil)
T.eq("not a color", ButtonLinks.color("blue"), nil)
T.eq("empty", ButtonLinks.color(""), nil)

T.section("Links")
T.eq("bindings 200-202", { ButtonLinks.LINKS[1].binding, ButtonLinks.LINKS[2].binding, ButtonLinks.LINKS[3].binding }, {
  200,
  201,
  202,
})
T.eq("light_v2 button IDs 0 top, 1 bottom, 2 toggle", {
  ButtonLinks.byBinding(200).button,
  ButtonLinks.byBinding(201).button,
  ButtonLinks.byBinding(202).button,
}, { 0, 1, 2 })
T.eq("no link on another binding", ButtonLinks.byBinding(5001), nil)
T.eq("property names", { ButtonLinks.propertyNames(ButtonLinks.LINKS[1]) }, {
  "On Button LED When Light On",
  "On Button LED When Light Off",
})
T.eq("keypad commands", { ButtonLinks.ACTIONS.DO_PUSH, ButtonLinks.ACTIONS.DO_CLICK, ButtonLinks.ACTIONS.DO_RELEASE }, {
  1,
  2,
  0,
})

T.section("LED state and colors")
local on, off, toggle = ButtonLinks.LINKS[1], ButtonLinks.LINKS[2], ButtonLinks.LINKS[3]
local m = ButtonLinks.ledMessages(on, true, "00ff00", "ff0000")
T.eq(
  "On link, light on: lit in its on color",
  { m.state, m.colors.CURRENT_COLOR, m.colors.ON_COLOR, m.colors.OFF_COLOR },
  {
    "1",
    "00ff00",
    "00ff00",
    "ff0000",
  }
)
m = ButtonLinks.ledMessages(on, false, "00ff00", "ff0000")
T.eq("On link, light off: unlit in its off color", { m.state, m.colors.CURRENT_COLOR }, { "0", "ff0000" })
m = ButtonLinks.ledMessages(off, false, "00ff00", "ff0000")
T.eq("Off link, light off: lit, colors swap for the keypad", {
  m.state,
  m.colors.CURRENT_COLOR,
  m.colors.ON_COLOR,
  m.colors.OFF_COLOR,
}, { "1", "ff0000", "ff0000", "00ff00" })
m = ButtonLinks.ledMessages(off, true, "00ff00", "ff0000")
T.eq("Off link, light on: unlit", { m.state, m.colors.CURRENT_COLOR }, { "0", "00ff00" })
m = ButtonLinks.ledMessages(toggle, true)
T.eq(
  "Toggle link defaults: blue while on",
  { m.state, m.colors.CURRENT_COLOR, m.colors.BUTTON_ID },
  { "1", "0000ff", "2" }
)
m = ButtonLinks.ledMessages(off, false)
T.eq("Off link defaults: blue while off", m.colors.CURRENT_COLOR, "0000ff")
for _, link in ipairs(ButtonLinks.LINKS) do
  local fields = ButtonLinks.ledMessages(link, true).colors
  T.check(
    link.name .. ": all four BUTTON_COLORS fields",
    fields.BUTTON_ID and fields.ON_COLOR and fields.OFF_COLOR and fields.CURRENT_COLOR
  )
end

T.finish()
