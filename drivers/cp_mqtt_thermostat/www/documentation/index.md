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

The MQTT Thermostat driver makes one MQTT thermostat a native Control4
thermostat: current temperature, heat and cool setpoints, HVAC mode and state,
fan mode and humidity, in Navigators, scenes and programming. It works with the
Tasmota Thermostat driver, TuyaMCU thermostats running Tasmota, and any device
with MQTT topics.

Each ability is turned on by filling in its topic. Leave a topic empty and the
thermostat does not have that ability.

# <span style="color:#660066">Index</span>

<div style="font-size: small">

- [System Requirements](#system-requirements)
- [Installer Setup](#installer-setup)
  - [Driver Installation](#driver-installation)
  - [Driver Properties](#driver-properties)
  - [Example: Tasmota Thermostat driver](#example-tasmota-thermostat-driver)
  - [Example: TuyaMCU thermostat](#example-tuyamcu-thermostat)
  - [Example: heat and cool with fan](#example-heat-and-cool-with-fan)
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
1. Install `cp_mqtt_thermostat.c4z` and add one **MQTT Thermostat** per
   thermostat. It connects itself to the MQTT Broker driver.
1. Fill in the topics for the abilities the thermostat has.

## Driver Properties

### Driver Settings and Availability Settings

As in the other MQTT drivers. With an availability topic, Control4 shows the
thermostat as disconnected while the device is offline, and the driver asks it
for its state when it comes back.

### Thermostat Settings

- **Capabilities** / **Thermostat State** (read-only) - what the thermostat can
  do with the current settings, and its state
  (`Heat, Heating, 20.7°C, setpoint 21.5°C`).
- **Device Temperature Scale** \[ **_Celsius_** | Fahrenheit \] - the scale the
  device reports and takes temperatures in. Control4 shows each user their own
  scale.
- **Temperature Multiplier** - the device value for one degree: `10` for devices
  that send `215` for 21.5 °C (most TuyaMCU thermostats), `1` otherwise. It
  applies to the temperature and both setpoints.
- **Setpoint Min** / **Setpoint Max** / **Setpoint Step** - in the device scale
  (default 5-35 °C in 0.5 steps, or 40-95 °F in 1 steps).
- **State Request Topic** / **State Request Payload** - optional message that
  makes the device report its state, sent when the broker connects and when the
  device comes online. The **Request State** action sends it too.
- **Optimistic** \[ **_Auto_** | Yes | No \] - assume a command worked. Auto
  does so for abilities without a state topic.
- **QoS**, **Retain** - for commands.

### Abilities

Each ability has a **State Topic** and **Value Path** (JSONPath into the
payload, empty for a plain value), and, where Control4 can change it, a
**Command Topic** and **Command Payload**. The payload is a template: `{value}`
is replaced by the value (empty means just the value), for example `16,{value}`
for TuyaMCU's `TuyaSend2`.

| Ability           | Turned on by                | In Control4                                       |
| ----------------- | --------------------------- | ------------------------------------------------- |
| **Temperature**   | Temperature State Topic     | Current temperature                               |
| **Humidity**      | Humidity State Topic        | Current humidity                                  |
| **Heat Setpoint** | Heat Setpoint Command Topic | Heat setpoint                                     |
| **Cool Setpoint** | Cool Setpoint Command Topic | Cool setpoint                                     |
| **HVAC Mode**     | Mode Command Topic          | Mode selection (the modes in Mode Values)         |
| **Power**         | Power Command Topic         | Mode Off switches the device off                  |
| **HVAC State**    | HVAC State Topic            | Heating / Cooling / Idle / ...                    |
| **Fan**           | Fan Mode Command Topic      | Fan mode selection (the modes in Fan Mode Values) |

With both setpoints, Control4 also offers Auto when the modes include it. When
the heat and cool setpoints use the **same** command topic, the thermostat is a
single-setpoint one: Control4 shows one setpoint and the mode decides whether it
heats or cools.

#### Value maps

**Mode Values**, **HVAC State Values** and **Fan Mode Values** translate between
Control4 names and device values: `Off=0,Heat=1,Cool=2,Auto=3`. The modes listed
are the ones Control4 offers. When empty:

- modes: `off`, `heat`, `cool`, `auto`, `fan_only`, `dry`, offering Off, Heat
  and Cool for the setpoints that exist (and Auto with both);
- HVAC state: a relay state (`ON` = Heating, `OFF` = Idle), or `heating`,
  `cooling`, `idle`, `off`, `drying`, `fan`;
- fan modes: `auto`, `low`, `medium`, `high`.

#### Power

**Power State Topic**, **Power Value Path**, **Power Command Topic**, **Power
Payload On / Off** (default `ON` / `OFF`) and **Power State On / Off**. With a
power command topic, Control4 mode Off switches the device off and any other
mode switches it on first. A device that is off shows mode Off.

## Example: Tasmota Thermostat driver

For a Tasmota with the Thermostat driver (`USE_THERMOSTAT`), topic `floor`, a
DS18B20 sensor and the heating on relay 1:

| Property                    | Value                           |
| --------------------------- | ------------------------------- |
| Temperature State Topic     | `tele/floor/SENSOR`             |
| Temperature Value Path      | `$.DS18B20.Temperature`         |
| Heat Setpoint Command Topic | `cmnd/floor/TempTargetSet1`     |
| Mode Command Topic          | `cmnd/floor/ThermostatModeSet1` |
| Mode Values                 | `Off=0,Heat=1`                  |
| HVAC State Topic            | `stat/floor/RESULT`             |
| HVAC State Value Path       | `$.POWER1`                      |
| Availability Topic          | `tele/floor/LWT`                |

Add the setpoint and mode state topics from where your firmware reports them.

## Example: TuyaMCU thermostat

TuyaMCU thermostats report their data points on `tele/<topic>/RESULT` as
`{"TuyaReceived":{"DpType2Id16":215, ...}}` and take commands with
`TuyaSend<type> <dpId>,<value>`. The data point numbers differ per model; check
the Tasmota console while changing settings on the device. For example:

| Property                      | Value                        |
| ----------------------------- | ---------------------------- |
| Temperature Multiplier        | `10`                         |
| Temperature State Topic       | `tele/moes/RESULT`           |
| Temperature Value Path        | `$.TuyaReceived.DpType2Id24` |
| Heat Setpoint State Topic     | `tele/moes/RESULT`           |
| Heat Setpoint Value Path      | `$.TuyaReceived.DpType2Id16` |
| Heat Setpoint Command Topic   | `cmnd/moes/TuyaSend2`        |
| Heat Setpoint Command Payload | `16,{value}`                 |
| Power State Topic             | `tele/moes/RESULT`           |
| Power Value Path              | `$.TuyaReceived.DpType1Id1`  |
| Power Command Topic           | `cmnd/moes/TuyaSend1`        |
| Power Payload On / Off        | `1,1` / `1,0`                |
| Power State On / Off          | `1` / `0`                    |

## Example: heat and cool with fan

For a device publishing
`{"temp":22.4,"heat":20,"cool":25,"mode":"cool","fan":"low","action":"cooling"}`
on `hvac/state`: use `hvac/state` as every state topic with value paths
`$.temp`, `$.heat`, `$.cool`, `$.mode`, `$.fan`, `$.action`, and its command
topics (`hvac/heat/set`, ...). The default value maps match these values.

## Actions

- **Request State** - asks the device for its state now.

# <span style="color:#660066">Support</span>

If you have any questions or issues integrating this driver with Control4, you
can file an issue on GitHub:

https://github.com/krishy2/control4-mqtt/issues/new

<!-- #embed-changelog -->
