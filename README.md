<!-- Copyright 2026 Control Pro. All rights reserved. -->

<img alt="MQTT" src="./images/header.png" width="500"/>

______________________________________________________________________

# <span style="color:#660066">Overview</span>

> DISCLAIMER: This software is neither affiliated with nor endorsed by either
> Control4 or MQTT.

The MQTT Broker driver gives the MQTT drivers below their MQTT connection. It
works in one of two modes:

- **External**: connects to an MQTT broker on the network (Mosquitto, Home
  Assistant, ...).
- **Built-in**: the controller is the broker. MQTT devices such as Tasmota
  connect straight to the controller, with no extra hardware or software.

The other MQTT drivers work the same in both modes, and connect themselves to
this driver: there is nothing to bind in the Connections tab, whichever driver
is added first.

## Driver Suite

The MQTT driver suite consists of three drivers:

| Driver           | Direction     | Purpose                                                                                         |
| ---------------- | ------------- | ----------------------------------------------------------------------------------------------- |
| **MQTT Broker**  | N/A           | The MQTT connection: an external broker, or the built-in one                                    |
| **MQTT General** | Inbound       | External MQTT device -> Control4 (create relays, contacts, buttons, variables from MQTT topics) |
| **MQTT Light**   | Bidirectional | One MQTT light as a native Control4 light (on/off, dimmer, color temperature, color)            |

**Typical Setup:**

1. Add the **MQTT Broker** driver and choose its mode
1. Add one **MQTT Light** per MQTT light (Tasmota, Zigbee2MQTT, ESPHome, ...)
1. Add **MQTT General** for other MQTT devices: relays, contacts, buttons,
   sensors

# <span style="color:#660066">Index</span>

<div style="font-size: small">

- [System Requirements](#system-requirements)
- [Features](#features)
- [Installer Setup](#installer-setup)
  - [Driver Installation](#driver-installation)
  - [Built-in Broker Setup](#built-in-broker-setup)
  - [External Broker Setup](#external-broker-setup)
  - [Shelly Setup](#shelly-setup)
  - [Driver Properties](#driver-properties)
  - [Driver Actions](#driver-actions)
  - [Programming](#programming)
- [Support](#support)
- [Changelog](#changelog)

</div>

# <span style="color:#660066">System Requirements</span>

- Control4 OS 3.3+ (the built-in broker has been tested on OS 4.x)
- External mode: an MQTT broker reachable on the local network

# <span style="color:#660066">Features</span>

- Local network communication requiring no cloud services
- **Built-in broker** for up to a few hundred devices on a trusted home network:
  MQTT 3.1 and 3.1.1, retained messages, Last Will, wildcards
- **External broker** with username/password authentication and automatic
  reconnection
- **Tasmota discovery**: finds Tasmota devices so the MQTT Light driver can set
  itself up from a list
- **Shelly discovery**: finds Shelly Gen2+ devices (Plus, Pro, Gen3, Gen4) and
  their dimmer, CCT, RGB, RGBW and relay outputs, for the same list
- Manages subscriptions for connected child drivers
- Message caching for late-subscribing devices
- Automatic updates of all MQTT drivers from GitHub

# <span style="color:#660066">Installer Setup</span>

## Driver Installation

1. Download the latest release from
   [GitHub](https://github.com/krishy2/control4-mqtt/releases/latest).

1. [Install](<(https://www.control4.com/help/c4/software/cpro/dealer-composer-help/content/composerpro_userguide/adding_drivers_manually.htm)>)
   the `cp_mqtt_broker.c4z`, `cp_mqtt_general.c4z` and `cp_mqtt_light.c4z`
   drivers.

1. In Composer's "Search" tab, search for "MQTT Broker" and add the driver to
   your project.

   > ⚠️ Use a **_single_** broker driver per broker. Only one driver can run the
   > built-in broker on a given port.

1. Choose the [Broker Mode](#broker-mode--external--built-in-) and follow the
   matching setup below.

## Built-in Broker Setup

1. Set **Broker Mode** to `Built-in`.

1. [`Driver Status`](#driver-status-read-only) shows
   `Built-in broker on port 3883: 0 devices`.

1. Give the controller a fixed IP address (a DHCP reservation), because every
   device is configured with it.

1. On each Tasmota, open Configuration → Configure MQTT, set **Host** to the
   controller's IP address and **Port** to `3883`, and save. User and password
   are not checked and can stay as they are.

1. **Connected Devices** counts up as devices connect. Run
   [Print Clients](#print-clients) to see them.

Port 1883 is used by the controller's own system broker, so the built-in broker
uses 3883 by default.

The built-in broker is meant for a trusted home network: it does not check user
names or passwords and does not encrypt. Use External mode with a broker of your
own if you need those.

## Shelly Setup

Shelly Gen2+ devices (Plus, Pro, Gen3, Gen4) are found in both modes. In the
Shelly's web page open **Settings → MQTT** and set:

| Setting                            | Value                                                                    |
| ---------------------------------- | ------------------------------------------------------------------------ |
| Enable                             | On                                                                       |
| Server                             | Built-in: `<controller IP>:3883`; External: your broker's `host:port`    |
| Client ID                          | Leave as it is (the device ID)                                           |
| MQTT Prefix                        | Leave as it is (the device ID), or a custom prefix of one or two levels  |
| User / Password                    | Empty in Built-in mode; your broker's account in External mode           |
| SSL/TLS                            | No TLS                                                                   |
| RPC over MQTT                      | On (the default): the light controls the device with it                  |
| RPC status notifications over MQTT | On (the default): the light follows the device with them                 |
| Generic status update over MQTT    | Optional, not needed                                                     |
| Enable MQTT control                | On (the default): the broker asks devices to announce themselves with it |

Save; the Shelly reconnects. Within a few seconds of connecting it appears in
[Shelly Devices](#shelly-devices-read-only) and in the MQTT Light's Discovered
Device list. Names come from the Shelly: its **Device name** and each output's
name (**Channel name** or **Light name**), so name them on the Shelly first.

How it works: when a Shelly publishes `<prefix>/online`, the driver sends
`announce` to `<prefix>/command`; the Shelly answers on `<prefix>/announce`, and
the driver reads its outputs with `Shelly.GetConfig` over RPC (answers on
`control4/shelly/rpc`). The driver also asks all devices on `shellies/command`
when it connects and every 15 minutes. In External mode a custom prefix with
more than two levels is found only through that broadcast. Gen1 devices (Shelly
1, 2.5, Dimmer 2, RGBW2, Bulb, Duo) are not supported.

## External Broker Setup

1. Set **Broker Mode** to `External`.

1. Fill in the [External Broker Settings](#external-broker-settings) with the
   connection information.

1. After a few moments the [`Driver Status`](#driver-status-read-only) will
   display `Connected`. If the driver fails to connect, set the
   [`Log Mode`](#log-mode--off--print--log--print-and-log-) property to `Print`
   and run action [`Reconnect`](#reconnect). Then check the Lua output window
   for more information.

## Driver Properties

### Update Settings

#### Automatic Updates

Turns automatic updates of all MQTT drivers from GitHub on or off.

#### Update Channel

Sets the update channel for which releases are considered during an automatic
update from the GitHub repo releases.

### Driver Settings

#### Driver Status (read-only)

Displays the current status of the driver.

#### Driver Version (read-only)

Displays the current version of the driver.

#### Log Level \[ Fatal | Error | Warning | **_Info_** | Debug | Trace | Ultra \]

Sets the logging level. Default is `Info`.

#### Log Mode \[ **_Off_** | Print | Log | Print and Log \]

Sets the logging mode. Default is `Off`.

#### Broker Mode \[ **_External_** | Built-in \]

`External` connects to an MQTT broker on the network. `Built-in` makes the
controller the broker. Changing it restarts the MQTT connection; the other
drivers reconnect on their own.

#### Shelly Devices (read-only)

How many Shelly Gen2+ devices the broker has found. See
[Shelly Setup](#shelly-setup). The list is kept when the controller restarts.

#### Tasmota Devices (read-only)

How many Tasmota devices the broker has found. Tasmota announces itself on
`tasmota/discovery/<MAC>/config` when it connects, as long as discovery is on
(`SetOption19 0`, the default). This works in both modes. The list is kept when
the controller restarts, and the MQTT Light driver offers these devices in its
Tasmota Device list.

### External Broker Settings

Shown in External mode.

#### Broker Address

Sets the broker IP address (e.g. `192.168.1.30`). Domain names are allowed as
long as they can be resolved to an accessible IP address by the controller.
HTTPS is not supported.

> ⚠️ If you are using an IP address, you should ensure it will not change by
> assigning a static IP or creating a DHCP reservation.

#### Port

Sets the broker port. The default port for most brokers is `1883`.

#### Username

Sets the username for broker authentication (optional).

#### Password

Sets the password for broker authentication (optional).

#### Keep Alive

Sets the keep-alive interval in seconds. Default is `60`.

### Built-in Broker

Shown in Built-in mode.

#### Listen Port

The port devices connect to. Default `3883`.

#### Max Clients

New connections above this many are refused. Default `250`.

#### Connected Devices (read-only)

MQTT devices connected to the built-in broker.

#### Messages per Second (read-only)

Messages received per second, over the last 5 seconds.

#### Broker Errors (read-only)

Protocol, socket and driver errors since the broker started, with the most
recent one. Should stay `0`.

#### Timer Lag (read-only)

How late a 1-second timer fires: a measure of how busy the controller is. A few
milliseconds is normal.

## Driver Actions

### Reconnect

External mode: reconnects to the MQTT broker. Built-in mode: restarts the
built-in broker; devices reconnect on their own within a few seconds.

### Print Clients

Built-in mode: prints one line per connected device (client id, address,
keepalive, time online, subscriptions, message counts) to the Lua output.

### Print Retained

Built-in mode: prints all retained messages.

### Print Report

Built-in mode: prints every statistic of the built-in broker.

### Reset Statistics

Built-in mode: resets the counters.

### Print Tasmota Devices

Prints every Tasmota device found: name, topic, IP address, model and its lights
and relays with their `POWER` index, plus any settings to change on the device.

### Forget Tasmota Devices

Clears the list. Devices that are connected are found again the next time they
connect (or restart them, or run `SetOption19 0` on them).

### Print Shelly Devices

Prints every Shelly found: name, topic prefix, model and its outputs with their
component (`light:0`, `rgbw:0`, `switch:1`, ...).

### Find Shelly Devices

Asks every Shelly on the broker to announce itself and reads each configuration
again, for example after renaming outputs on a Shelly. Run
[Print Shelly Devices](#print-shelly-devices) a few seconds later.

### Forget Shelly Devices

Clears the Shelly list. Connected devices are found again when they next connect
or with [Find Shelly Devices](#find-shelly-devices).

### Update Drivers

Updates all MQTT drivers to the latest release on GitHub, regardless of the
current version. The log shows each step:

- `Update started: ...` with the installed version of each driver;
- `Update: vYYYYMMDDNN downloaded and sent to the controller`, after which the
  drivers restart;
- after the restart, `Update to vYYYYMMDDNN succeeded` with the new version, or
  `Update to vYYYYMMDDNN FAILED` naming each driver still on another version;
- `Update FAILED: ...` if GitHub could not be reached or a download failed.

Automatic updates report the result the same way after the restart.

## Programming

**Events:**

- **Broker Connected** - Fires when the driver connects to the external broker,
  or the built-in broker starts
- **Broker Disconnected** - Fires when the connection to the external broker is
  lost, or the built-in broker stops

**Conditionals:**

- **Broker Connected** - Check if the broker is connected or disconnected

# <span style="color:#660066">Support</span>

If you have any questions or issues integrating this driver with Control4, you
can file an issue on GitHub:

https://github.com/krishy2/control4-mqtt/issues/new

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

- Fixed automatic driver updates not working when the leader instance is removed
  from the project.

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
