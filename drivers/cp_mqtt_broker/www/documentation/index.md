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

The MQTT driver suite consists of six drivers:

| Driver              | Direction     | Purpose                                                                                            |
| ------------------- | ------------- | -------------------------------------------------------------------------------------------------- |
| **MQTT Broker**     | N/A           | The MQTT connection: an external broker, or the built-in one                                       |
| **MQTT General**    | Inbound       | External MQTT device -> Control4 (create relays, contacts, buttons, variables from MQTT topics)    |
| **MQTT Light**      | Bidirectional | One MQTT light as a native Control4 light (on/off, dimmer, color temperature, color)               |
| **MQTT Shutter**    | Bidirectional | One MQTT shutter or blind as a native Control4 blind (position, open/close/stop, slats)            |
| **MQTT Thermostat** | Bidirectional | One MQTT thermostat as a native Control4 thermostat (temperature, setpoints, modes, fan, humidity) |
| **MQTT Web View**   | Inbound       | MQTT values (air-quality sensors, ...) on a web view for touch screens and the mobile apps         |

**Typical Setup:**

1. Add the **MQTT Broker** driver and choose its mode
1. Add one **MQTT Light** per MQTT light (Tasmota, Zigbee2MQTT, ESPHome, ...)
1. Add one **MQTT Shutter** per shutter or blind (Tasmota, Shelly, Zigbee2MQTT,
   ...)
1. Add one **MQTT Thermostat** per thermostat (Tasmota, TuyaMCU, ...)
1. Add **MQTT General** for other MQTT devices: relays, contacts, buttons,
   sensors
1. Add **MQTT Web View** to show an MQTT device's values on touch screens and in
   the mobile apps

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
   the `cp_mqtt_broker.c4z`, `cp_mqtt_general.c4z`, `cp_mqtt_light.c4z`,
   `cp_mqtt_shutter.c4z`, `cp_mqtt_thermostat.c4z` and `cp_mqtt_webview.c4z`
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

<!-- #embed-changelog -->
