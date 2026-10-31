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

The MQTT Fan driver makes one MQTT fan a native Control4 fan: on, off, speeds,
preset speed and reverse from Navigators, keypads, scenes and programming. It
works with Tasmota iFans, Zigbee2MQTT fans, Shelly relays and any device with
MQTT power, speed or direction topics.

Like the MQTT Light, every ability comes from a topic (or JSON key) you fill in:
On/Off always, speeds with a speed topic, reverse with a direction topic.

# <span style="color:#660066">Index</span>

<div style="font-size: small">

- [System Requirements](#system-requirements)
- [Installer Setup](#installer-setup)
  - [Driver Installation](#driver-installation)
  - [Speeds in Control4](#speeds-in-control4)
  - [Driver Properties](#driver-properties)
  - [Example: Tasmota iFan](#example-tasmota-ifan)
  - [Example: Zigbee2MQTT](#example-zigbee2mqtt)
  - [Example: Shelly relay](#example-shelly-relay)
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
1. Install `cp_mqtt_fan.c4z` and add one **MQTT Fan** driver per fan. It
   connects itself to the MQTT Broker driver.
1. Pick the fan in [Discovered Device](#discovered-device), or fill in its
   topics.

## Speeds in Control4

Control4's fan reads its number of speeds and whether it can reverse from the
driver file only, once; a property cannot change them. The MQTT Fan therefore
always shows **6 speed levels** (`Level 1` to `Level 6`) and the reverse
control, and maps your fan's own speeds onto them with
[Speed Mapping](#speed-mapping--spread-over-6-levels--levels-1-to-n-):

| Device speeds | Spread over 6 Levels | Levels 1 to N              |
| ------------- | -------------------- | -------------------------- |
| 1 (on/off)    | on = level 6         | on = level 1               |
| 2             | levels 3, 6          | levels 1, 2 (3-6 run 2)    |
| 3             | levels 2, 4, 6       | levels 1, 2, 3 (4-6 run 3) |
| 4             | levels 1, 3, 4, 6    | levels 1-4 (5-6 run 4)     |
| 6             | levels 1-6           | levels 1-6                 |

A level between two speeds runs the speed above it, and Control4 then shows that
speed's level. Speed Up and Speed Down always move one device speed. Without a
direction topic the reverse control does nothing.

> [!NOTE]
> Changing the driver file's capabilities makes Composer ask to restart
> Director, and they only load after a controller reboot. This driver never
> needs that: speed count and direction are properties.

## Driver Properties

### Driver Settings

- **Driver Status** (read-only) - `Connected`, `Disconnected` or
  `Device offline`. The fan shows offline in Control4 while the broker is
  disconnected or the device is unavailable.
- **Driver Version** (read-only), **Log Level**, **Log Mode** - as in the other
  MQTT drivers.

### Availability Settings

An availability topic marks the device offline; when it comes back online the
driver asks it for its state. Tasmota: `tele/<topic>/LWT` with `Online` /
`Offline`. Shelly: `<prefix>/online` with `true` / `false`.

### Fan Settings

#### Capabilities / Fan State (read-only)

What the fan can do with the current settings (`On/Off, 3 Speeds, Reverse`) and
the state Control4 shows (`Off`, `Speed 2 of 3 (medium, level 4)`).

#### Discovered Device

The Tasmota iFans (Sonoff iFan02, iFan03, iFan04) the MQTT Broker driver has
found, for example `Bedroom [bedroom_fan] Fan`. Picking one fills in every
setting and renames the driver after the device. The fan keeps following the
device; choose `(Manual)` to stop. The iFan's light is a separate MQTT Light.

#### Device Notes (read-only)

Shown when the picked device has a setting that should change.

#### Payload Mode \[ **_Separate Topics_** | JSON \]

- **Separate Topics** - a state topic (with an optional value path) and a
  command topic per ability, with plain values. Tasmota, ESPHome, Shelly command
  topics, Home Assistant style MQTT fans.
- **JSON** - one **JSON State Topic** and one **JSON Command Topic** carrying an
  object, using **State Key**, **Speed Key** and **Direction Key**. Zigbee2MQTT.

#### State Request Topic / State Request Payload

Optional message that makes the device report its state, sent when the broker
connects and when the device comes online. The **Request State** action sends it
too. Tasmota: `cmnd/<topic>/STATE`, empty payload.

#### Optimistic \[ **_Auto_** | Yes | No \], QoS, Retain

Optimistic shows a command's result at once instead of waiting for the device;
Auto does that only when no state topic is set. QoS and Retain apply to
commands.

#### On Speed \[ **_Preset Speed_** | Last Speed \]

What On (and Toggle from off) does: run the preset chosen in Control4's fan
settings (the top speed until one is chosen), or the speed the fan last ran at.

### On/Off

- **Power State Topic / Power Value Path** - where on/off comes from. **State
  On** / **State Off** are the values that mean on and off (`ON`, `OFF`, `true`,
  `false` and `1`, `0` work when both are empty). Optional when the speed topic
  also reports off (Speed Off Value).
- **Power Command Topic** with **Payload On** / **Payload Off**. When the fan is
  off and a speed is set, the driver sends Payload On first, then the speed.
- JSON: **State Key** (default `state`) with the same values.

### Speed

- **Speed State Topic / Speed Value Path / Speed Command Topic**, or in JSON
  mode **Speed Key**. Filling one in gives the fan speeds.
- **Speed Values** - the device's value for each speed, slowest first, comma
  separated: `low,medium,high`, `1,2,3`, or percentages `33,66,100`. The number
  of values is the number of speeds (up to 6). A number reported between two
  values goes to the nearest speed; `0` is off when every value is above 0.
- **Speed Count** (1-6) - used when Speed Values is empty: the values are then
  `1` to this number.
- **Speed Off Value** - optional, the speed value that means off: `0` for
  Tasmota FanSpeed, `off` for Zigbee2MQTT `fan_mode`. With it the speed topic
  alone turns the fan on and off, and no power topic is needed.
- **Speed Command Payload** - optional template for speed commands: `{value}` is
  replaced by the speed value (from Speed Values or Speed Off Value). Empty
  sends the value itself. Use it when the value has to sit inside a bigger
  message, as with Tasmota's Zigbee `ZbSend`; see
  [Example: Tasmota Zigbee bridge](#example-tasmota-zigbee-bridge).

#### Speed Mapping \[ **_Spread over 6 Levels_** | Levels 1 to N \]

How the device's speeds sit on Control4's 6 levels; see
[Speeds in Control4](#speeds-in-control4).

### Direction

**Direction State Topic**, **Direction Value Path**, **Direction Command
Topic**, or in JSON mode **Direction Key**, with the values **Direction
Forward** (default `forward`) and **Direction Reverse** (default `reverse`).
Filling one in lets Control4 reverse the fan.

### Button Links

Color pickers for the [Button Links](#connections): **On**, **Off** and **Toggle
Button LED When On** / **When Off**, and **Speed Button LED When On** / **When
Off** for the Speed Up, Speed Down and Toggle Direction links. Keypads show the
first color while the fan runs, the second while it is off.

## Example: Tasmota iFan

The quickest way is the [Discovered Device](#discovered-device) list. By hand,
for an iFan with topic `bedroom_fan`:

| Property            | Value                       |
| ------------------- | --------------------------- |
| Payload Mode        | Separate Topics             |
| Speed State Topic   | `stat/bedroom_fan/RESULT`   |
| Speed Value Path    | `$.FanSpeed`                |
| Speed Command Topic | `cmnd/bedroom_fan/FanSpeed` |
| Speed Values        | `1,2,3`                     |
| Speed Off Value     | `0`                         |
| State Request Topic | `cmnd/bedroom_fan/STATE`    |
| Availability Topic  | `tele/bedroom_fan/LWT`      |

## Example: Zigbee2MQTT

| Property           | Value                         |
| ------------------ | ----------------------------- |
| Payload Mode       | JSON                          |
| JSON State Topic   | `zigbee2mqtt/Ceiling Fan`     |
| JSON Command Topic | `zigbee2mqtt/Ceiling Fan/set` |
| State Key          | `fan_state`                   |
| Speed Key          | `fan_mode`                    |
| Speed Values       | `low,medium,high`             |
| Speed Off Value    | `off`                         |

## Example: Tasmota Zigbee bridge

An IKEA STARKVIND air purifier paired to a Tasmota Zigbee bridge (topic
`zigbee`), controlled with `ZbSend`: `IkeaFanMode` 0 is off, 1 is auto, 10 and
up are the speeds.

| Property              | Value                                                    |
| --------------------- | -------------------------------------------------------- |
| Payload Mode          | Separate Topics                                          |
| Power Command Topic   | `cmnd/zigbee/ZbSend`                                     |
| Payload On            | `{"Device":"STARKVIND","Write":{"IkeaFanMode":1}}`       |
| Payload Off           | `{"Device":"STARKVIND","Write":{"IkeaFanMode":0}}`       |
| Speed Command Topic   | `cmnd/zigbee/ZbSend`                                     |
| Speed Command Payload | `{"Device":"STARKVIND","Write":{"IkeaFanMode":{value}}}` |
| Speed Values          | `10,20,30,40,50` (the device's values, slowest first)    |

Off sends Payload Off. A speed sends Payload On first when the fan is off, then
the speed. To show changes made at the device, add Power and Speed State Topic
`tele/zigbee/SENSOR` with Value Path `$.ZbReceived.STARKVIND.IkeaFanMode` (the
device name appears there with `SetOption83 1`; otherwise its short address),
State Off `0`, and Speed Off Value `0`.

## Example: Shelly relay

A one-speed fan on a Shelly Plus 1 (Gen2+, device ID `shellyplus1-a8032ab12345`,
output `switch:0`):

| Property              | Value                                       |
| --------------------- | ------------------------------------------- |
| Power State Topic     | `shellyplus1-a8032ab12345/status/switch:0`  |
| Power Value Path      | `$.output`                                  |
| Power Command Topic   | `shellyplus1-a8032ab12345/command/switch:0` |
| Payload On            | `on`                                        |
| Payload Off           | `off`                                       |
| State Request Topic   | `shellyplus1-a8032ab12345/command/switch:0` |
| State Request Payload | `status_update`                             |

## Connections

- **MQTT Broker** - binds to the MQTT Broker driver automatically.
- **Fan** - the Control4 fan proxy.
- **On**, **Off**, **Toggle**, **Speed Up**, **Speed Down** and **Toggle
  Direction Button Link** - bind a keypad button here. A press runs the action
  once; the keypad LED follows the fan in the colors from
  [Button Links](#button-links).

## Actions

- **Request State** - asks the device for its state now.

The Lua commands `On` and `Off` can also be run from programming.

# <span style="color:#660066">Support</span>

If you have any questions or issues integrating this driver with Control4, you
can file an issue on GitHub:

https://github.com/krishy2/control4-mqtt/issues/new

<!-- #embed-changelog -->
