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

The MQTT Web View driver reads one or more MQTT topics through the MQTT Broker
driver and shows every value it receives on a web view inside Control4. JSON
payloads, such as an IKEA VINDSTYRKA air-quality sensor in Zigbee2MQTT, are
split into one tile per field.

The page is part of the driver and is served by the controller. It opens from an
Experience button, so it works on T4 and T5 touch screens and in the Control4
iOS and Android apps, at home and remotely. All data comes from the driver on
the controller; the page never connects to MQTT itself.

# <span style="color:#660066">Index</span>

<div style="font-size: small">

- [System Requirements](#system-requirements)
- [Features](#features)
- [Installer Setup](#installer-setup)
  - [Driver Installation](#driver-installation)
  - [Driver Setup](#driver-setup)
  - [Driver Properties](#driver-properties)
  - [Driver Actions](#driver-actions)
  - [Programming](#programming)
- [How the Web View Gets Its Data](#how-the-web-view-gets-its-data)
- [Support](#support)
- [Changelog](#changelog)

</div>

# <span style="color:#660066">System Requirements</span>

- Control4 OS 3.3+
- MQTT Broker driver installed and connected
- Control4 app 321.46 or later for the web view in the mobile apps

# <span style="color:#660066">Features</span>

- Any number of values from one or more topics; nested JSON is flattened
  (`sensors.pm25`, `data[1]`)
- Known readings get labels, units and rounding: PM1, PM2.5, PM10, VOC and NOx
  index, tVOC, CO₂, temperature, humidity, pressure, illuminance, battery,
  power, link quality and more
- Air-quality grading (Good, Fair, Poor, Bad) for PM2.5, PM10, VOC index, tVOC,
  CO₂, AQI, humidity and battery, on the tiles and on the navigator icon
- A Control4 variable per value, plus an `Air Quality` variable, for programming
- Hide, reorder and relabel fields from Composer
- Stale data detection
- Connects itself to the MQTT Broker driver

# <span style="color:#660066">Installer Setup</span>

## Driver Installation

1. Install `cp_mqtt_webview.c4z` with the other MQTT drivers. Keep the file
   name: the web view address is `controller://driver/cp_mqtt_webview/...`,
   which must match the driver file name.

1. In Composer's "Search" tab, search for "MQTT Web View" and add the driver to
   the room where the icon should appear. It connects to the MQTT Broker driver
   by itself.

## Driver Setup

1. Set [MQTT Topics](#mqtt-topics), for example `zigbee2mqtt/Vindstyrka`. Use
   the same topic as the MQTT General item that already reads the device.

1. In the room's **Navigator** properties, make the driver visible in the
   Experience menu you want (Comfort, Security, Listen or Watch).

1. Refresh Navigators and tap the icon to open the web view.

[`Driver Status`](#driver-status-read-only) shows `Connected` when the broker is
connected.
[`Last Payload`](#last-message--last-payload--current-values-read-only) and
`Current Values` show what has been received.

## Driver Properties

##### Driver Status (read-only)

Displays the current status of the driver.

##### Driver Version (read-only)

Displays the current version of the driver.

##### Log Level \[ Fatal | Error | Warning | **_Info_** | Debug | Trace | Ultra \]

Sets the logging level. Default is `Info`.

##### Log Mode \[ **_Off_** | Print | Log | Print and Log \]

Sets the logging mode. Default is `Off`.

##### MQTT Topics

The topics to read, separated by commas. Each topic must be written out in full;
wildcards are not used. A new message on a topic replaces all values received
earlier on that topic.

##### QoS

Subscription QoS.

##### Last Message / Last Payload / Current Values (read-only)

The last topic and time, the raw payload (first 1000 characters), and a one-line
summary of what the web view shows.

##### Title

Heading on the web view. Empty uses the driver's name.

##### Theme \[ **_Dark_** | Light | Auto \]

Auto follows the device's light or dark setting where the device supports it.

##### Field Order

Keys to show first, in order, for example `pm25,voc_index,temperature,humidity`.
Other fields follow: graded air readings first, then the rest.

##### Hidden Fields

Keys to hide, separated by commas. `*` is a wildcard. The default
`update*,last_seen,identify` hides the Zigbee2MQTT firmware update details.

##### Field Labels

A custom label and unit per key, separated by `;`:

```
pm25=Fine dust|µg/m³; voc_index=Air quality|; linkquality=Signal
```

The `|unit` part is optional; a `|` with nothing after it removes the unit.

##### Temperature Display \[ **_As Received_** | Celsius to Fahrenheit | Fahrenheit to Celsius | Source is Fahrenheit \]

How temperatures are shown. `Source is Fahrenheit` only changes the unit label.

##### Stale After (minutes)

When nothing arrives for this long, the web view shows **Stale** and the
`Data Stale` event fires. `0` turns this off. Default is `15`.

##### Web View URL (read-only)

The address of the web view on the controller.

##### Create Variables \[ **_Yes_** | No \]

Creates one variable per shown value, named after its key (`pm25`,
`temperature`, ...), plus `Air Quality`.

## Driver Actions

##### Resubscribe

Sends the topic subscriptions to the MQTT Broker driver again.

##### Refresh Web View

Sends the current values to open web views.

##### Clear Values

Forgets all values. The broker sends the last message of each topic again.

## Programming

**Events:**

- **Values Updated** - New MQTT values arrived
- **Air Quality Changed** - The overall air-quality level changed
- **Data Stale** - Nothing arrived within Stale After (minutes)

**Variables:**

One variable per value when Create Variables is `Yes`, and `Air Quality` (Good,
Fair, Poor or Bad) when a graded reading is present.

# <span style="color:#660066">How the Web View Gets Its Data</span>

The page uses the Control4 UI Button JavaScript API:

- When it opens, and every 20 seconds after that, it asks the driver for the
  current values.
- It subscribes to the driver's updates, and the driver sends one as soon as a
  new MQTT message arrives.

Both carry the same data, so the page updates straight away on touch screens and
in the apps, including remote app sessions, with no extra web server or port.

# <span style="color:#660066">Support</span>

If you have any questions or issues integrating this driver with Control4, you
can file an issue on GitHub:

https://github.com/krishy2/control4-mqtt/issues/new

<!-- #embed-changelog -->
