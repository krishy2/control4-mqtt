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

The MQTT Light driver makes one MQTT light a native Control4 light. It uses the
Control4 light_v2 proxy, so the light works everywhere a Control4 light does:
Navigators, keypad buttons, Advanced Lighting Scenes, voice control and
programming.

The light's abilities follow from the topics you fill in. Leave a topic empty
and the light simply doesn't have that ability; fill it in and Control4 picks it
up immediately, no driver reload needed.

# <span style="color:#660066">Index</span>

<div style="font-size: small">

- [System Requirements](#system-requirements)
- [Features](#features)
- [Installer Setup](#installer-setup)
  - [Driver Installation](#driver-installation)
  - [Driver Setup](#driver-setup)
    - [Driver Properties](#driver-properties)
      - [Driver Settings](#driver-settings)
      - [Availability Settings](#availability-settings)
      - [Light Settings](#light-settings)
      - [On/Off](#onoff)
      - [Dimmer](#dimmer)
      - [Color Temperature](#color-temperature)
      - [Color](#color)
      - [White Channel](#white-channel)
      - [Transition](#transition)
  - [Example: Tasmota](#example-tasmota)
  - [Example: Shelly](#example-shelly)
  - [Example: Zigbee2MQTT](#example-zigbee2mqtt)
  - [How the Light Behaves](#how-the-light-behaves)
  - [Connections](#connections)
  - [Programming](#programming)
- [Support](#support)
- [Changelog](#changelog)

</div>

# <span style="color:#660066">System Requirements</span>

- Control4 OS 3.3+
- MQTT Broker driver installed and connected

# <span style="color:#660066">Features</span>

| Ability           | Turned on by                                           | In Control4                             |
| ----------------- | ------------------------------------------------------ | --------------------------------------- |
| **On/Off**        | always                                                 | Switch                                  |
| **Dimmer**        | a brightness topic (or a color format with brightness) | Dimmer with ramps, click and hold rates |
| **Color Temp**    | a color temperature topic                              | Tunable white within your min/max       |
| **Color**         | a color topic                                          | Full color picker                       |
| **White Channel** | a white topic (RGBW lights)                            | A fixed color temperature preset        |
| **Transition**    | a transition topic                                     | Fades run on the device                 |

- **Three payload styles** - separate plain topics per ability (Tasmota,
  ESPHome), a single JSON state and command topic (Zigbee2MQTT, Home Assistant
  JSON schema), or Shelly Gen2+ RPC (Plus, Pro, Gen3, Gen4)
- **Discovery** - pick a Tasmota or Shelly output from a list and every setting
  is filled in
- **Shared state topics** - several abilities can read from the same topic with
  their own JSONPath (e.g. Tasmota's `stat/<topic>/RESULT`)
- **Color formats** - RGB, Hex (with or without `#`, including Tasmota's extra
  white channels), HSB, HS and CIE xy
- **Keypad support** - top, bottom and toggle buttons with click and
  press-and-hold dimming
- **Ramps without device support** - when the light has no transition topic, the
  driver steps the brightness itself so holds and slow fades still work
- **Availability** - an optional availability topic marks the light offline in
  Control4

# <span style="color:#660066">Installer Setup</span>

## Driver Installation

1. Install the MQTT Broker driver and connect it to your broker (see its
   documentation).
1. Install `cp_mqtt_light.c4z` and add one **MQTT Light** driver per light. It
   connects itself to the MQTT Broker driver, so there is nothing to bind in the
   Connections tab. (A binding you made by hand is left as it is.)
1. Fill in the topics for the abilities your light has.

## Driver Setup

### Driver Properties

#### Driver Settings

##### Driver Status (read-only)

Displays the current status of the driver and broker connection.

##### Driver Version (read-only)

Displays the current version of the driver.

##### Log Level \[ Fatal | Error | Warning | **_Info_** | Debug | Trace | Ultra \]

Sets the logging level. Default is `Info`.

##### Log Mode \[ **_Off_** | Print | Log | Print and Log \]

Sets the logging mode. Logging turns itself off after 3 hours.

#### Availability Settings

Optional. When set, the light shows as offline in Control4 while the device
reports it is unavailable (for example Tasmota's `tele/<topic>/LWT` with
`Online` / `Offline`, or Zigbee2MQTT's `<device>/availability`).

##### Availability Topic

Topic to subscribe to for availability.

##### Availability Topic Value (read-only)

The last payload received on the availability topic.

##### Availability Value Path

JSONPath to the availability value when the payload is JSON (e.g. `$.state`).

##### Availability Value Path Result (read-only)

The value extracted with the path.

##### Availability Status (read-only)

`Available` or `Unavailable`.

##### Payload Available / Payload Not Available

Values meaning available and unavailable. If only one is set, any other value
means the opposite.

#### Light Settings

##### Discovered Device

The easiest way to set up a Tasmota or Shelly light. The list shows every light
and relay the MQTT Broker driver has found, for example
`Kitchen [tasmota_A1B2C3] RGBCCT light` or
`Living [shellyplusrgbwpm-a0a3b3c4d5e6] RGBW light`. Picking one fills in every
setting below. For Tasmota: topics, value paths, `POWER<n>`, dimmer scale, color
temperature range, color format, state request and Online/Offline. For Shelly:
[Payload Mode](#payload-mode--separate-topics--json--shelly-gen2-)
`Shelly (Gen2+)`, the topic prefix and output, color temperature range, state
request and Online/Offline.

Picking a device also renames the light in Composer and Navigator.

- Tasmota: a bulb gets its DeviceName (`Hall Lamp`); an output of a device with
  several gets its own FriendlyName, or the DeviceName and the output
  (`Kitchen RGBCCT light`). Tasmota's default names (`Tasmota`, `Tasmota2`, ...)
  are skipped.
- Shelly: the output's name when it has one, otherwise the device name (with the
  output when the device has several, `Kitchen Dimmer 2`), otherwise the device
  ID.

This happens only when you pick a device, so a name you change afterwards stays.

The light keeps following the device: if its topic or setup changes, the
settings are updated. Choose `(Manual)` to stop following and keep the settings
as they are, for example after editing them by hand.

Tasmota announces itself when it connects to the broker, as long as discovery is
on (`SetOption19 0`, the default). Shelly devices are asked by the MQTT Broker
driver when they connect; see its documentation for the Shelly MQTT settings. A
device that does not appear in the list is not set up for discovery or is not
connected yet.

##### Device Notes (read-only)

Shown when the chosen device has a setting that keeps this light from working
well, for example Tasmota's `SetOption4 1`, with what to change.

##### Capabilities (read-only)

The abilities the light has right now, for example
`On/Off, Dimmer, Color Temp (2000-6500K), Color`.

##### Light State (read-only)

The state reported to Control4, for example `On 45% 2700K`.

##### Payload Mode \[ **_Separate Topics_** | JSON | Shelly (Gen2+) \]

- **Separate Topics** - each ability has its own state and command topic with
  plain values. Use this for Tasmota and ESPHome.
- **JSON** - one state topic and one command topic carrying a JSON object. Each
  ability is turned on by filling in its **Key**. Use this for Zigbee2MQTT.
- **Shelly (Gen2+)** - one output of a Shelly Plus, Pro, Gen3 or Gen4 device,
  controlled over Shelly's RPC. Only
  [Shelly Topic Prefix and Shelly Component](#shelly-topic-prefix--shelly-component-shelly-mode)
  are needed; the output type decides the abilities and the topic settings below
  are not used.

##### Shelly Topic Prefix / Shelly Component (Shelly mode)

The device's MQTT topic prefix (its device ID unless changed, for example
`shellyplus1pm-a8032ab12345`) and the output: `light:0` (dimmer), `cct:0`
(tunable white), `rgb:0`, `rgbw:0` or `switch:0` (relay, on/off). The number is
the output, counting from 0.

| Output     | Abilities in Control4                                  |
| ---------- | ------------------------------------------------------ |
| `switch:N` | On/Off                                                 |
| `light:N`  | Dimmer                                                 |
| `cct:N`    | Dimmer, Color Temp (within Color Temp Min/Max)         |
| `rgb:N`    | Dimmer, Color                                          |
| `rgbw:N`   | Dimmer, Color, White Channel (at **White Color Temp**) |

Dimmers, CCT and color outputs fade on the device. An RGBW output shows color
with the white channel off, or white with the color off.

##### JSON State Topic / JSON Command Topic (JSON mode)

For example `zigbee2mqtt/Kitchen` and `zigbee2mqtt/Kitchen/set`.

##### State Request Topic / State Request Payload

Optional. A message that asks the device for its full state. It is sent when the
broker connects and whenever the device comes back online (see
[Availability Settings](#availability-settings)), so the light shows the right
state after a controller restart instead of unknown. For Tasmota use
`cmnd/<topic>/STATE` with an empty payload: the answer arrives on
`stat/<topic>/RESULT`.

##### Optimistic \[ **_Auto_** | Yes | No \]

Whether Control4 shows the new state as soon as a command is sent, or waits for
the device to report it. `Auto` waits when any state topic is set.

##### QoS \[ **_0_** | 1 | 2 \] / Retain \[ Yes | **_No_** \]

MQTT quality of service and whether commands are retained on the broker.

#### On/Off

##### Power State Topic / Power Value Path / Power Command Topic

Topic reporting on/off, an optional JSONPath into it, and the topic to send
on/off to. If a light has no power command topic, it is turned off with
brightness 0.

##### State Key (JSON mode)

Key holding the on/off state. Default `state`.

##### State On / State Off

Values meaning on and off. If only one is set, any other value means the
opposite. Defaults `ON` / `OFF`.

##### Payload On / Payload Off

Values sent to turn the light on and off. Defaults `ON` / `OFF`.

#### Dimmer

##### Brightness State Topic / Brightness Value Path / Brightness Command Topic

Filling in a brightness topic makes the light a dimmer.

##### Brightness Key (JSON mode)

For example `brightness`.

##### Brightness Scale Max

Device value for 100%: `100` for Tasmota, `254` for Zigbee2MQTT, `255` for many
others.

#### Color Temperature

##### Color Temp State Topic / Color Temp Value Path / Color Temp Command Topic

Filling in a color temperature topic adds tunable white.

##### Color Temp Key (JSON mode)

For example `color_temp`.

##### Color Temp Unit \[ **_Mireds_** | Kelvin \]

Tasmota and Zigbee use mireds (153-500 is 6500K-2000K).

##### Color Temp Min / Color Temp Max

Warmest and coolest temperature the light supports, in Kelvin. Control4 keeps
its sliders and presets inside this range.

#### Color

##### Color State Topic / Color Value Path / Color Command Topic

Filling in a color topic adds full color.

##### Color Key (JSON mode)

For example `color`.

##### Color Format

| Format            | Example         | Notes                                                          |
| ----------------- | --------------- | -------------------------------------------------------------- |
| **RGB (r,g,b)**   | `255,128,0`     |                                                                |
| **Hex (RRGGBB)**  | `FF8000`        | Default. Also reads Tasmota RGBW/RGBCCT values like `FF800000` |
| **Hex (#RRGGBB)** | `#FF8000`       |                                                                |
| **HSB (h,s,b)**   | `30,100,80`     | Tasmota `HSBColor`; brightness is included                     |
| **HS (h,s)**      | `30,100`        |                                                                |
| **XY (x,y)**      | `0.5267,0.4133` |                                                                |

State values are read in either RGB or Hex spelling regardless of which one you
pick.

##### JSON Color Format \[ **_XY {x,y}_** | RGB {r,g,b} | HS {hue,saturation} \] (JSON mode)

The shape of the color object sent. State is read in any of these shapes.

##### Color Includes Brightness \[ **_Yes_** | No \]

For RGB and Hex. `Yes` scales the color to the current brightness (red at 50% is
`800000`), which is what Tasmota expects and lets an RGB-only light dim. `No`
always sends full-intensity color.

#### White Channel

For RGBW lights with a separate white channel.

##### White State Topic / White Value Path / White Command Topic / White Key

When the light has no color temperature topic, the white channel shows up in
Control4 as a fixed color temperature: choosing it turns the white channel on at
the light's brightness.

##### White Scale Max

Device value for 100% white.

##### White Color Temp

Color temperature of the white LEDs in Kelvin. Default `4000`.

#### Transition

##### Transition Command Topic / Transition Key

Filling this in lets the device fade by itself. The fade time is sent before
each command (or in the same JSON object). Without it, the driver steps
brightness for ramps and keypad holds.

##### Transition Unit \[ **_Seconds_** | Tenths of a Second | Milliseconds | Tasmota Speed \]

`Tasmota Speed` sends Tasmota's `Speed` value (1-40 half-seconds). Enable fading
on the device once with `Fade 1`.

## Example: Tasmota

The quickest way is the [Discovered Device](#discovered-device) list. To set it
up by hand, for a Tasmota bulb with topic `kitchen`:

| Property                 | Value                 |
| ------------------------ | --------------------- |
| Payload Mode             | Separate Topics       |
| State Request Topic      | `cmnd/kitchen/STATE`  |
| Power State Topic        | `stat/kitchen/RESULT` |
| Power Value Path         | `$.POWER`             |
| Power Command Topic      | `cmnd/kitchen/POWER`  |
| Brightness State Topic   | `stat/kitchen/RESULT` |
| Brightness Value Path    | `$.Dimmer`            |
| Brightness Command Topic | `cmnd/kitchen/Dimmer` |
| Color Temp State Topic   | `stat/kitchen/RESULT` |
| Color Temp Value Path    | `$.CT`                |
| Color Temp Command Topic | `cmnd/kitchen/CT`     |
| Color State Topic        | `stat/kitchen/RESULT` |
| Color Value Path         | `$.Color`             |
| Color Command Topic      | `cmnd/kitchen/Color`  |
| Color Format             | Hex (RRGGBB)          |
| Availability Topic       | `tele/kitchen/LWT`    |
| Payload Available        | `Online`              |
| Payload Not Available    | `Offline`             |

Leave out the color temperature rows for an RGB bulb and the color rows for a
tunable white bulb. For an RGBW strip add **White Command Topic**
`cmnd/kitchen/White` (state from `stat/kitchen/RESULT`, path `$.White`).

Tasmota publishes `stat/<topic>/RESULT` whenever the light changes, including
from its own buttons, and as the answer to the state request. Reading every
ability from `RESULT` means one subscription covers them all.

With the MQTT Broker driver in **Built-in** mode, set the Tasmota's MQTT Host to
the controller's IP address and its Port to the broker's **Listen Port**
(default `3883`).

### Tasmota with more than one load

On a Tasmota with several relays, or a relay and a light, each load has an
index: `POWER1`, `POWER2`, and so on. Plain `POWER` only fits single-load
devices. Use the light's index in both the command topic and the value path, for
example for a light on the second load:

| Property            | Value                 |
| ------------------- | --------------------- |
| Power State Topic   | `stat/kitchen/RESULT` |
| Power Value Path    | `$.POWER2`            |
| Power Command Topic | `cmnd/kitchen/POWER2` |

Check the Tasmota console: `stat/<topic>/RESULT` shows which `POWER<n>` changes
when the light is switched.

## Example: Shelly

The quickest way is the [Discovered Device](#discovered-device) list. By hand,
for the first dimmer of a Shelly Pro Dimmer 2PM with the default prefix:

| Property              | Value                                                                                                        |
| --------------------- | ------------------------------------------------------------------------------------------------------------ |
| Payload Mode          | Shelly (Gen2+)                                                                                               |
| Shelly Topic Prefix   | `shellyprodm2pm-aabbccddeeff`                                                                                |
| Shelly Component      | `light:0`                                                                                                    |
| State Request Topic   | `shellyprodm2pm-aabbccddeeff/rpc`                                                                            |
| State Request Payload | `{"id":1,"src":"control4/shellyprodm2pm-aabbccddeeff/light_0","method":"Light.GetStatus","params":{"id":0}}` |
| Availability Topic    | `shellyprodm2pm-aabbccddeeff/online`                                                                         |
| Payload Available     | `true`                                                                                                       |
| Payload Not Available | `false`                                                                                                      |

The light sends `Light.Set` (or `CCT.Set`, `RGB.Set`, `RGBW.Set`, `Switch.Set`)
to `<prefix>/rpc`, and follows the device through the `NotifyStatus` messages on
`<prefix>/events/rpc` and the answers to its state request on
`control4/<prefix>/<output>/rpc`.

## Example: Zigbee2MQTT

For a Zigbee2MQTT bulb named `Kitchen`:

| Property             | Value                     |
| -------------------- | ------------------------- |
| Payload Mode         | JSON                      |
| JSON State Topic     | `zigbee2mqtt/Kitchen`     |
| JSON Command Topic   | `zigbee2mqtt/Kitchen/set` |
| State Key            | `state`                   |
| Brightness Key       | `brightness`              |
| Brightness Scale Max | `254`                     |
| Color Temp Key       | `color_temp`              |
| Color Key            | `color`                   |
| JSON Color Format    | XY {x,y}                  |
| Transition Key       | `transition`              |

Zigbee2MQTT's `color_mode` field tells the driver whether the bulb is in color
or color temperature mode.

## How the Light Behaves

- **Color while off** - choosing a color while the light is off does not turn it
  on; the color is used the next time the light turns on.
- **Default On color** - when the light turns on without a color, it uses the
  Default On color preset (and dims toward the Dim color below the On level)
  once Control4 has sent those presets to the driver.
- **Brightness and color together** - a brightness and a color command that
  arrive together are sent as one change (one JSON message in JSON mode).
- **Keypad holds** - press-and-hold ramps toward full or off and stops where you
  let go. With a transition topic the device fades; without one the driver steps
  the brightness.
- **Ramps and scenes** - Advanced Lighting Scenes are supported, including
  stopping a ramping scene.

## Connections

- **MQTT Broker** - binds to the MQTT Broker driver automatically.
- **Light** - the light_v2 proxy. Keypad buttons bind to the proxy's Top, Bottom
  and Toggle button links as with any Control4 light.

### Programming

Use the standard Control4 light events, conditionals and commands on the light.

**Events:**

- **Device Available** / **Device Unavailable** - when an availability topic is
  set

**Conditionals:**

- **Device Available** - whether the device is available

# <span style="color:#660066">Support</span>

If you have any questions or issues integrating this driver with Control4, you
can file an issue on GitHub:

https://github.com/krishy2/control4-mqtt/issues/new

<!-- #embed-changelog -->
