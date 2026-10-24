<!-- Copyright 2026 Control Pro. All rights reserved. -->

# MQTT Server Test (step 0)

A test driver, not a product. It checks whether a Control4 controller can be the
MQTT broker for 30-100 Tasmota devices, before the broker is built into the MQTT
Broker driver (step 1).

It answers three questions:

1. **Can a driver listen on the port?** See **Server Status**.
1. **How many connections can one driver hold?** See **Connected Clients** and
   **Peak Connections**.
1. **Does binary MQTT data arrive intact?** See **Protocol Errors** (must stay
   0\) and **TCP Reads**.

It is a working broker for testing: Tasmota can connect, publish, subscribe, use
retained messages and Last Will. It is not connected to other drivers yet.

## What you need

- A controller on OS 3.3.x and, if possible, one on 4.x
- One or two Tasmota devices
- A computer on the same network with Python 3.7 or newer, for
  `mqtt_load_test.py` (in the repository next to this driver; nothing to
  install)

## Test 1: the port opens

1. Add `mqtt_server_test.c4z` to the project (Driver → Add or Update Driver).
1. Add **MQTT Server Test** to any room.
1. **Server Status** should show `Listening on 0.0.0.0:3883` within a few
   seconds.

If it shows an error, note the exact text. `address already in use` means
something else holds 3883; try another **Listen Port**.

## Test 2: a real Tasmota

1. In the Tasmota web UI, open Configuration → Configure MQTT. Set **Host** to
   the controller's IP and **Port** to `3883`. Leave the user and password as
   they are (they are ignored). Save.
1. The Tasmota console should show `MQT: Connected` within a few seconds, and
   **Connected Clients** in Composer goes to 1.
1. Run the **Print Clients** action. The device appears with its client id (e.g.
   `DVES_A1B2C3`) and about 3 subscriptions.
1. Run **Publish Test** with Topic `cmnd/<your device topic>/POWER` and Payload
   `TOGGLE`. The light should toggle.
1. Optional: set **Log Mode** to `Print` and **Log Messages** to `On` to watch
   the device's messages in the Lua output.

## Test 3: 100 clients

On the computer, from the folder with `mqtt_load_test.py`:

```
python3 mqtt_load_test.py --host <controller IP> --clients 100 --duration 300
```

On Windows use `py` instead of `python3`.

It simulates 100 Tasmota devices for 5 minutes and prints PASS or FAIL for each
check. When it finishes, run **Print Report** in Composer.

If time allows, try the limit too: set **Max Clients** to `1000` and run with
`--clients 200`, then `--clients 400`. Note where connections start failing.

If the simulator cannot connect at all while **Server Status** says `Listening`,
the controller's firewall is blocking the port. That is an important result in
itself.

## Test 4: restarts

1. With devices connected, run **Restart Server**. **Server Status** must show
   `Listening` again and the devices reconnect.
1. Restart Director (or update the driver) with devices connected. Note how long
   the real Tasmota takes to show `MQT: Connected` again in its console.

## What to send back

- The controller model and OS version for each controller tested
- The full output of `mqtt_load_test.py`
- The output of **Print Report** (and **Print Clients** for test 2)
- Anything from tests 1, 2 and 4 that did not behave as described

## Properties

**Server**

- **Listen Port**: TCP port for MQTT clients. Default 3883; 1883 belongs to the
  controller's own broker.
- **Max Clients**: refuse new connections above this many.
- **Server Status**: whether the port is open, or the error.
- **Test Summary**: clients, problems and worst timer lag at a glance.

**Connections**

- **Connected Clients**, **Open Connections**, **Peak Connections**, **Total
  Connections**
- **Rejected Connections**: unsupported protocol (for example MQTT 5), bad
  client id, or Max Clients reached.
- **Client Takeovers**: a device reconnected with the same id and replaced its
  old connection.
- **Keepalive Timeouts**: devices closed for going quiet longer than 1.5 times
  their keepalive.
- **Slow Clients Dropped**: clients closed because 1 MB of output was waiting
  for them.

**Traffic**

- **Messages In**, **Messages Delivered**, **Messages per Second**
- **Retained Messages**, **Wills Published**
- **Data In** / **Data Out**
- **TCP Reads**: socket reads. Split and multi-packet counts above 0 show that
  packets crossing read boundaries were put back together correctly.

**Errors**: **Protocol Errors**, **Socket Errors** and **Driver Errors** should
all stay 0. The matching **Last ... Error** shows the most recent one.

**Controller Load**

- **Timer Lag**: how late a 1-second timer fires. A few milliseconds is normal;
  hundreds mean Director is struggling.
- **Lua Memory**: memory used by this driver.

## Actions

- **Print Report**: every statistic, for pasting back.
- **Print Clients**: one line per connection.
- **Print Retained**: all retained messages.
- **Reset Statistics**, **Disconnect All Clients**, **Restart Server**
- **Publish Test**: publish a message to the connected devices.
