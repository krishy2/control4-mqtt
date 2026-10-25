-- Tests for the MQTT Light's ON, OFF and Toggle button links
-- (src/mqtt/button_links.lua), which follow Control4's own light_v2 drivers
-- (control4_light_relay.c4z): links 300-302 and LED colors chosen in the
-- proxy's "Button and Button Connection Status LED Colors".
--
-- Run from the repo root:
--   make test
-- or:
--   ./test/run_test.sh test_button_links.lua

local T = require("testlib")
require("c4_shim")
local ButtonLinks = require("mqtt.button_links")

T.section("Links")
T.eq("bindings 300-302 for buttons 0-2", {
  ButtonLinks.byBinding(300).button,
  ButtonLinks.byBinding(301).button,
  ButtonLinks.byBinding(302).button,
}, { 0, 1, 2 })
T.eq("names", { ButtonLinks.LINKS[1].name, ButtonLinks.LINKS[2].name, ButtonLinks.LINKS[3].name }, {
  "ON",
  "OFF",
  "Toggle",
})
T.eq(
  "no link on other bindings",
  { ButtonLinks.byBinding(299), ButtonLinks.byBinding(303), ButtonLinks.byBinding(5001) },
  {}
)
T.eq("keypad commands to light_v2 actions", {
  ButtonLinks.ACTIONS.DO_PUSH,
  ButtonLinks.ACTIONS.DO_CLICK,
  ButtonLinks.ACTIONS.DO_RELEASE,
}, { 1, 2, 0 })
T.eq(
  "button IDs",
  { ButtonLinks.buttonId("0"), ButtonLinks.buttonId(2), ButtonLinks.buttonId(3), ButtonLinks.buttonId("x") },
  {
    0,
    2,
  }
)

T.section("Colors")
T.eq("rrggbb", ButtonLinks.color("00FF00"), "00ff00")
T.eq("#rrggbb", ButtonLinks.color("#0000ff"), "0000ff")
T.eq("not a color", ButtonLinks.color("blue"), nil)
local colors = ButtonLinks.load(nil)
T.eq("defaults: ON blue while on", { colors[0].onColor, colors[0].offColor }, { "0000ff", "000000" })
T.eq("defaults: OFF blue while off", { colors[1].onColor, colors[1].offColor }, { "000000", "0000ff" })
T.eq("defaults: Toggle blue while on", { colors[2].onColor, colors[2].offColor }, { "0000ff", "000000" })
T.eq("SET_BUTTON_COLOR changes a button", ButtonLinks.set(colors, 2, "00ff00", "0000ff"), true)
T.eq("to the chosen colors", { colors[2].onColor, colors[2].offColor }, { "00ff00", "0000ff" })
T.eq("the same again: no change", ButtonLinks.set(colors, 2, "00FF00", "0000ff"), false)
T.eq("only the on color", ButtonLinks.set(colors, 0, "ff0000", nil), true)
T.eq("keeps the off color", colors[0].offColor, "000000")
T.eq("an unknown button", ButtonLinks.set(colors, 5, "ff0000", "ff0000"), false)
T.eq("current color while on", ButtonLinks.current(colors, 2, true), "00ff00")
T.eq("current color while off", ButtonLinks.current(colors, 2, false), "0000ff")
local reloaded = ButtonLinks.load({ ["2"] = { onColor = "00ff00", offColor = "0000ff" } })
T.eq("saved colors come back (string keys after persisting)", reloaded[2].onColor, "00ff00")
T.eq("and the rest default", reloaded[1].offColor, "0000ff")

T.finish()
