<!-- Copyright 2026 Control Pro. All rights reserved. -->

<style>
@media print {
   .noprint {
      visibility: hidden;
      display: none;
   }
   * {
        -webkit-print-color-adjust: exact;
        print-color-adjust: exact;
    }
}
</style>

<img alt="MQTT" src="./images/header.png" width="500"/>

______________________________________________________________________

# <span style="color:#660066">Overview</span>

> DISCLAIMER: This software is neither affiliated with nor endorsed by either
> Control4 or MQTT.

The MQTT Shutter driver makes one MQTT shutter, blind or awning a native
Control4 blind: open, close, stop and move to a position from Navigators,
keypads, scenes and programming. It works with Tasmota shutters, Shelly Gen2+
covers and any device with MQTT position and command topics.

One driver controls the shutter's position. For a venetian blind, add a second
MQTT Shutter driver with [Control](#control--position--tilt-) set to `Tilt` for
its slats.

# <span style="color:#660066">Index</span>

<div style="font-size: small">

- [System Requirements](#system-requirements)
- [Installer Setup](#installer-setup)
  - [Driver Installation](#driver-installation)
  - [Driver Properties](#driver-properties)
  - [Example: Tasmota](#example-tasmota)
  - [Example: Shelly](#example-shelly)
  - [Example: Zigbee2MQTT](#example-zigbee2mqtt)
  - [Connections](#connections)
  - [Actions](#actions)
- [Support](#support)
- [Changelog](#changelog)

</div>

# <span style="color:#660066">System Requirements</span>

- Control4 OS 3.3+
- MQTT Broker driver installed and connected

# <span style="color:#660066">Installer Setup</span>

## Driver Installation

1. Install the MQTT Broker driver and connect it to your broker (see its
   documentation).
1. Install `cp_mqtt_shutter.c4z` and add one **MQTT Shutter** driver per
   shutter. It connects itself to the MQTT Broker driver.
1. Pick the shutter in [Discovered Device](#discovered-device), or fill in its
   topics.

## Driver Properties

### Driver Settings

- **Driver Status** (read-only) - `Connected`, `Disconnected` or
  `Device offline`.
- **Driver Version** (read-only), **Log Level**, **Log Mode** - as in the other
  MQTT drivers.

### Availability Settings

An availability topic marks the device offline in **Driver Status**; when it
comes back online the driver asks it for its state. Tasmota: `tele/<topic>/LWT`
with `Online` / `Offline`. Shelly: `<prefix>/online` with `true` / `false`.

### Shutter Settings

#### Discovered Device

The Tasmota shutters and Shelly covers the MQTT Broker driver has found, for
example `Living Shutter [living_shutter] Shutter` or
`Bedroom [shellyplus2pm-a8032ab12345] Bedroom Blind (tilt)`. `(tilt)` marks
shutters with slats. Picking one fills in every setting and renames the driver
after the device (with ` Slats` added when [Control](#control--position--tilt-)
is `Tilt`). The shutter keeps following the device; choose `(Manual)` to stop.

- Tasmota: a shutter is found when its relays are in shutter mode (`ShutterMode`
  / `ShutterRelay1`); tilt when `ShutterTiltConfig1` is set.
- Shelly: a cover is found when the device is in cover profile; slats when slat
  control is on in the cover's settings. Positioning needs a calibrated cover;
  until then the shutter only opens and closes.

#### Device Notes (read-only)

Shown when the picked device is missing a setting, for example tilt not being
set up for a `Tilt` driver.

#### Control \[ **_Position_** | Tilt \]

`Position` moves the shutter; `Tilt` turns the slats (0% closed, 100% open). A
venetian blind uses two MQTT Shutter drivers, one of each.

#### Capabilities / Shutter State (read-only)

What the shutter can do with the current settings (`Position, Stop`,
`Open/Close`, ...) and the state Control4 shows (`40%`, `Open`,
`Moving to 100`).

#### Payload Mode \[ **_Separate Topics_** | JSON | Shelly (Gen2+) \]

- **Separate Topics** - state topics with value paths and command topics per
  action. Tasmota, Home Assistant style MQTT covers.
- **JSON** - one state and one command topic with a JSON object, using
  **Position Key**, **Tilt Key**, **State Key** and **Moving Key**. Zigbee2MQTT.
- **Shelly (Gen2+)** - a cover of a Shelly Plus, Pro, Gen3 or Gen4 over Shelly
  RPC, from **Shelly Topic Prefix** and **Shelly Component** (`cover:0`).

#### State Request Topic / State Request Payload

Optional message that makes the device report its state, sent when the broker
connects and when the device comes online. The **Request State** action sends it
too.

#### Optimistic \[ **_Auto_** | Yes | No \], QoS, Retain

Optimistic assumes a command worked; Auto does that only when no state topic is
set. QoS and Retain apply to commands.

#### Travel Time (Seconds) / Tilt Time (Seconds)

How long a full open or close (or the slats from closed to open) takes. Control4
uses it to show progress, and, without position feedback, to know when a move
has finished.

#### Invert Position \[ **_No_** | Yes \]

`Yes` for devices that report 0 as open and 100 as closed.

### Position

- **Position State Topic / Position Value Path** - where the position (0-100)
  comes from.
- **Position Command Topic** - where a position is sent. With it Control4 can
  move the shutter to any level; without it the shutter only opens and closes.
- **Target Value Path** - optional, the position being moved to.
- **Movement State Topic / Movement Value Path** - optional, whether it is
  moving: `1` / `-1` / `0` (Tasmota Direction), `opening` / `closing` /
  `stopped` / `open` / `closed`, or `UP` / `DOWN` / `STOP`. A device that
  reports only `open` / `closed` here works without a position topic.

### Commands

**Open**, **Close** and **Stop Command Topic** with their payloads. Fully open
and fully closed use Open and Close (so the motor runs to its end stops); levels
in between use the Position Command Topic. Stop appears in Control4 when a Stop
Command Topic is filled in. In JSON mode the payloads are the **State Key**
values (`OPEN`, `CLOSE`, `STOP` when empty).

### Tilt

**Tilt State Topic**, **Tilt Value Path**, **Tilt Command Topic**, and **Tilt
Min** / **Tilt Max**: the device values for slats closed (0%) and open (100%),
`-90` and `90` for Tasmota.

### Button Links

Six color pickers, two for each of the
[Open, Close and Toggle Button Links](#connections): **Open / Close / Toggle
Button LED When Open** and **When Closed**. Keypads show the first while the
shutter is open or partly open, the second while it is closed.

## Example: Tasmota

The quickest way is the [Discovered Device](#discovered-device) list. By hand,
for shutter 1 of a Tasmota with topic `living_shutter`:

| Property               | Value                                  |
| ---------------------- | -------------------------------------- |
| Payload Mode           | Separate Topics                        |
| Position State Topic   | `stat/living_shutter/RESULT`           |
| Position Value Path    | `$.Shutter1.Position`                  |
| Position Command Topic | `cmnd/living_shutter/ShutterPosition1` |
| Target Value Path      | `$.Shutter1.Target`                    |
| Movement State Topic   | `stat/living_shutter/RESULT`           |
| Movement Value Path    | `$.Shutter1.Direction`                 |
| Open Command Topic     | `cmnd/living_shutter/ShutterOpen1`     |
| Close Command Topic    | `cmnd/living_shutter/ShutterClose1`    |
| Stop Command Topic     | `cmnd/living_shutter/ShutterStop1`     |
| State Request Topic    | `cmnd/living_shutter/ShutterPosition1` |
| Availability Topic     | `tele/living_shutter/LWT`              |

For the slats: Control `Tilt`, Tilt State Topic `stat/living_shutter/RESULT`,
Tilt Value Path `$.Shutter1.Tilt`, Tilt Command Topic
`cmnd/living_shutter/ShutterTilt1`, Tilt Min `-90`, Tilt Max `90`.

## Example: Shelly

Pick the cover in [Discovered Device](#discovered-device), or set Payload Mode
`Shelly (Gen2+)`, Shelly Topic Prefix (the device ID, for example
`shellyplus2pm-a8032ab12345`) and Shelly Component `cover:0`. The driver sends
`Cover.Open`, `Cover.Close`, `Cover.Stop` and `Cover.GoToPosition` (`pos`, or
`slat_pos` for Tilt) to `<prefix>/rpc` and follows `NotifyStatus` on
`<prefix>/events/rpc`. See the MQTT Broker documentation for the Shelly MQTT
settings.

## Example: Zigbee2MQTT

| Property           | Value                          |
| ------------------ | ------------------------------ |
| Payload Mode       | JSON                           |
| JSON State Topic   | `zigbee2mqtt/Living Blind`     |
| JSON Command Topic | `zigbee2mqtt/Living Blind/set` |
| Position Key       | `position`                     |
| State Key          | `state`                        |
| Moving Key         | `moving`                       |

## Connections

- **MQTT Broker** - binds to the MQTT Broker driver automatically.
- **Blind** - the Control4 blind proxy.
- **Open Button Link**, **Close Button Link**, **Toggle Button Link** - bind a
  keypad button here. A tap opens, closes, or toggles (a tap while the shutter
  moves stops it); holding moves it until the button is released. The keypad LED
  follows the shutter in the colors from [Button Links](#button-links).

## Actions

- **Request State** - asks the device for its state now.

The Lua commands `Open`, `Close` and `Stop` can also be run from programming.

# <span style="color:#660066">Support</span>

If you have any questions or issues integrating this driver with Control4, you
can file an issue on GitHub:

https://github.com/krishy2/control4-mqtt/issues/new

<!-- #embed-changelog -->
