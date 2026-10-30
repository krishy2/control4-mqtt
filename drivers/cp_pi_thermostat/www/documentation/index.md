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

<img alt="PI Thermostat" src="./images/header.png" width="500"/>

______________________________________________________________________

# <span style="color:#660066">Overview</span>

> DISCLAIMER: This software is neither affiliated with nor endorsed by Control4.

The PI Thermostat driver is a native Control4 thermostat that does the control
itself. It reads the room temperature from a temperature sensor bound in
Connections, keeps the heat and cool setpoints in the driver, and opens and
closes one or two water valves (a heat valve and a cool valve) through Control4
relays.

- More than **5 °C** from the setpoint, the valve is fully open (full heating or
  full cooling).
- Closer than that, a **PI controller** sets how long the valve is open in each
  cycle (time-proportional control), starting where full power left off.
- The PI gains are **learned**: an auto-tune you start from Extras, then
  continuous adjustment from how the room responds.

The driver does not use MQTT and does not connect to the MQTT Broker. It is part
of the same driver suite.

# <span style="color:#660066">Index</span>

<div style="font-size: small">

- [System Requirements](#system-requirements)
- [Installer Setup](#installer-setup)
  - [Driver Installation](#driver-installation)
  - [Connections](#connections)
  - [Driver Properties](#driver-properties)
  - [Actions](#actions)
- [User Settings (Extras)](#user-settings-extras)
- [How It Controls](#how-it-controls)
- [Message](#message)
- [Scheduling](#scheduling)
- [Programming](#programming)
- [Support](#support)
- [Changelog](#changelog)

</div>

# <span style="color:#660066">System Requirements</span>

- Control4 OS 3.3+
- A temperature sensor with a temperature output connection (a Control4
  temperature sensor, the MQTT General driver's temperature binding, another
  thermostat's Temperature output, ...)
- One or two relays (a Control4 I/O extender, a relay module driver, ...) wired
  to the valve actuators

# <span style="color:#660066">Installer Setup</span>

## Driver Installation

1. Download the latest release from
   [GitHub](https://github.com/krishy2/control4-mqtt/releases/latest).
1. Install `cp_pi_thermostat.c4z` with Composer Pro (Driver → Add or Update
   Driver).
1. Add **PI Thermostat** to the room.
1. Bind its connections (below) and set the valve properties.

If the MQTT Broker driver is in the project, its Update Drivers action and
automatic updates keep this driver up to date as well.

## Connections

| Connection             | Bind to                                                     |
| ---------------------- | ----------------------------------------------------------- |
| **Temperature Sensor** | The sensor's temperature output (class `TEMPERATURE_VALUE`) |
| **Heat Valve**         | The relay of the heat valve (class `RELAY`)                 |
| **Cool Valve**         | The relay of the cool valve (class `RELAY`)                 |

With one valve: **Heat Only** uses Heat Valve, **Cool Only** uses Cool Valve,
and **Changeover** drives whichever of the two is bound (bind one).

## Driver Properties

### Driver Settings

- **Driver Status** (read-only)
- **Driver Version** (read-only)
- **Log Level** / **Log Mode** - logging; the log mode switches itself off after
  3 hours.

### Valves

- **Valve Count** - `2 Valves` (heat and cool; modes Off, Heat, Cool, Auto) or
  `1 Valve`.
- **Single Valve Use** (1 valve only):
  - `Heat Only` - modes Off and Heat.
  - `Cool Only` - modes Off and Cool.
  - `Changeover` - one valve on a 2-pipe system that carries hot or cold water
    by season. The HVAC mode says which: Heat or Cool (no Auto).
- **Valve Opens When Relay Is** - `Closed` (default: the relay energizes a
  normally closed valve) or `Opened`.

### Setpoints

- **Setpoint Minimum** / **Setpoint Maximum** - °C, for both setpoints.
- **Heat Cool Deadband** - the smallest gap (°C) between the heat and cool
  setpoints. Moving one setpoint into the other pushes the other one along.

### PI Gains

- **Heating Kp** / **Cooling Kp** - % of valve opening per °C of deviation.
- **Heating Ti** / **Cooling Ti** - integral time in minutes.

The driver keeps these up to date as it tunes and learns. Typing a value sets
it; learning then continues from there.

### Status (read-only)

- **Controller State** - Off, Idle, Full power, PI control, Auto-tune, or No
  temperature reading.
- **Temperature** - the last reading.
- **Controller Output** - 0-100 %.
- **Heat Valve** / **Cool Valve** - open or closed, and what the relay reported.
- **Last Learning** - the last auto-tune or gain adjustment.

## Actions

- **Start Auto-Tune Heating** / **Start Auto-Tune Cooling** - same as the Extras
  buttons.
- **Stop Auto-Tune**
- **Reset Learned Gains** - back to Kp 30 %/°C, Ti 30 min.
- **Request Temperature** - asks the bound sensor for its value.

# <span style="color:#660066">User Settings (Extras)</span>

The user settings are in the thermostat's **Extras** on touch screens and in the
app:

| Setting                           | Default | Meaning                                                 |
| --------------------------------- | ------- | ------------------------------------------------------- |
| Response                          | Normal  | Slow (Kp x 0.6), Normal, Fast (Kp x 1.5)                |
| Self-Learning                     | On      | Adjust the gains from how the room responds             |
| Full Power Above                  | 5 °C    | Deviation from the setpoint that opens the valve fully  |
| Back to PI Control                | 0.5 °C  | PI takes over again this far below the full-power value |
| Valve Cycle Time                  | 10 min  | One open/closed cycle of time-proportional control      |
| Minimum Valve Open/Closed Time    | 2 min   | Shortest time a valve stays open or closed              |
| Close Valves If No Reading For    | 15 min  | Sensor timeout                                          |
| Auto-Tune Heating / Cooling, Stop |         | Start or stop an auto-tune                              |
| Reset Learned Gains               |         | Back to the default gains                               |

Every setting is saved on the controller and kept across restarts and driver
updates.

# <span style="color:#660066">How It Controls</span>

Every 10 seconds, and whenever the temperature, a setpoint or the mode changes:

1. **Side**: Heat mode heats, Cool mode cools. In Auto it heats below the heat
   setpoint and cools above the cool setpoint; between them the last side winds
   down to zero. The other valve is always closed.
1. **Full power**: when the room is more than **Full Power Above** (5 °C) from
   the setpoint, the valve is fully open.
1. **PI control**: once the deviation is below 5 °C minus **Back to PI Control**
   (4.5 °C), the PI controller takes over, starting from 100 % so there is no
   jump. Its integral does not wind up while the valve is fully open or closed.
1. **Valves**: the output (0-100 %) is the share of each **Valve Cycle Time**
   the valve is open: 60 % of 10 minutes is 6 minutes open, 4 closed. The
   **Minimum Valve Open/Closed Time** protects the actuators.
1. **Safety**: with no temperature reading for longer than the sensor timeout,
   or when the sensor reports itself unavailable, both valves close at once and
   the Message says so. Off closes both valves at once too. The driver asks the
   sensor for its value every 5 minutes; a sensor that only reports changes and
   does not answer requests may need a longer timeout in Extras.

## Self-learning

The heating and cooling gains are learned separately.

- **Auto-tune** (Extras → Auto-Tune Heating or Cooling) runs a relay test: the
  valve opens below the setpoint and closes above it, and after two full swings
  the driver works out the gains from their size and period (Tyreus-Luyben
  rules, gentle enough for water systems). It takes from about one hour (fan
  coils) to several hours (underfloor heating); the Message shows its progress.
  Changing to Off, a mode that does not use that side, or losing the sensor
  stops it.
- **Continuous learning** (Self-Learning on): every response to a setpoint
  change or a disturbance is watched. Overshoot or oscillation makes the gains
  gentler; a slow approach without overshoot makes them stronger, by 10-15 % at
  a time and within safe limits. When the valve was fully open most of the time
  the plant is at its capacity and nothing is changed.

# <span style="color:#660066">Message</span>

The thermostat's message (shown in Navigators) tells what the controller is
doing, for example:

```
Full heating: 6.2 °C below setpoint
Kp 30 %/°C, Ti 30 min (learned, 3 adjustments)
Heat valve open, cool valve closed
```

```
PI heating: 42 %
Kp 30 %/°C, Ti 30 min (auto-tuned)
P 25 % + I 17 %, deviation 0.8 °C
Heat valve open, cool valve closed
```

# <span style="color:#660066">Scheduling</span>

The driver supports the thermostat's own **preset scheduling**. Create presets
(HVAC mode, heat and cool setpoints) and schedule them in the thermostat's
Schedule on a touch screen or in the app. When a preset runs, the driver applies
its mode and setpoints and shows its name.

# <span style="color:#660066">Programming</span>

**Events**: Full Power Started, Full Power Ended, Sensor Lost, Sensor Restored,
Auto-Tune Finished, Auto-Tune Failed, Gains Learned.

**Variables**: `CONTROLLER_STATE`, `CONTROLLER_OUTPUT` (0-100),
`HEAT_VALVE_OPEN`, `COOL_VALVE_OPEN`. The thermostat proxy's own variables and
commands (setpoints, HVAC mode, presets) work as for any Control4 thermostat.

# <span style="color:#660066">Support</span>

If you have any questions or issues integrating this driver with Control4, you
can file an issue on GitHub:

https://github.com/krishy2/control4-mqtt/issues/new

<!-- #embed-changelog -->
