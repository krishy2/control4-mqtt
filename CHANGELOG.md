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
