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
