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

MQTT General w Webview is a WebView driver, like Control4's own WebView driver:
an Experience button you place in a room's Comfort menu (or Listen, Watch,
Security). Instead of a website it shows MQTT values. It reads one or more MQTT
topics through the MQTT Broker driver and shows every value it receives. JSON
payloads, such as an IKEA VINDSTYRKA air-quality sensor in Zigbee2MQTT, are
split into one tile per field.

The page is part of the driver and is served by the controller, so it works on
T4 and T5 touch screens and in the Control4 iOS and Android apps, at home and
remotely. All data comes from the driver on the controller; the page never
connects to MQTT itself.

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
- Fields that arrive in separate messages are kept, and the fields in Field
  Order are always shown
- A list of every field ever received, with one-click copy to Field Order
- Hide, reorder and relabel fields from Composer
- Stale data detection
- Connects itself to the MQTT Broker driver

# <span style="color:#660066">Installer Setup</span>

## Driver Installation

1. Install `cp_mqtt_general_webview.c4z` with the other MQTT drivers. Keep the
   file name: the web view address is
   `controller://driver/cp_mqtt_general_webview/...`, which must match the
   driver file name.

1. In Composer's "Search" tab, search for "MQTT General w Webview" and add the
   driver to the room where the button should appear. It connects to the MQTT
   Broker driver by itself.

## Driver Setup

1. Set [MQTT Topics](#mqtt-topics), for example `zigbee2mqtt/Vindstyrka`. Use
   the same topic as the MQTT General item that already reads the device.

1. When the values have arrived, choose **Copy All to Field Order** in Received
   Fields Action, then edit Field Order to keep the fields you want, in the
   order you want.

1. Show the button in Comfort. Like every WebView driver, Control4 adds it
   hidden: in **System Design**, select the room, open **Navigators** in the
   room's properties, find the driver under **Comfort** and set it to
   **Visible**. Use the other menus (Listen, Watch, Security) the same way if
   you want it there too.

1. Refresh Navigators. The button is in the room's Comfort menu on touch screens
   and in the app; tap it to open the web view.

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
wildcards are not used. Fields may arrive in separate messages: each field keeps
its last value until a new one arrives.

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

The fields to show, in order, for example `pm25,voc_index,temperature,humidity`.
These fields are always shown, even before a value has arrived (they show `--`
until then) and even when Hidden Fields matches them. Fields that are not listed
are not shown. Leave it empty to show every received field, graded air readings
first.

The easiest way to fill it is
[Copy All to Field Order](#received-fields-action--copy-all-to-field-order--clear-),
then delete the fields you do not want and reorder the rest.

##### Received Fields (read-only)

Every field ever received over MQTT, separated by commas. Devices that send one
field per message add to the list as each field arrives. The list is kept across
restarts.

##### Received Fields Action [ Copy All to Field Order | Clear ]

- **Copy All to Field Order** puts every field in Received Fields into Field
  Order, except those matched by Hidden Fields.
- **Clear** empties Received Fields; it fills again as fields arrive. Field
  Order and the shown values are not changed.

The list returns to `(Select)` after each use.

##### Hidden Fields

Keys to hide when Field Order is empty, and to leave out of Copy All to Field
Order, separated by commas. `*` is a wildcard. The default
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
