#!/usr/bin/env python3
"""Load test for the MQTT Server Test driver (step 0).

Simulates Tasmota-like MQTT clients against the driver and checks that the
broker routes everything correctly. Python 3.7+ and nothing else: no packages
to install. Run it on a computer on the same network as the controller:

    python3 mqtt_load_test.py --host 192.168.1.50
    python3 mqtt_load_test.py --host 192.168.1.50 --clients 100 --duration 300

What one run does
  1. Connects --clients simulated devices. Like Tasmota, each sets a retained
     Last Will (tele/<id>/LWT Offline), publishes Online and a ~1.5 KB retained
     discovery config, subscribes to cmnd/<id>/#, publishes telemetry and
     answers POWER commands. Every 5th client sends its packets one byte at a
     time and every 5th+1 sends several packets in one write, to test framing.
  2. A "controller" client sends POWER commands to random devices and times
     the answers, and checks every telemetry message arrives once, in order,
     intact.
  3. A fresh client checks the retained messages (all Online, all configs).
  4. 10% of devices drop without DISCONNECT: their Offline wills must arrive.
  5. One device reconnects with the same client id: the old connection must
     be closed by the server.

The exit code is 0 when every check passes. Paste the whole output back.
"""

import argparse
import asyncio
import hashlib
import json
import random
import socket
import statistics
import struct
import sys
import time

# ----------------------------------------------------------------------------
# MQTT 3.1.1 packets
# ----------------------------------------------------------------------------


def enc_len(n):
    out = bytearray()
    while True:
        digit = n % 128
        n //= 128
        if n:
            digit |= 0x80
        out.append(digit)
        if not n:
            return bytes(out)


def enc_str(s):
    b = s.encode() if isinstance(s, str) else s
    return struct.pack("!H", len(b)) + b


def pkt(first, body):
    return bytes([first]) + enc_len(len(body)) + body


def p_connect(client_id, keepalive, will=None):
    flags = 0x02
    payload = enc_str(client_id)
    if will:
        topic, message, retain = will
        flags |= 0x04 | (0x20 if retain else 0)
        payload += enc_str(topic) + enc_str(message)
    body = enc_str("MQTT") + bytes([4, flags]) + struct.pack("!H", keepalive) + payload
    return pkt(0x10, body)


def p_publish(topic, payload, retain=False, qos=0, packet_id=1):
    body = enc_str(topic)
    if qos:
        body += struct.pack("!H", packet_id)
    body += payload.encode() if isinstance(payload, str) else payload
    return pkt(0x30 | (qos << 1) | (1 if retain else 0), body)


def p_subscribe(packet_id, filters):
    body = struct.pack("!H", packet_id)
    for f in filters:
        body += enc_str(f) + bytes([0])
    return pkt(0x82, body)


P_PINGREQ = bytes([0xC0, 0])
P_DISCONNECT = bytes([0xE0, 0])


class Framer:
    """Turns a TCP byte stream into (type, flags, body) packets."""

    def __init__(self):
        self.buf = bytearray()

    def feed(self, data):
        self.buf += data
        out = []
        while True:
            if len(self.buf) < 2:
                return out
            mult, value, i = 1, 0, 1
            while True:
                if i >= len(self.buf):
                    return out
                b = self.buf[i]
                value += (b & 0x7F) * mult
                mult *= 128
                i += 1
                if b < 128:
                    break
                if i > 4:
                    raise ValueError("malformed remaining length from server")
            if len(self.buf) - i < value:
                return out
            first = self.buf[0]
            body = bytes(self.buf[i : i + value])
            del self.buf[: i + value]
            out.append((first >> 4, first & 0x0F, body))


def parse_publish(flags, body):
    tlen = struct.unpack("!H", body[:2])[0]
    topic = body[2 : 2 + tlen].decode(errors="replace")
    pos = 2 + tlen
    if (flags >> 1) & 3:
        pos += 2
    return topic, body[pos:], bool(flags & 1)


# ----------------------------------------------------------------------------
# Clients
# ----------------------------------------------------------------------------


class Stats:
    def __init__(self):
        self.connect_ok = 0
        self.connect_fail = []
        self.unexpected_disconnects = []
        self.tele_sent = {}  # id -> last seq sent
        self.tele_seen = {}  # id -> list of seqs received by controller
        self.tele_corrupt = 0
        self.cmd_sent = {}  # token -> (id, t0)
        self.cmd_rtt = []
        self.cmd_wrong_target = 0
        self.wills = set()
        self.server_errors = []


def checksum(text):
    return hashlib.sha1(text.encode()).hexdigest()[:12]


class Client:
    def __init__(self, args, client_id, stats, mode="normal"):
        self.args = args
        self.id = client_id
        self.stats = stats
        self.mode = mode  # normal | split | pipelined
        self.reader = None
        self.writer = None
        self.framer = Framer()
        self.connack = asyncio.Event()
        self.suback = asyncio.Event()
        self.closed = asyncio.Event()
        self.on_publish = None
        self.expect_close = False
        self.last_tx = time.monotonic()
        self.tasks = []
        self.retained_seen = {}
        self.write_lock = asyncio.Lock()

    async def write(self, data):
        # One packet at a time: a split write must not interleave with another.
        async with self.write_lock:
            self.last_tx = time.monotonic()
            if self.mode == "split":
                for i in range(len(data)):
                    self.writer.write(data[i : i + 1])
                    await self.writer.drain()
                    if i % 16 == 15:
                        await asyncio.sleep(0.001)
            else:
                self.writer.write(data)
                await self.writer.drain()

    async def open(self, will=None, subscribe=None, first_publishes=()):
        try:
            self.reader, self.writer = await asyncio.wait_for(
                asyncio.open_connection(self.args.host, self.args.port), timeout=10
            )
        except Exception as e:  # noqa: BLE001 - report every failure kind
            self.stats.connect_fail.append(f"{self.id}: TCP connect failed: {e!r}")
            return False
        sock = self.writer.get_extra_info("socket")
        if sock is not None:
            # Send each packet at once so round-trip times are real
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.tasks.append(asyncio.ensure_future(self.read_loop()))
        connect = p_connect(self.id, self.args.keepalive, will)
        rest = b""
        if subscribe:
            rest += p_subscribe(1, subscribe)
        for topic, payload, retain in first_publishes:
            rest += p_publish(topic, payload, retain)
        try:
            if self.mode == "pipelined":
                # CONNECT, SUBSCRIBE and PUBLISH in a single write
                await self.write(connect + rest)
                await asyncio.wait_for(self.connack.wait(), timeout=10)
            else:
                await self.write(connect)
                await asyncio.wait_for(self.connack.wait(), timeout=10)
                if rest:
                    await self.write(rest)
            if subscribe:
                await asyncio.wait_for(self.suback.wait(), timeout=10)
        except Exception as e:  # noqa: BLE001
            self.stats.connect_fail.append(f"{self.id}: no CONNACK/SUBACK: {e!r}")
            self.abort()
            return False
        self.stats.connect_ok += 1
        self.tasks.append(asyncio.ensure_future(self.ping_loop()))
        return True

    async def read_loop(self):
        try:
            while True:
                data = await self.reader.read(65536)
                if not data:
                    break
                for ptype, flags, body in self.framer.feed(data):
                    if ptype == 2:
                        if body[1] != 0:
                            self.stats.server_errors.append(
                                f"{self.id}: CONNACK code {body[1]}"
                            )
                        self.connack.set()
                    elif ptype == 9:
                        self.suback.set()
                    elif ptype == 3:
                        topic, payload, retain = parse_publish(flags, body)
                        if retain:
                            self.retained_seen[topic] = payload
                        if self.on_publish:
                            self.on_publish(topic, payload, retain)
        except (ConnectionError, OSError, asyncio.CancelledError):
            pass
        except ValueError as e:
            self.stats.server_errors.append(f"{self.id}: {e}")
        finally:
            self.closed.set()
            # Only a connection that was up counts; refused connects are reported separately.
            if not self.expect_close and self.connack.is_set():
                self.stats.unexpected_disconnects.append(self.id)

    async def ping_loop(self):
        try:
            while True:
                await asyncio.sleep(1)
                if time.monotonic() - self.last_tx >= self.args.keepalive * 0.8:
                    await self.write(P_PINGREQ)
        except (ConnectionError, OSError, asyncio.CancelledError):
            pass

    async def publish(self, topic, payload, retain=False):
        await self.write(p_publish(topic, payload, retain))

    async def disconnect(self):
        self.expect_close = True
        try:
            await self.write(P_DISCONNECT)
            self.writer.close()
        except (ConnectionError, OSError):
            pass
        self.stop_tasks()

    def abort(self):
        """Drop the TCP connection without DISCONNECT (like a power cut)."""
        self.expect_close = True
        if self.writer:
            try:
                sock = self.writer.get_extra_info("socket")
                if sock is not None:
                    # RST instead of FIN so it looks like a lost device
                    sock.setsockopt(
                        socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0)
                    )
                self.writer.close()
            except OSError:
                pass
        self.stop_tasks()

    def stop_tasks(self):
        for t in self.tasks:
            t.cancel()


class Device(Client):
    """A simulated Tasmota."""

    def __init__(self, args, index, stats):
        mode = (
            "split" if index % 5 == 0 else ("pipelined" if index % 5 == 1 else "normal")
        )
        super().__init__(args, f"{args.prefix}_{index:03d}", stats, mode)
        self.seq = 0
        self.on_publish = self.handle

    def discovery_topic(self):
        index = int(self.id.rsplit("_", 1)[1])
        return f"tasmota/discovery/SIM0000{index:05X}/config"

    def discovery_config(self):
        # Shaped like Tasmota's discovery config, padded to ~1.5 KB
        index = int(self.id.rsplit("_", 1)[1])
        cfg = {
            "ip": f"10.0.{index // 250}.{index % 250 + 1}",
            "dn": self.id,
            "fn": [self.id, None, None, None, None, None, None, None],
            "hn": f"{self.id}-{index:04d}",
            "mac": f"SIM0000{index:05X}",
            "md": "Simulated RGBW",
            "ty": 0,
            "if": 0,
            "cam": 0,
            "ofln": "Offline",
            "onln": "Online",
            "state": ["OFF", "ON", "TOGGLE", "HOLD"],
            "sw": "14.3.0",
            "t": self.id,
            "ft": "%prefix%/%topic%/",
            "tp": ["cmnd", "stat", "tele"],
            "rl": [2, 0, 0, 0, 0, 0, 0, 0],
            "so": {"4": 0, "11": 0, "13": 0, "17": 0, "20": 0, "30": 0},
            "lk": 1,
            "lt_st": 4,
            "ver": 1,
        }
        cfg["pad"] = "x" * 900
        return json.dumps(cfg)

    async def start(self):
        return await self.open(
            will=(f"tele/{self.id}/LWT", "Offline", True),
            subscribe=[f"cmnd/{self.id}/#"],
            first_publishes=[
                (f"tele/{self.id}/LWT", "Online", True),
                (self.discovery_topic(), self.discovery_config(), True),
            ],
        )

    def handle(self, topic, payload, retain):
        if topic.startswith(f"cmnd/{self.id}/POWER"):
            msg = payload.decode(errors="replace")
            answer = json.dumps({"POWER": msg})
            asyncio.ensure_future(self.safe_publish(f"stat/{self.id}/RESULT", answer))
        elif topic.startswith("cmnd/"):
            self.stats.cmd_wrong_target += 1

    async def safe_publish(self, topic, payload):
        try:
            await self.publish(topic, payload)
        except (ConnectionError, OSError):
            pass

    async def telemetry_loop(self, stop_at):
        await asyncio.sleep(random.uniform(0, self.args.tele))
        while time.monotonic() < stop_at:
            self.seq += 1
            body = json.dumps(
                {"seq": self.seq, "POWER": "ON", "Dimmer": random.randint(1, 100)}
            )
            text = json.dumps({"data": body, "crc": checksum(body)})
            try:
                await self.publish(f"tele/{self.id}/STATE", text)
                self.stats.tele_sent[self.id] = self.seq
            except (ConnectionError, OSError):
                return
            await asyncio.sleep(self.args.tele)


class Controller(Client):
    def __init__(self, args, stats):
        super().__init__(args, f"{args.prefix}_controller", stats)
        self.on_publish = self.handle

    def handle(self, topic, payload, retain):
        text = payload.decode(errors="replace")
        parts = topic.split("/")
        if len(parts) == 3 and not parts[1].startswith(self.args.prefix + "_"):
            return  # a real device on the same broker, not one of ours
        if len(parts) == 3 and parts[0] == "tele" and parts[2] == "STATE":
            try:
                outer = json.loads(text)
                if checksum(outer["data"]) != outer["crc"]:
                    raise ValueError("crc")
                seq = json.loads(outer["data"])["seq"]
                self.stats.tele_seen.setdefault(parts[1], []).append(seq)
            except (ValueError, KeyError):
                self.stats.tele_corrupt += 1
        elif len(parts) == 3 and parts[0] == "stat" and parts[2] == "RESULT":
            try:
                token = json.loads(text)["POWER"]
            except (ValueError, KeyError):
                return
            sent = self.stats.cmd_sent.pop(token, None)
            if sent:
                dev, t0 = sent
                if dev != parts[1]:
                    self.stats.cmd_wrong_target += 1
                self.stats.cmd_rtt.append((time.monotonic() - t0) * 1000)
        elif (
            len(parts) == 3
            and parts[0] == "tele"
            and parts[2] == "LWT"
            and text == "Offline"
        ):
            self.stats.wills.add(parts[1])

    async def command_loop(self, devices, stop_at):
        n = 0
        interval = 1.0 / self.args.commands if self.args.commands > 0 else None
        while interval and time.monotonic() < stop_at:
            live = [d for d in devices if not d.closed.is_set()]
            if live:
                d = random.choice(live)
                n += 1
                token = f"T{n}"
                self.stats.cmd_sent[token] = (d.id, time.monotonic())
                try:
                    await self.publish(f"cmnd/{d.id}/POWER", token)
                except (ConnectionError, OSError):
                    return
            await asyncio.sleep(interval)


# ----------------------------------------------------------------------------
# Test run
# ----------------------------------------------------------------------------


class Report:
    def __init__(self):
        self.failures = 0
        self.lines = []

    def check(self, name, ok, detail=""):
        self.failures += 0 if ok else 1
        self.lines.append(
            f"  [{'PASS' if ok else 'FAIL'}] {name}"
            + (f"  ({detail})" if detail else "")
        )

    def info(self, text):
        self.lines.append("  " + text)


def pct(values, p):
    if not values:
        return 0.0
    values = sorted(values)
    k = min(len(values) - 1, max(0, int(round(p / 100.0 * (len(values) - 1)))))
    return values[k]


async def run(args):
    stats = Stats()
    report = Report()
    t_start = time.monotonic()
    print(
        f"MQTT load test: {args.clients} clients -> {args.host}:{args.port}, {args.duration}s"
    )

    controller = Controller(args, stats)
    if not await controller.open(
        subscribe=["tele/+/STATE", "stat/+/RESULT", "tele/+/LWT"]
    ):
        print("Could not connect the controller client:")
        for f in stats.connect_fail:
            print("   ", f)
        print(
            "Check --host and --port, that the driver shows 'Listening', and the controller firewall."
        )
        return 2

    # 1. Connect devices in batches
    devices = [Device(args, i + 1, stats) for i in range(args.clients)]
    t0 = time.monotonic()
    for i in range(0, len(devices), args.batch):
        batch = devices[i : i + args.batch]
        results = await asyncio.gather(*(d.start() for d in batch))
        connected = sum(1 for d in devices[: i + len(batch)] if d.connack.is_set())
        print(f"  connected {connected}/{i + len(batch)}", end="\r", flush=True)
        if not all(results) and args.stop_on_fail:
            break
    connect_secs = time.monotonic() - t0
    live = [d for d in devices if d.connack.is_set()]
    print()
    report.check(
        f"all {args.clients} devices connected",
        len(live) == args.clients,
        f"{len(live)} connected in {connect_secs:.1f}s",
    )
    if stats.connect_fail:
        for f in stats.connect_fail[:10]:
            report.info("connect failure: " + f)

    # 2. Traffic
    stop_at = time.monotonic() + args.duration
    traffic = [asyncio.ensure_future(d.telemetry_loop(stop_at)) for d in live]
    traffic.append(asyncio.ensure_future(controller.command_loop(live, stop_at)))
    while time.monotonic() < stop_at:
        left = int(stop_at - time.monotonic())
        print(
            f"  running: {left:4d}s left, {len(stats.cmd_rtt)} commands answered, "
            f"{len(stats.unexpected_disconnects)} unexpected disconnects   ",
            end="\r",
            flush=True,
        )
        await asyncio.sleep(1)
    await asyncio.gather(*traffic, return_exceptions=True)
    await asyncio.sleep(2)  # let the last messages arrive
    print()

    lost = dup = disorder = 0
    for d in live:
        sent = stats.tele_sent.get(d.id, 0)
        seen = stats.tele_seen.get(d.id, [])
        if seen != sorted(seen):
            disorder += 1
        dup += len(seen) - len(set(seen))
        lost += sent - len(set(seen))
    total_tele = sum(stats.tele_sent.values())
    report.check(
        "telemetry: nothing lost", lost == 0, f"{total_tele} sent, {lost} lost"
    )
    report.check("telemetry: no duplicates", dup == 0, f"{dup} duplicates")
    report.check(
        "telemetry: in order", disorder == 0, f"{disorder} devices out of order"
    )
    report.check(
        "telemetry: intact", stats.tele_corrupt == 0, f"{stats.tele_corrupt} corrupt"
    )
    answered = len(stats.cmd_rtt)
    unanswered = len(stats.cmd_sent)
    report.check(
        "commands: every command answered",
        unanswered == 0,
        f"{answered} answered, {unanswered} not",
    )
    report.check(
        "commands: only the target device got it",
        stats.cmd_wrong_target == 0,
        f"{stats.cmd_wrong_target} misrouted",
    )
    if stats.cmd_rtt:
        report.info(
            "command round trip (controller -> device -> controller): "
            f"median {statistics.median(stats.cmd_rtt):.0f} ms, "
            f"95% {pct(stats.cmd_rtt, 95):.0f} ms, max {max(stats.cmd_rtt):.0f} ms"
        )
    report.check(
        "no unexpected disconnects",
        not stats.unexpected_disconnects,
        f"{len(stats.unexpected_disconnects)}: {', '.join(stats.unexpected_disconnects[:5])}",
    )

    # 3. Retained messages, seen by a fresh client
    checker = Client(args, f"{args.prefix}_checker", stats)
    if await checker.open(subscribe=["tele/+/LWT", "tasmota/discovery/+/config"]):
        await asyncio.sleep(2)
        online = sum(
            1
            for d in live
            if checker.retained_seen.get(f"tele/{d.id}/LWT") == b"Online"
        )
        configs = sum(
            1
            for d in live
            if checker.retained_seen.get(d.discovery_topic(), b"").decode(
                errors="replace"
            )
            == d.discovery_config()
        )
        report.check(
            "retained: every device shows Online",
            online == len(live),
            f"{online}/{len(live)}",
        )
        report.check(
            "retained: every discovery config intact",
            configs == len(live),
            f"{configs}/{len(live)}",
        )
        await checker.disconnect()
    else:
        report.check("retained: checker client connected", False)

    # 4. Last Will: drop 10% without DISCONNECT
    victims = live[: max(1, len(live) // 10)] if live else []
    for d in victims:
        d.abort()
    await asyncio.sleep(3)
    got = sum(1 for d in victims if d.id in stats.wills)
    report.check(
        "last will: dropped devices reported Offline",
        got == len(victims),
        f"{got}/{len(victims)}",
    )

    # 5. Same client id reconnects: the old connection must be closed
    survivors = [d for d in live if d not in victims]
    if survivors:
        old = survivors[-1]
        old.expect_close = True
        twin = Device(args, int(old.id.rsplit("_", 1)[1]), stats)
        twin.mode = "normal"
        twin_ok = await twin.start()
        try:
            await asyncio.wait_for(old.closed.wait(), timeout=5)
            replaced = True
        except asyncio.TimeoutError:
            replaced = False
        report.check(
            "reconnect with same id: new accepted, old closed", twin_ok and replaced
        )
        survivors[-1] = twin

    # Clean up
    for d in survivors:
        await d.disconnect()
    await controller.disconnect()

    if stats.server_errors:
        report.check(
            "no protocol errors from the server",
            False,
            "; ".join(stats.server_errors[:5]),
        )

    print()
    print("=" * 70)
    print(
        f"Result for {args.host}:{args.port}  ({args.clients} clients, {args.duration}s, {time.monotonic() - t_start:.0f}s total)"
    )
    for line in report.lines:
        print(line)
    print("=" * 70)
    print(
        "ALL CHECKS PASSED"
        if report.failures == 0
        else f"{report.failures} CHECK(S) FAILED"
    )
    print("Now run 'Print Report' in the driver's Actions tab and paste both outputs.")
    return 0 if report.failures == 0 else 1


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("--host", required=True, help="controller IP address")
    ap.add_argument("--port", type=int, default=3883)
    ap.add_argument(
        "--clients", type=int, default=100, help="simulated devices (default 100)"
    )
    ap.add_argument(
        "--duration", type=int, default=120, help="seconds of traffic (default 120)"
    )
    ap.add_argument(
        "--keepalive",
        type=int,
        default=30,
        help="MQTT keepalive seconds (Tasmota default 30)",
    )
    ap.add_argument(
        "--tele",
        type=float,
        default=10,
        help="seconds between telemetry per device (default 10)",
    )
    ap.add_argument(
        "--commands",
        type=float,
        default=5,
        help="commands per second from the controller (default 5)",
    )
    ap.add_argument(
        "--batch",
        type=int,
        default=10,
        help="devices connecting at the same time (default 10)",
    )
    ap.add_argument("--prefix", default="sim", help="client id prefix (default sim)")
    ap.add_argument(
        "--stop-on-fail",
        action="store_true",
        help="stop connecting at the first failure",
    )
    args = ap.parse_args()
    if sys.platform == "win32":
        asyncio.set_event_loop_policy(asyncio.WindowsSelectorEventLoopPolicy())
    try:
        sys.exit(asyncio.run(run(args)))
    except KeyboardInterrupt:
        sys.exit(130)


if __name__ == "__main__":
    main()
