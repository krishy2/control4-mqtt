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
      - [Button Links](#button-links)
  - [Example: Tasmota](#example-tasmota)
  - [Example: Shelly](#example-shelly)
  - [Example: Zigbee2MQTT](#example-zigbee2mqtt)
  - [Example: Tasmota Zigbee bridge](#example-tasmota-zigbee-bridge)
  - [Zigbee Troubleshooting](#zigbee-troubleshooting)
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

| Ability           | Turned on by                                            | In Control4                             |
| ----------------- | ------------------------------------------------------- | --------------------------------------- |
| **On/Off**        | always                                                  | Switch                                  |
| **Dimmer**        | a brightness topic (or a color format with brightness)  | Dimmer with ramps, click and hold rates |
| **Color Temp**    | a color temperature topic                               | Tunable white within your min/max       |
| **Color**         | a color topic                                           | Full color picker                       |
| **White Channel** | a white topic (RGBW lights)                             | A fixed color temperature preset        |
| **Transition**    | a transition topic, or command payloads with `{time16}` | Fades run on the device                 |

- **Three payload styles** - separate plain topics per ability (Tasmota,
  ESPHome), a single JSON state and command topic (Zigbee2MQTT, Home Assistant
  JSON schema), or Shelly Gen2+ RPC (Plus, Pro, Gen3, Gen4)
- **Discovery** - pick a Tasmota or Shelly output, or a Zigbee light behind a
  Tasmota Zigbee gateway, from a list and every setting is filled in
- **Shared state topics** - several abilities can read from the same topic with
  their own JSONPath (e.g. Tasmota's `stat/<topic>/RESULT`)
- **Color formats** - RGB, Hex (with or without `#`, including Tasmota's extra
  white channels), HSB, HS and CIE xy
- **Advanced Lighting Scenes** - full support: several steps per light with a
  **Delay**, fade times, flash scenes, and ramping a scene up and down
- **On modes and Daylight** - Default On and Previous On brightness; On color,
  Previous color and Dim-To-Warm; follows the Daylight Agent through the day
- **Keypad support** - top, bottom and toggle buttons with click and
  press-and-hold dimming
- **Ramps without device support** - when the light cannot fade by itself, the
  driver steps the brightness (or, with Fade: Jump to Target, sends the final
  level) so holds and slow fades still work
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
request and Online/Offline. For a Zigbee light behind a Tasmota Zigbee gateway
(`spot1 [zigbee] White light`): the gateway's `ZbSend` topic with a
[Command Payload](#command-payload-power-brightness-color-temp-color-white) per
ability, the state topic and value paths, scales and Online/Offline of the
gateway.

Picking a device also renames the light in Composer and Navigator.

- Tasmota: a bulb gets its DeviceName (`Hall Lamp`); an output of a device with
  several gets its own FriendlyName, or the DeviceName and the output
  (`Kitchen RGBCCT light`). Tasmota's default names (`Tasmota`, `Tasmota2`, ...)
  are skipped.
- Shelly: the output's name when it has one, otherwise the device name (with the
  output when the device has several, `Kitchen Dimmer 2`), otherwise the device
  ID.
- Zigbee: the device's name on the gateway (`ZbName`), otherwise its model and
  address.

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

##### Zigbee Light Type

Shown for a Zigbee light behind a Tasmota gateway: **Auto** (default), Switch,
Dimmer or White (CT). Auto uses what the broker detected from the gateway; the
others fill in the fields for that kind of light whatever the gateway says, for
a bulb the gateway has no light type for. Picking another device sets it back to
Auto. Also run `ZbLight <light>,<type>` on the gateway (2 for White): Tasmota
uses the type to read values back from the light, and Device Notes say when the
two differ.

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

##### Command Payload (Power, Brightness, Color Temp, Color, White)

Optional payload template for that ability's commands, shown once its command
topic is set. Empty sends the value itself. Use it when the value has to sit
inside a bigger message, as with Tasmota's Zigbee `ZbSend`; see
[Example: Tasmota Zigbee bridge](#example-tasmota-zigbee-bridge).

| Placeholder | Replaced by                                                        |
| ----------- | ------------------------------------------------------------------ |
| `{value}`   | the value (Payload On or Payload Off for power)                    |
| `{hex8}`    | the value as one hex byte (`51` → `33`)                            |
| `{hex16}`   | the value as two hex bytes, low byte first (`454` → `C601`)        |
| `{time16}`  | the fade time in tenths of a second, two hex bytes, low byte first |

A template with `{time16}` makes the light fade by itself, like a transition
topic: each command carries Control4's fade time.

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
each command (or in the same JSON object). Command payloads with `{time16}` do
the same without a transition topic (Zigbee lights behind a Tasmota gateway);
leave this empty for them. Without either, fades follow the
[Fade](#fade--stepped--jump-to-target-) setting.

##### Transition Unit \[ **_Seconds_** | Tenths of a Second | Milliseconds | Tasmota Speed \]

`Tasmota Speed` sends Tasmota's `Speed` value (1-40 half-seconds). Enable fading
on the device once with `Fade 1`.

##### Fade \[ **_Stepped_** | Jump to Target \]

For a light that cannot fade by itself (no transition topic and no `{time16}`
command payloads); shown only then. **Stepped** sends a fade as brightness
steps, at most every 250 ms (40 at most). **Jump to Target** sends one command
with the final brightness and leaves the softening to the light; Control4 still
shows the fade time.

Picking a Zigbee light sets Jump to Target. Such a light fades by itself (the
fade time is in its commands), so the setting is hidden; it is kept for the wait
below, because the gateway reports levels it read during the fade.

With Jump to Target, the driver also waits for the light to get there: for 2
seconds (plus the fade time) after a command, reports of another level are taken
as late ones, sent before the light arrived, and are not passed on to Control4.
A report of the commanded level, or any report after that time, counts as usual.
For a light that cannot fade by itself, keypad holds are always stepped (there
is no end level until the button is released), every 500 ms at most.

#### Button Links

The LED colors of keypad buttons bound to the
[ON, OFF and Toggle Button Links](#connections) are set like on any Control4
light: in the light's **Brightness** tab, under **Button and Button Connection
Status LED Colors**, pick the button (**Top (Ramp Up)** for ON, **Bottom (Ramp
Down)** for OFF, **Toggle**) and its **On Color** and **Off Color**. Keypads
show the On Color while the light is on and the Off Color while it is off.

Until colors are chosen, ON and Toggle are blue while the light is on and OFF is
blue while it is off. The colors are kept when the controller restarts.

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

## Example: Tasmota Zigbee bridge

These are the settings Discovered Device fills in for a Zigbee light (it names
the device by its IEEE address rather than `spot1`); they also work by hand.

A Zigbee bulb with brightness and color temperature, paired to a Tasmota Zigbee
bridge (topic `zigbee`) as `spot1` with short address `0xE53A`, and
`SetOption89 1` so each device reports on its own topic. Every command goes to
`ZbSend` with the device named in the message.

| Property                   | Value                                                 |
| -------------------------- | ----------------------------------------------------- |
| Payload Mode               | Separate Topics                                       |
| Power State Topic          | `tele/zigbee/E53A/SENSOR`                             |
| Power Value Path           | `$.ZbReceived['0xE53A'].Power`                        |
| Power Command Topic        | (empty: brightness switches the light)                |
| State On / State Off       | `1` / `0`                                             |
| Brightness State Topic     | `tele/zigbee/E53A/SENSOR`                             |
| Brightness Value Path      | `$.ZbReceived['0xE53A'].Dimmer`                       |
| Brightness Command Topic   | `cmnd/zigbee/ZbSend`                                  |
| Brightness Command Payload | `{"Device":"spot1","Send":"0008!04/{hex8}{time16}"}`  |
| Brightness Scale Max       | `254`                                                 |
| Color Temp State Topic     | `tele/zigbee/E53A/SENSOR`                             |
| Color Temp Value Path      | `$.ZbReceived['0xE53A'].CT`                           |
| Color Temp Command Topic   | `cmnd/zigbee/ZbSend`                                  |
| Color Temp Command Payload | `{"Device":"spot1","Send":"0300!0A/{hex16}{time16}"}` |
| Color Temp Unit            | Mireds                                                |
| Color Temp Min / Max       | the bulb's range in Kelvin, e.g. 2200 / 4000          |
| Fade                       | Jump to Target                                        |

The commands are the standard Zigbee ones with a fade time: `0008!04` (Move to
Level with On/Off: level 0 turns the light off, any other level on) and
`0300!0A` (Move to Color Temperature). The bulb does Control4's fades itself,
including fading on and off. A plain switch uses
`{"Device":"spot1","Send":{"Power":{value}}}` with Payload On / Off `1` / `0`
instead. To check a bulb fades, run
`ZbSend {"Device":"spot1","Send":"0008!04/FE1E00"}` on the gateway: it should go
to full over 3 seconds.

When brightness and color temperature change together (a scene, warm dimming),
the brightness command goes first and the color temperature 250 ms later. A
two-channel bulb such as the TS0502B jumps when the color temperature command
comes first or at the same moment.

Messages without light values (for example only `LinkQuality`) are skipped. The
short address in the state topics changes if the bulb is paired again. Without
`SetOption89` every device reports on `tele/zigbee/SENSOR`; use that topic
instead, with the same Value Paths.

## Zigbee Troubleshooting

For a Zigbee light behind a Tasmota Zigbee gateway. The commands below go in the
gateway's console (its web page, **Tools > Console**); replace `spot1` with the
light's name or short address. `ZbStatus` and `ZbLight` without a type only
read.

**Check what the gateway knows about the light**

```
ZbStatus3 spot1
```

- `Config` lists what the light can do: `O01` on/off, `L01` brightness, and
  `L01.2` brightness with light type 2 (white with color temperature) set by
  `ZbLight`. A `~01.1` entry is not a light type.
- `LinkQuality` below about 20 means a weak radio link: commands can arrive late
  or not at all. A mains-powered Zigbee device between the gateway and the light
  helps.

**The light is offered as a dimmer but has color temperature**

Tasmota has no light type for it. Set it on the gateway, which the driver picks
up at once:

```
ZbLight spot1,2
```

Types: 0 on/off, 1 dimmer, 2 white with color temperature, 3 RGB, 4 RGBW, 5 RGB
with color temperature. Or set [Zigbee Light Type](#zigbee-light-type) in the
light. Then pick the device again under Discovered Device.

**Name, remove**

- `ZbName 0x372D,Kitchen_spot` names a device; the name is used for the light.
- `ZbForget spot1` removes a device that is gone; it then drops from the list.

**Check that the light fades by itself**

Each should change the light smoothly over 3 seconds:

```
ZbSend {"Device":"spot1","Send":"0008!04/FE1E00"}
ZbSend {"Device":"spot1","Send":"0008!04/201E00"}
ZbSend {"Device":"spot1","Send":"0300!0A/99001E00"}
ZbSend {"Device":"spot1","Send":"0300!0A/C6011E00"}
```

The first two set brightness (`FE` full, `20` about 12%), the last two color
temperature (`9900` 153 mireds, about 6500 K; `C601` 454 mireds, about 2200 K).
`1E00` is 30 tenths of a second, low byte first. If the light jumps instead, it
cannot fade: clear the Brightness and Color Temp Command Payloads' `{time16}`
(use `{"Device":"spot1","Send":{"Dimmer":{value}}}` and
`{"Device":"spot1","Send":{"CT":{value}}}`) and set
[Fade](#fade--stepped--jump-to-target-) to Stepped.

**A jump at the start of a scene**

When brightness and color temperature change together, the driver sends the
brightness first and the color temperature 250 ms later. With a two-channel bulb
(Tuya TS0502B) the other order, or both at the same moment, makes the light
jump. To see it on the gateway, from full brightness and cool white:

```
Backlog ZbSend {"Device":"spot1","Send":"0008!04/0D0800"}; ZbSend {"Device":"spot1","Send":"0300!0A/F4010800"}
```

is smooth, and the same two in the other order jumps.

**Seeing what the driver sends**

Set the light's **Log Level** to `5 - Debug` and **Log Mode** to `Print`: the
Lua output shows each Control4 command (`SET_BRIGHTNESS_TARGET`,
`SET_COLOR_TARGET`) and each `ZbSend` published. The gateway console shows the
same commands arriving and the light's reports (`ZbReceived`).

## How the Light Behaves

- **Color while off** - choosing a color while the light is off does not turn it
  on; the color is used the next time the light turns on.
- **On modes** - an On (Navigator, keypad, programming) goes to the level of the
  light's Brightness On Mode: its preset level, or with **Previous** the level
  the light had when it last went off. Without a color of its own it takes the
  Color On Mode's color: the preset's (On color, or the Daylight Agent's),
  **Previous** (the color it went off in), or **Fade** (Dim-To-Warm: the On
  color at the on level, warming toward the Dim color as it dims). The driver
  reads these from the proxy at start and follows every change.
- **Brightness and color together** - a brightness and a color command that
  arrive together are sent as one change (one JSON message in JSON mode).
- **Keypad holds** - press-and-hold ramps toward full or off and stops where you
  let go. A light that fades by itself fades toward full or off and gets the
  level it reached on release; otherwise the driver steps the brightness.
- **Advanced Lighting Scenes** - Control4 sends each scene to the light, and the
  light runs its steps itself: each step waits its **Delay**, then sets its
  brightness and/or color over its fade time, then the next step follows. A
  flash scene repeats its steps until it is deactivated. Ramping a scene up or
  down fades toward full or off in the color of the scene's last step, and stops
  where you let go; a scene set to ignore ramps does not ramp. Any other
  brightness command (Navigator, keypad, programming) ends the scene's later
  steps. The scenes are kept when the controller restarts.
- **Daylight Agent** - with the Daylight Agent's preset as the Color On Mode,
  the light turns on in the agent's color and follows it as the agent moves it
  through the day. It tells Control4 which preset its level and color come from;
  picking a color by hand stops the following until the next On.
- **Light groups** - the light can be a member of a Control4 Dimmer Load Group
  (a Switch Load Group only takes lights that cannot dim). A group's level, ramp
  and stop commands are carried out by each MQTT Light on its own device.
- **After updating from an earlier version** - what a light can do (load groups,
  full scene support with Delay, on modes) is kept in two places: the controller
  reads it again when it starts, but Composer keeps what the light had when it
  was added. After updating, reboot the controller and reconnect Composer. A
  light added before v2026111912 keeps working and shows Delay on the scene
  steps it already has, but Composer does not offer it in an Advanced Lighting
  Scene's Add/Remove list until it is deleted and added again. A light added
  with v2026111912 or later is offered.
- **Default Color Rate message** - Composer may show "Error setting default
  color rate from driver" (Minimum and Maximum 0.000) when it opens a light that
  has no color or color temperature when it is added. Click OK: the light works;
  only that one default cannot be edited in Composer.

## Connections

- **MQTT Broker** - binds to the MQTT Broker driver automatically.
- **Light** - the light_v2 proxy.
- **ON Button Link**, **OFF Button Link**, **Toggle Button Link** - bind a
  keypad button here in the Connections tab. A tap turns the light on, off, or
  toggles it; holding dims up (ON), down (OFF), or toward the other end
  (Toggle), and releasing stops. The keypad LED follows the light in the colors
  from [Button Links](#button-links).

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
