# Experiments

Drivers and tools for trying ideas on real hardware. Nothing here is part of a
release or the automatic update list.

## mqtt_server_test

Step 0 of the built-in MQTT broker: can a controller be the broker for 30-100
Tasmota devices? The test plan is in
[mqtt_server_test/www/documentation/index.md](mqtt_server_test/www/documentation/index.md).

- `driver.lua`, `driver.xml`: the test driver. Build it with
  `make mqtt-server-test`; the file lands in `dist/experiments/`.
- `mqtt_load_test.py`: simulates up to hundreds of Tasmota-like clients. Python
  3.7+, no packages.
- `run_local.lua`: runs the driver on a computer (LuaJIT + luasocket) so the
  load test can be tried without a controller.

The broker itself is in `src/mqtt/server/` (codec and broker core) and is unit
tested by `test/test_mqtt_server.lua`.
