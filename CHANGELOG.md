# <span style="color:#660066">Changelog</span>

<!--
Template for a new release entry (copy below the heading, fill in, uncomment):

## v[Version] - YYYY-MM-DD

### Added
- Added

### Fixed
- Fixed

### Changed
- Changed

### Removed
- Removed
-->

## v2026112102 - 2026-11-21

### Fixed

- MQTT Light: a color temperature sent by Control4 (as xy) reached the bulb up
  to about 20 K too warm: the xy-to-Kelvin conversion was McCamy's
  approximation, so the "Relax" preset's 2240 K went out as 2224 K (450 instead
  of 446 mireds) and the bulb reported 2220 K. The conversion is now exact for
  colors on the white line (a Kelvin to xy and back is the same Kelvin), and
  reads colors off it as before.
- MQTT Light: a command or scene step setting 0% with a color now tells Control4
  that color at once, ahead of the off (the bulb stays off and gets it at the
  next On), and the bulb's old color reported while it is off does not undo it.
  Scenes with lights at 0% and a color can show active.

## v2026112101 - 2026-11-21

### Fixed

- MQTT Light: Advanced Lighting Scenes with a color never showed active. The
  light reported the color it landed on, slightly off the scene's (a TS0502B
  asked for the "Relax" preset's 2240 K reports 2220 K), and the scene agent
  compares exactly. While the light is within 10 mireds (or 0.01 in xy for full
  color) of the color it was asked for, Control4 is now told that color; a color
  set by something else is told as reported.

## v2026112100 - 2026-11-21

### Changed

- MQTT Light: the debug log shows every report the light sends Control4
  (`Told Control4 LIGHT_BRIGHTNESS_CHANGED {...}`, `LIGHT_COLOR_CHANGED`, the
  changing reports and capabilities), beside the commands it receives. The scene
  agent judges whether a scene is active from these reports.

## v2026111917 - 2026-11-21

### Fixed

- MQTT Light: Composer's "Error setting default color rate from driver" (Minimum
  and Maximum 0.000). The driver declared no color and no color temperature, so
  Composer never set up the light's color fade field and then refused Control4's
  0.75 s default. driver.xml now declares both; at start the light tells
  Control4 what it can really do, as before. Composer reads this when a light is
  added, so lights added earlier may still show the message.

## v2026111916 - 2026-11-21

### Added

- MQTT Light: full Advanced Lighting Scene support (Delay, flash, scene ramps),
  on modes (Preset, Previous, Dim-To-Warm) and Daylight Agent support are back,
  as in v2026111914, with the same capabilities declared.

### Changed

- MQTT Light documentation: after updating, the controller takes the new
  capabilities at a reboot, but Composer keeps those a light had when it was
  added. Lights added before v2026111912 keep working (scene steps with Delay
  run), but are offered in an Advanced Lighting Scene's Add/Remove list only
  once deleted and added again. A scene saved while its lights had full support
  sends them `ACTIVATE_SCENE`, which needs this version. Composer's "Error
  setting default color rate" message on lights without color is harmless.

## v2026111915 - 2026-11-21

### Changed

- MQTT Light: back to v2026111911, the last version confirmed working. The
  Advanced Lighting Scene, on mode and Daylight support of v2026111912 to
  v2026111914 is withdrawn: Composer keeps the capabilities a light had when it
  was added, so lights added before those versions were no longer offered in an
  Advanced Lighting Scene's Add/Remove list unless deleted and added again.
  Reboot the controller after updating. A light deleted and added again with
  v2026111912 to v2026111914 may need the same once more to be offered in the
  Add/Remove list.

## v2026111914 - 2026-11-20

### Fixed

- MQTT Light: after v2026111912 no MQTT Light appeared in the Add/Remove list of
  an Advanced Lighting Scene. The light's capabilities now follow the full set a
  light with working Advanced Lighting Scenes declares: `True`/`False` values,
  and `supports_default_on`, `supports_color_stop`, `color_trace_tolerance`,
  `has_fixed_ramp_rate`, `fixed_ramp_rate`, `has_extras`, `disable_flash` and
  `multi_click` declared; fade times up to 65535 ms; color rate behavior 1. The
  light tells the same at runtime. Reboot the controller after updating.

## v2026111913 - 2026-11-20

### Changed

- MQTT Light documentation: after updating, a controller reboot is enough for
  Composer to offer Delay, the on modes and load groups on existing lights
  (confirmed); they do not need to be deleted and added again.

## v2026111912 - 2026-11-20

### Added

- MQTT Light: full Advanced Lighting Scene support. Control4 sends each scene
  (`PUSH_SCENE`) to the light, which runs its steps itself: a **Delay** before
  each step, its brightness and color with their fade times, flash scenes, and
  scene ramps up and down with stop. Any other brightness command ends a scene's
  later steps. Scenes are kept across restarts.
- MQTT Light: on modes. Brightness On Mode Preset and Previous; Color On Mode
  Preset, Previous and Fade (Dim-To-Warm). The light reads them from the proxy
  at start (`GET_SETUP`) and follows every change.
- MQTT Light: Daylight Agent support. The light reports the preset its level and
  color come from (preset id and origin), turns on in the agent's color and
  follows it through the day; a color picked by hand stops the following until
  the next On.

### Changed

- The light now declares full scene support and the on mode capabilities.
  Composer reads these when a light is added: a light added with an earlier
  version may need a controller reboot, or to be deleted and added again, before
  Composer offers Delay and the on modes. v2026111911 is the version to go back
  to if needed.

## v2026111911 - 2026-11-20

### Changed

- MQTT Light documentation: a Zigbee Troubleshooting section with the gateway
  console checks (ZbStatus3, ZbLight, ZbName, ZbForget, link quality), the
  commands to check a light fades by itself, the brightness and color
  temperature order, and how to see what the driver sends.

## v2026111910 - 2026-11-20

### Changed

- Documentation brought up to date: Zigbee lights fade by themselves (fade time
  in their commands, so leave Transition Command Topic empty), when the Fade
  setting applies and why Zigbee lights keep Jump to Target, keypad holds on
  lights that fade by themselves, discovery of Zigbee lights, and load groups
  (Dimmer Load Group; a Switch Load Group takes only lights that cannot dim).

## v2026111909 - 2026-11-19

### Fixed

- MQTT Light: a scene on a Zigbee light (brightness and color temperature
  together) jumped at the start of its fade. Tested on a TS0502B: color
  temperature first, or both at the same moment, jumps; brightness first and
  color temperature 250 ms later is smooth. Lights whose commands carry the fade
  time now send them that way.

## v2026111908 - 2026-11-19

### Added

- MQTT Light: Command Payload placeholders `{hex8}`, `{hex16}` and `{time16}`
  (fade time in tenths of a second); a template with `{time16}` makes the light
  fade by itself with Control4's fade time.
- Zigbee lights behind a Tasmota gateway fade by themselves: picking one fills
  in the standard Zigbee commands with the fade time, `0008!04` (Move to Level
  with On/Off, which also fades on and off) and `0300!0A` (Move to Color
  Temperature), so brightness and color temperature change smoothly in one
  command each instead of in steps. Pick the light again (or set the templates)
  to use it on lights already set up.

## v2026111907 - 2026-11-19

### Fixed

- MQTT Light: a fade started while another was running began from the last
  confirmed level instead of where the light was, so dragging the slider made a
  light jump back up (Dimmer 254) on every step. Fades now start where the
  previous one got to, and the first step goes toward the target instead of
  resending the start.

### Added

- MQTT Light: Fade (Stepped, Jump to Target) for lights without a transition
  topic. Jump to Target sends one command with the final brightness; picking a
  Zigbee light sets it. With it, reports of another level within 2 seconds of a
  command are taken as late and not passed on, so Control4 (and scenes) see the
  level the light ends on. Keypad holds still step, every 500 ms at most.

## v2026111906 - 2026-11-19

### Fixed

- MQTT Light: Composer Pro could still refuse the default brightness and color
  rate ("Value of '0.750' is not valid", Minimum and Maximum 0), for example
  when the light's capabilities changed. The fade time ranges and their 0.75 s
  defaults are now sent on their own before the other capabilities, as well as
  with them, and driver.xml declares the defaults. Lights added before
  v2026102502 may still need to be removed and added again.

## v2026111905 - 2026-11-19

### Added

- MQTT Light: Zigbee Light Type (Auto, Switch, Dimmer, White (CT)), shown for a
  Zigbee light. Auto uses what the broker detected; the others fill in the
  fields for that kind of light whatever the gateway says. Device Notes say when
  the gateway's `ZbLight` type differs.

## v2026111904 - 2026-11-19

### Fixed

- Zigbee discovery kept showing lights as dimmers or switches after an update:
  the saved list was read with the older version, and the gateway was not asked
  again when it reconnected within a minute of an earlier ask (as it does after
  the broker restarts). A gateway is now asked every time it connects, and the
  broker keeps each device's answer and reads it again when it starts.

## v2026111903 - 2026-11-19

### Fixed

- Zigbee discovery read the light type from the wrong `Config` entry. Tasmota
  shows the type set with `ZbLight` on the Level entry (`L01.2`); the `~01.1`
  entry it was read from is something else. Lights set with `ZbLight <light>,2`
  showed as dimmers, and one as a switch. A `ZbLight` answer on the gateway now
  updates the light at once, and Device Notes suggest `ZbLight` for lights
  without a type.
- The broker saves what it learns about Zigbee devices within 2 seconds rather
  than 10, so less is lost when it restarts.

## v2026111902 - 2026-11-19

### Fixed

- Zigbee discovery: a device counts as a light only when it has the On/Off
  cluster. Soil moisture sensors (HOBEIAN ZG-303Z) that Tasmota had marked as a
  light type were offered as dimmers.

## v2026111901 - 2026-11-19

### Added

- MQTT Broker: Zigbee discovery. Every Tasmota is asked `ZbStatus1`; a Zigbee
  gateway's devices are read with `ZbStatus3`, and its lights (light type from
  `ZbLight`, or the On/Off and Level clusters) appear in the MQTT Light's
  Discovered Device list. New Zigbee Devices property and Print, Find and Forget
  Zigbee Devices actions.
- MQTT Light: picking a Zigbee light fills in the `ZbSend` command payloads
  (device named by IEEE address), state topic and value paths (learnt from the
  gateway's messages: SetOption89, 83 and 112), scales and the gateway's
  Online/Offline, and renames the light after the device. Device Notes say when
  `ZbLight` or `ZbName` should be run.

## v2026111900 - 2026-11-19

### Added

- MQTT Light: Command Payload templates for Power, Brightness, Color Temp, Color
  and White (`{value}` is the value), for lights that need the value inside a
  bigger message, such as Tasmota Zigbee `ZbSend`
  (`{"Device":"spot1","Send":{"Dimmer":{value}}}`). The light documentation has
  a Tasmota Zigbee bridge example.

## v2026103100 - 2026-10-31

### Added

- MQTT Fan: Speed Command Payload, an optional template for speed commands
  (`{value}` is the speed value), for devices that need the value inside a
  bigger message, such as Tasmota Zigbee `ZbSend`
  (`{"Device":"STARKVIND","Write":{"IkeaFanMode":{value}}}`).

## v2026103006 - 2026-10-30

### Added

- **MQTT Fan** (`cp_mqtt_fan.c4z`): one MQTT fan as a native Control4 fan, with
  on/off, speeds, preset speed and reverse. Like the MQTT Light, every ability
  comes from a property: power, speed and direction state and command topics
  (Separate Topics), or one JSON state and command topic with keys
  (Zigbee2MQTT). Speed Values (`low,medium,high`, `1,2,3`, `33,66,100`) and a
  Speed Off Value fit any device; Control4 always shows 6 speed levels, and
  Speed Mapping spreads the device's speeds over them. On, Off, Toggle, Speed
  Up, Speed Down and Toggle Direction button links with LED colors.
- Tasmota discovery finds iFans (Sonoff iFan02, iFan03, iFan04): pick one in the
  MQTT Fan's Discovered Device list and every setting is filled in.

## v2026103005 - 2026-10-30

### Added

- MQTT General w Webview: a 24-hour graph for every number, as a small line in
  each tile and as a large chart with times, minimum, average and maximum when a
  tile is tapped. Each point is the average of a 15-minute slot (96 points a
  day). The history is kept in the controller's memory only (about 1.5 KB per
  field, never written to flash) and starts again after a restart or Clear
  Values. The page gets the whole history when it opens and only the newest
  point after that.

## v2026103003 - 2026-10-30

### Changed

- MQTT General w Webview: an empty Title shows no heading (it no longer falls
  back to the driver name), and the Live / Stale / Broker offline status with
  the last update time is at the bottom of the page instead of the top right
  corner.

## v2026103002 - 2026-10-30

### Changed

- MQTT General w Webview: fields that arrive in separate MQTT messages are kept;
  each field keeps its last value instead of the latest message replacing them
  all. Field Order now lists the fields to show: they are always shown, with
  `--` until a value arrives, and fields not listed are not shown (an empty
  Field Order still shows every received field).

### Added

- MQTT General w Webview: a read-only **Received Fields** property with every
  field ever received, and a **Received Fields Action** list with Copy All to
  Field Order (every received field except Hidden Fields) and Clear.

## v2026103001 - 2026-10-30

### Changed

- MQTT Web View is now **MQTT General w Webview**
  (`cp_mqtt_general_webview.c4z`) and is built like Control4's WebView driver: a
  driver with its own Experience button (no longer a combo driver), so it can be
  shown in a room's Comfort menu, or Listen, Watch and Security, on touch
  screens and in the apps. It sends the web view address and icon once the
  button is ready. Delete `cp_mqtt_webview` from projects and add MQTT General w
  Webview; the old file is no longer updated.

## v2026103000 - 2026-10-30

### Added

- MQTT Web View driver (`cp_mqtt_webview.c4z`): the values of one or more MQTT
  topics on a web view that opens from an Experience button on T4 and T5 touch
  screens and in the Control4 iOS and Android apps. JSON payloads such as an
  IKEA VINDSTYRKA in Zigbee2MQTT become one tile per field, with labels, units
  and Good, Fair, Poor or Bad grading for air-quality readings (also on the
  navigator icon). The page is served by the controller from the driver and gets
  its data from the driver, not from MQTT. Optional Control4 variables per
  value, hidden, ordered and relabeled fields, stale data detection, and Values
  Updated, Air Quality Changed and Data Stale events.
- MQTT Broker: connects and updates the web view driver too.

## v2026102900 - 2026-10-29

### Fixed

- MQTT Light could not be added to a Switch Group or other Control4 load group:
  it declared no load group support. It now does, and carries out a group's set
  level, ramp to level, start ramp and stop ramp commands on its own device.
  Delete and re-add existing lights in Composer to pick up the change.

## v2026102600 - 2026-10-26

### Added

- MQTT Thermostat driver (`cp_mqtt_thermostat.c4z`): one MQTT thermostat as a
  Control4 thermostat (thermostatV2). Current temperature, humidity, heat and
  cool setpoints (single setpoint when both use one topic), HVAC mode, power,
  HVAC state and fan mode, each turned on by filling in its topic. Value maps
  for modes and states, payload templates and a temperature multiplier for
  devices such as TuyaMCU thermostats, and Celsius or Fahrenheit per device.

## v2026102511 - 2026-10-25

### Added

- MQTT Shutter driver (`cp_mqtt_shutter.c4z`): one MQTT shutter or blind as a
  Control4 blind, using the same blind proxy protocol as Control4's 2 Relay
  Blinds driver. Position (0-100), open, close and stop; slats with a second
  driver set to Control: Tilt. Separate topics, JSON (Zigbee2MQTT) or Shelly
  Gen2+ RPC. A Discovered Device list with the Tasmota shutters and Shelly
  covers the MQTT Broker driver found; picking one fills in every setting and
  names the driver. Open, Close and Toggle Button Links for keypads (tap to
  move, tap again to stop, hold to move while held) with LED color pickers.
- MQTT Broker: discovery also records Tasmota shutters (shutter relays, tilt)
  and Shelly covers (slat control); the broker updates the shutter driver too.

## v2026102510 - 2026-10-25

### Fixed

- MQTT Broker: Update Drivers could leave the broker itself a version behind.
  Its own update goes to the controller last, and the connection was closed
  right after that last message, which could drop it. The connection now stays
  open until every message is sent.

## v2026102509 - 2026-10-25

### Fixed

- MQTT Broker: Tasmota devices found before v2026102508 showed 0 buttons until
  they announced themselves again. The broker now keeps each discovery message
  and reads it again when it starts, so what a driver update reads from it
  applies at once.

## v2026102508 - 2026-10-25

### Added

- MQTT General: a Discovered Device list with the Tasmota and Shelly devices the
  MQTT Broker driver has found. Picking one creates an Event for each of its
  buttons (Tasmota buttons with `SetOption73 1`, switches with `SetOption114 1`,
  Shelly inputs set to Button), with the State Topic, Value Path and Event Type
  Filter filled in.
- MQTT Broker: Tasmota and Shelly discovery also records buttons and inputs;
  Shelly devices with inputs only (Plus i4) are listed too.
- JSONPath value paths accept filters such as
  `$.params.events[?(@.component=='input:0')].event` and quoted keys.

## v2026102507 - 2026-10-25

### Fixed

- MQTT Light button links now work like Control4's own lights: the ON, OFF and
  Toggle Button Links are bindings 300-302, and the keypad LED colors are chosen
  in the light's Brightness tab (Button and Button Connection Status LED
  Colors), which Composer now shows. Keypads get the colors and the light's
  on/off state on every bound link. This replaces the six color properties of
  v2026102506.

## v2026102506 - 2026-10-25

### Added

- MQTT Light: On, Off and Toggle Button Links in the Connections tab, for keypad
  buttons. A tap turns the light on, off or toggles it; holding dims and
  releasing stops. The keypad LED follows the light, in colors chosen with six
  color pickers in Properties (each link's color while the light is on and while
  it is off).

### Fixed

- MQTT Light: releasing a hold-to-dim right after it started on a light that was
  off could turn the light off instead of leaving it at the lowest level.

## v2026102505 - 2026-10-25

### Added

- Shelly Gen2+ discovery (Plus, Pro, Gen3, Gen4) in the MQTT Broker driver, in
  both modes. When a Shelly connects the driver asks it to announce itself and
  reads its outputs over Shelly RPC. New Shelly Devices property and Print, Find
  and Forget Shelly Devices actions.
- MQTT Light: Payload Mode `Shelly (Gen2+)` for dimmer (`light`), tunable white
  (`cct`), `rgb`, `rgbw` and relay (`switch`) outputs, controlled with
  `<Type>.Set` over RPC, with fades on the device. Shelly outputs appear in the
  device list next to Tasmota's; picking one fills in the settings and names the
  light after the Shelly.

### Changed

- MQTT Light: the Tasmota Device and Tasmota Notes properties are now Discovered
  Device and Device Notes. A Tasmota device already chosen stays chosen.

## v2026102504 - 2026-10-25

### Fixed

- Fixed Composer Pro refusing the MQTT Light's default color rate ("Value of
  '0.750' is not valid", with Minimum and Maximum 0). The light now sends its
  brightness and color fade time range with every capability update, which
  Composer otherwise reads as 0 to 0.

## v2026102503 - 2026-10-25

### Added

- MQTT Light and MQTT General connect themselves to the MQTT Broker driver; no
  binding to make in Composer. A light added before the broker is connected by
  the broker when it starts. Bindings made by hand are left alone.
- Picking a Tasmota Device renames the MQTT Light after it (the Tasmota
  DeviceName, or the output's FriendlyName on devices with several outputs).
- Update Drivers reports in the log whether the update worked: after the drivers
  restart, `Update to vX succeeded`, or `FAILED` with the drivers that are still
  on another version. Errors reaching GitHub are logged too.

## v2026102502 - 2026-10-25

### Fixed

- Fixed Composer Pro refusing the MQTT Light's Default Brightness Rate ("Value
  of '0.750' is not valid"). The light declared a 3600 s maximum brightness and
  color fade time, which Composer reads as a 16-bit number and so as negative.
  The maximum is now 32.7 s; keypad click and hold rates are not affected.

## v2026102501 - 2026-10-25

### Fixed

- Fixed automatic updates missing a new release. The updater took the first
  release GitHub listed as the newest, but GitHub does not list releases in
  version order (v20261030 came before v2026102500), so controllers stayed on
  the old drivers. It now picks the release with the highest version.

## v2026102500 - 2026-10-25

### Added

- Added Tasmota discovery. The MQTT Broker driver finds Tasmota devices in both
  modes and keeps the list across restarts; its Print Tasmota Devices action
  shows them. The MQTT Light driver has a new **Tasmota Device** list: picking a
  light or relay fills in every setting, including the right `POWER<n>`, split
  RGB and white lights (`SetOption37`) and one dimmer per channel
  (`SetOption68`). The light follows the device if its topic changes later.

### Fixed

- Fixed the release notes of v20261030 leaving out two fixes it already
  contained: MQTT General temperature sensor items now update a bound
  thermostat, and sensor and number variable items ignore `nan` and `inf`
  payloads, keeping the last good value.

## v20261030 - 2026-10-25

### Added

- Added the MQTT Light driver, a native Control4 light (light_v2) for one MQTT
  light. Its abilities follow the topics you fill in: on/off, dimmer, color
  temperature, full color (RGB, Hex, HSB, HS or XY), an RGBW white channel and
  device-side fades. Works with separate plain topics (Tasmota, ESPHome) or a
  single JSON state/command topic (Zigbee2MQTT).
- Added a built-in MQTT broker to the MQTT Broker driver. With **Broker Mode**
  set to `Built-in`, the controller is the broker: Tasmota and other MQTT
  devices connect to it on port 3883, with no separate broker needed. The MQTT
  Light and MQTT Universal drivers work the same in both modes. New actions
  Print Clients, Print Retained, Print Report and Reset Statistics show what is
  connected.
- Added State Request Topic to the MQTT Light driver. It asks the device for its
  full state when the broker connects and when the device comes online, so a
  light shows the right state after a controller restart.

### Changed

- The MQTT drivers are now published by Control Pro and update from
  github.com/krishy2/control4-mqtt. DriverCentral licensing has been removed.
- The drivers are now fully independent of other MQTT driver suites and can be
  installed next to them in the same project: new file names
  (`cp_mqtt_broker.c4z`, `cp_mqtt_general.c4z`, `cp_mqtt_light.c4z`) and their
  own connection type. MQTT Universal is renamed **MQTT General**. Because the
  file names changed, these are new drivers to Composer: add them to the project
  again and remove the previous ones.
- The MQTT Light documentation reads the Tasmota power state from
  `stat/<topic>/RESULT` and explains `POWER<n>` for Tasmota devices with more
  than one load.

### Fixed

- Fixed an automatic update sometimes leaving companion drivers on the previous
  version until the next update, which could make them stop responding in the
  meantime.
- Fixed an MQTT event leaving a bound light stalled part way through a ramp
  instead of toggling it. Event button links now send the same command pair a
  Control4 keypad sends for a tap.
- Fixed the Device Available, Device Unavailable and event item Triggered events
  leaving the device's name out of their script title in Composer Pro. The title
  now names the device.

## v20260415 - 2026-04-15

### Fixed

- Fixed MQTT Broker auto-reconnect reliability.

## v20260414 - 2026-04-14

### Fixed

- Fixed MQTT Universal variables losing their programming "Set Variable"
  callback after the first inbound MQTT message on the variable's state topic.
- Fixed MQTT Universal BOOL variables not toggling reliably from programming due
  to incorrect serialization to Control4.
- Fixed MQTT Universal variables losing their writable state after a controller
  reboot or driver reload.

<!-- #ifndef DRIVERCENTRAL -->

- Fixed automatic driver updates not working when the leader instance is removed
  from the project.

<!-- #endif -->

## v20260217 - 2026-02-17

### Changed

- Broker properties (Automatic Updates, Update Channel) now automatically sync
  across all MQTT Broker driver instances.
- Temperature conversions (Fahrenheit/Celsius) now use single decimal precision
  instead of rounding to the nearest integer or half degree.

### Fixed

- Fixed variable restore order during driver initialization on controller
  reboot.

## v20260120 - 2026-01-27

### Fixed

- Fixed incorrect DriverCentral product ID in MQTT Universal driver.

## v20260120 - 2026-01-20

### Fixed

- Fixed consumer bindings (e.g., BUTTON_LINK for Event entities) not restoring
  their connections on controller reboot. The bindings module now tracks
  connection info and automatically re-establishes consumer binding connections
  when bindings are restored.

## v20260119 - 2026-01-19

### Added

- Added Event entity type to MQTT Universal driver for receiving MQTT events and
  triggering Control4 buttons/keypads.

### Changed

- Updated MQTT Broker documentation to include Programming section with events
  and conditionals.
- Updated MQTT Universal documentation to include missing read-only properties
  and BUTTON_LINK binding information.

### Removed

- Removed deprecated MQTT Switch, MQTT Contact, and MQTT Button drivers.

## v20260117 - 2026-01-17

### Added

- Added the MQTT Universal driver for managing multiple MQTT devices from a
  single driver instance. Supports relays, contacts, buttons, variables, and
  sensors with features including:
  - Keypad button linking for MQTT buttons
  - Device availability conditionals and events
  - State variables for relay and contact items
  - JSONPath value extraction for complex JSON payloads
- Added "Broker Connected" conditional and events to the MQTT Broker driver.

### Deprecated

- Deprecated the MQTT Switch, MQTT Contact, and MQTT Button drivers. Use MQTT
  Universal instead. This is the terminal release for these drivers.

## v20251229 - 2025-12-29

### Added

- Initial Release.
