# Observability Stack Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A `docker compose up` that gets you Factorio plus a working Grafana instance with two pre-provisioned dashboards — factory/server stats (item production rates, UPS, player count, power) and server logs — with the stats dashboard independently shareable without exposing the logs dashboard.

**Architecture:** A new Python exporter (`exporter/`) polls Factorio's RCON interface and serves Prometheus metrics; a new compose example (`examples/docker-compose.observability.yml`) wires that exporter together with Prometheus, Loki, Promtail, and Grafana (all official upstream images), provisioned via config files in a new `observability/` directory so dashboards and datasources appear with zero manual clicking. Two new CI workflows: one adds a real integration test to the existing `ci.yml`, the other publishes the new exporter image.

**Tech Stack:** Python 3.13 (stdlib socket for RCON, `prometheus_client` for metrics), Prometheus, Loki, Promtail, Grafana (official images), Docker Compose.

## Global Constraints

- No changes to the main `factorio-headless` image, its entrypoint, or its CI/publishing pipeline — this is entirely new, additive components plus turning on the existing (already-supported) `CONSOLE_LOG` env var in the new compose example.
- Metrics are cumulative counters mirroring Factorio's own cumulative game state (`input_counts`/`output_counts`, `game.tick`) — rates are computed by PromQL (`rate(...)`), not by the exporter. Verified pattern: `Counter.labels(...)._value.set(absolute_value)` (prometheus_client 0.26.0, confirmed working — this is the documented approach for mirroring an externally-tracked cumulative value, since `Counter` has no public "set absolute value" method, only `.inc()`).
- Exact metric names (all verified against these Lua paths on a live server): `factorio_item_produced_total{item}` (`get_item_production_statistics(surface).input_counts`), `factorio_item_consumed_total{item}` (same object's `.output_counts`), `factorio_tick_total` (`game.tick`), `factorio_players_connected` (`#game.connected_players`), `factorio_power_produced_joules_total{network_id}` / `factorio_power_consumed_joules_total{network_id}` (pole `.electric_network_statistics`, deduped by `.electric_network_id`).
- `helpers.table_to_json`, not `game.table_to_json` — the latter doesn't exist in Factorio 2.0+.
- Image versions to pin (all confirmed available and working during design): `prom/prometheus:v3.15.0` (note the `v` prefix — `prom/prometheus:3.15.0` without it does not exist), `grafana/loki:3.7.8`, `grafana/promtail:3.6.8`, `grafana/grafana:13.2.2`.
- Exporter's own Dockerfile must set `PYTHONUNBUFFERED=1` — confirmed during design that without it, the exporter's log output does not reach `docker logs` promptly (Python block-buffers stdout when it isn't a TTY).
- No new credential env vars beyond what's needed: the exporter reuses the same `RCON_PASSWORD` value the `factorio` service already uses.

---

### Task 1: RCON client module + tests

**Files:**
- Create: `exporter/rcon.py`
- Create: `exporter/test_rcon.py`

**Interfaces:**
- Consumes: nothing (foundational).
- Produces: `RconClient(host, port, password, timeout=10)` with methods `.connect()` (raises `RconError` on auth failure), `.command(command) -> str`, `.close()`. `RconError` exception class. Task 2 imports both by name from `exporter.rcon`.

- [ ] **Step 1: Write the failing test**

Create `exporter/test_rcon.py`:

```python
import socket
import struct
import threading
import unittest

from rcon import RconClient, RconError


def _pack_packet(pkt_id, pkt_type, body):
    payload = struct.pack("<ii", pkt_id, pkt_type) + body.encode("utf-8") + b"\x00\x00"
    return struct.pack("<i", len(payload)) + payload


def _read_packet(sock):
    size = struct.unpack("<i", sock.recv(4))[0]
    data = b""
    while len(data) < size:
        data += sock.recv(size - len(data))
    pkt_id, pkt_type = struct.unpack("<ii", data[:8])
    body = data[8:-2].decode("utf-8")
    return pkt_id, pkt_type, body


class _FakeRconServer:
    """A minimal in-process RCON server for testing RconClient against real
    socket behavior, not mocks. Accepts one connection, authenticates against
    a fixed password, and echoes back "echo: <command>" for any command."""

    def __init__(self, password):
        self._password = password
        self._server_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self._server_sock.bind(("127.0.0.1", 0))
        self._server_sock.listen(1)
        self.port = self._server_sock.getsockname()[1]
        self._thread = threading.Thread(target=self._serve, daemon=True)
        self._thread.start()

    def _serve(self):
        conn, _ = self._server_sock.accept()
        with conn:
            pkt_id, _, body = _read_packet(conn)
            if body == self._password:
                conn.sendall(_pack_packet(pkt_id, 2, ""))
            else:
                conn.sendall(_pack_packet(-1, 2, ""))
                return
            while True:
                try:
                    pkt_id, _, body = _read_packet(conn)
                except (ConnectionError, struct.error, IndexError):
                    return
                conn.sendall(_pack_packet(pkt_id, 0, f"echo: {body}"))

    def close(self):
        self._server_sock.close()


class TestRconClient(unittest.TestCase):
    def test_successful_auth_and_command(self):
        server = _FakeRconServer(password="correct-password")
        try:
            client = RconClient("127.0.0.1", server.port, "correct-password")
            client.connect()
            self.assertEqual(client.command("hello"), "echo: hello")
            client.close()
        finally:
            server.close()

    def test_failed_auth_raises(self):
        server = _FakeRconServer(password="correct-password")
        try:
            client = RconClient("127.0.0.1", server.port, "wrong-password")
            with self.assertRaises(RconError):
                client.connect()
        finally:
            server.close()


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `cd exporter && python3 test_rcon.py`
Expected: FAIL — `ModuleNotFoundError: No module named 'rcon'` (the module doesn't exist yet).

- [ ] **Step 3: Write `exporter/rcon.py`**

```python
"""Minimal Source RCON client (stdlib only) — the same protocol Factorio uses."""
import socket
import struct

SERVERDATA_AUTH = 3
SERVERDATA_EXECCOMMAND = 2
SERVERDATA_RESPONSE_VALUE = 0


class RconError(Exception):
    """Raised when authentication fails or the connection breaks."""


class RconClient:
    def __init__(self, host, port, password, timeout=10):
        self._host = host
        self._port = port
        self._password = password
        self._timeout = timeout
        self._sock = None

    def connect(self):
        self._sock = socket.create_connection((self._host, self._port), timeout=self._timeout)
        self._send_packet(1, SERVERDATA_AUTH, self._password)
        pkt_id, pkt_type, _ = self._read_packet()
        if pkt_type == SERVERDATA_RESPONSE_VALUE:
            pkt_id, pkt_type, _ = self._read_packet()
        if pkt_id != 1:
            self.close()
            raise RconError("RCON authentication failed")

    def command(self, command):
        self._send_packet(2, SERVERDATA_EXECCOMMAND, command)
        _, _, body = self._read_packet()
        return body

    def close(self):
        if self._sock is not None:
            self._sock.close()
            self._sock = None

    def _send_packet(self, pkt_id, pkt_type, body):
        payload = struct.pack("<ii", pkt_id, pkt_type) + body.encode("utf-8") + b"\x00\x00"
        self._sock.sendall(struct.pack("<i", len(payload)) + payload)

    def _read_packet(self):
        size = struct.unpack("<i", self._recv_exact(4))[0]
        data = self._recv_exact(size)
        pkt_id, pkt_type = struct.unpack("<ii", data[:8])
        body = data[8:-2].decode("utf-8", errors="replace")
        return pkt_id, pkt_type, body

    def _recv_exact(self, n):
        buf = b""
        while len(buf) < n:
            chunk = self._sock.recv(n - len(buf))
            if not chunk:
                raise RconError("connection closed while reading")
            buf += chunk
        return buf
```

- [ ] **Step 4: Run the test and confirm it passes**

Run: `cd exporter && python3 test_rcon.py -v`
Expected:
```
test_failed_auth_raises (__main__.TestRconClient) ... ok
test_successful_auth_and_command (__main__.TestRconClient) ... ok

Ran 2 tests in ...s

OK
```

- [ ] **Step 5: Commit**

```bash
git add exporter/rcon.py exporter/test_rcon.py
git commit -m "$(cat <<'EOF'
Add minimal Source RCON client with tests against a real in-process fake server

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Exporter metrics + polling logic + tests

**Files:**
- Create: `exporter/exporter.py`
- Create: `exporter/test_exporter.py`
- Create: `exporter/requirements.txt`

**Interfaces:**
- Consumes: `exporter.rcon.RconClient`, `exporter.rcon.RconError` (Task 1).
- Produces: `parse_item_stats(response) -> (dict, dict)`, `parse_globals(response) -> (int, int)`, `parse_power_stats(response) -> dict`, `poll_once(client)` (updates module-level Prometheus collectors), `main()`. Task 3 needs `exporter.py` to run as `python3 exporter.py` reading `FACTORIO_HOST`, `RCON_PORT`, `RCON_PASSWORD`, `POLL_INTERVAL_SECONDS`, `METRICS_PORT` from the environment and serving metrics on `METRICS_PORT` (default `8000`).

- [ ] **Step 1: Write `exporter/requirements.txt`**

```
prometheus_client==0.26.0
```

- [ ] **Step 2: Write the failing tests**

Create `exporter/test_exporter.py`:

```python
import json
import unittest

from exporter import parse_globals, parse_item_stats, parse_power_stats


class TestParsing(unittest.TestCase):
    def test_parse_item_stats(self):
        response = json.dumps({"input": {"iron-plate": 100}, "output": {"iron-plate": 40}})
        input_counts, output_counts = parse_item_stats(response)
        self.assertEqual(input_counts, {"iron-plate": 100})
        self.assertEqual(output_counts, {"iron-plate": 40})

    def test_parse_item_stats_empty(self):
        response = json.dumps({"input": {}, "output": {}})
        input_counts, output_counts = parse_item_stats(response)
        self.assertEqual(input_counts, {})
        self.assertEqual(output_counts, {})

    def test_parse_globals(self):
        response = json.dumps({"tick": 164302, "players": 2})
        tick, players = parse_globals(response)
        self.assertEqual(tick, 164302)
        self.assertEqual(players, 2)

    def test_parse_power_stats_dedupes_by_network(self):
        # Matches the real shape returned by the power-stats Lua command: one
        # entry per distinct electric_network_id, keyed as a JSON string.
        response = json.dumps({"3": {"input": {"solar-panel": 500}, "output": {"electric-mining-drill": 200}}})
        result = parse_power_stats(response)
        self.assertEqual(result, {"3": ({"solar-panel": 500}, {"electric-mining-drill": 200})})

    def test_parse_power_stats_empty(self):
        self.assertEqual(parse_power_stats("{}"), {})


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 3: Run it and confirm it fails**

Run: `cd exporter && python3 test_exporter.py`
Expected: FAIL — `ModuleNotFoundError: No module named 'exporter'` or an import error, since `exporter.py` doesn't exist yet.

- [ ] **Step 4: Write `exporter/exporter.py`**

```python
"""Factorio RCON -> Prometheus metrics exporter."""
import json
import os
import time

from prometheus_client import Counter, Gauge, start_http_server

from rcon import RconClient, RconError

ITEM_PRODUCED = Counter("factorio_item_produced_total", "Cumulative items produced", ["item"])
ITEM_CONSUMED = Counter("factorio_item_consumed_total", "Cumulative items consumed", ["item"])
TICK_TOTAL = Counter("factorio_tick_total", "Cumulative game ticks simulated")
PLAYERS_CONNECTED = Gauge("factorio_players_connected", "Currently connected players")
POWER_PRODUCED = Counter("factorio_power_produced_joules_total", "Cumulative energy produced", ["network_id"])
POWER_CONSUMED = Counter("factorio_power_consumed_joules_total", "Cumulative energy consumed", ["network_id"])

# All three commands verified live against a real running server during design.
_ITEM_STATS_COMMAND = (
    "/sc local stats = game.forces.player.get_item_production_statistics(game.surfaces[1]) "
    "rcon.print(helpers.table_to_json({input=stats.input_counts, output=stats.output_counts}))"
)
_GLOBALS_COMMAND = "/sc rcon.print(helpers.table_to_json({tick=game.tick, players=#game.connected_players}))"
_POWER_COMMAND = (
    "/sc local seen = {} local out = {} "
    "for _, pole in pairs(game.surfaces[1].find_entities_filtered{type='electric-pole'}) do "
    "local id = pole.electric_network_id "
    "if id and not seen[id] then seen[id] = true "
    "out[tostring(id)] = {input=pole.electric_network_statistics.input_counts, output=pole.electric_network_statistics.output_counts} "
    "end end rcon.print(helpers.table_to_json(out))"
)


def parse_item_stats(response):
    """Parses the JSON body of _ITEM_STATS_COMMAND into (input_counts, output_counts) dicts."""
    data = json.loads(response)
    return data.get("input", {}), data.get("output", {})


def parse_globals(response):
    """Parses the JSON body of _GLOBALS_COMMAND into (tick, players) ints."""
    data = json.loads(response)
    return int(data["tick"]), int(data["players"])


def parse_power_stats(response):
    """Parses the JSON body of _POWER_COMMAND into {network_id: (input_counts, output_counts)}."""
    data = json.loads(response)
    return {
        network_id: (entry.get("input", {}), entry.get("output", {}))
        for network_id, entry in data.items()
    }


def poll_once(client):
    """One full poll cycle: fetches all metrics via RCON and updates the
    Prometheus collectors in place. Values are set to the absolute cumulative
    figures Factorio itself tracks — see Global Constraints on why Counter
    objects are updated via `.labels(...)._value.set(...)` rather than
    `.inc()`. Raises RconError/ValueError on any RCON or parse failure; the
    caller (main's loop) is responsible for catching that and retrying."""
    input_counts, output_counts = parse_item_stats(client.command(_ITEM_STATS_COMMAND))
    for item_name, count in input_counts.items():
        ITEM_PRODUCED.labels(item=item_name)._value.set(count)
    for item_name, count in output_counts.items():
        ITEM_CONSUMED.labels(item=item_name)._value.set(count)

    tick, players = parse_globals(client.command(_GLOBALS_COMMAND))
    TICK_TOTAL._value.set(tick)
    PLAYERS_CONNECTED.set(players)

    for network_id, (power_in, power_out) in parse_power_stats(client.command(_POWER_COMMAND)).items():
        POWER_PRODUCED.labels(network_id=network_id)._value.set(sum(power_in.values()))
        POWER_CONSUMED.labels(network_id=network_id)._value.set(sum(power_out.values()))


def main():
    host = os.environ.get("FACTORIO_HOST", "factorio")
    port = int(os.environ.get("RCON_PORT", "27015"))
    password = os.environ["RCON_PASSWORD"]
    poll_interval = int(os.environ.get("POLL_INTERVAL_SECONDS", "10"))
    metrics_port = int(os.environ.get("METRICS_PORT", "8000"))

    start_http_server(metrics_port)
    print(f"[exporter] serving metrics on :{metrics_port}, polling {host}:{port} every {poll_interval}s")

    client = None
    while True:
        try:
            if client is None:
                client = RconClient(host, port, password)
                client.connect()
                print("[exporter] connected to RCON")
            poll_once(client)
        except (RconError, ConnectionError, OSError, ValueError) as exc:
            print(f"[exporter] WARNING: poll failed ({exc}), will reconnect next cycle")
            if client is not None:
                client.close()
            client = None
        time.sleep(poll_interval)


if __name__ == "__main__":
    main()
```

- [ ] **Step 5: Run the tests and confirm they pass**

Run: `cd exporter && python3 test_exporter.py -v`
Expected: 5 tests, all `ok`.

- [ ] **Step 6: Commit**

```bash
git add exporter/exporter.py exporter/test_exporter.py exporter/requirements.txt
git commit -m "$(cat <<'EOF'
Add exporter metrics/polling logic with tests for the pure parsing functions

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Exporter Dockerfile + local build/boot verification

**Files:**
- Create: `exporter/Dockerfile`
- Create: `exporter/.dockerignore`

**Interfaces:**
- Consumes: `exporter/rcon.py`, `exporter/exporter.py`, `exporter/requirements.txt` (Tasks 1-2).
- Produces: a buildable image whose `CMD` runs `python3 exporter.py`, listening on port `8000`. Task 4's compose file references this image by the local build context `./exporter` (or, once published, the registry tag from Task 6 — either works, since compose can build from a Dockerfile directly).

- [ ] **Step 1: Write `exporter/.dockerignore`**

```
__pycache__
*.pyc
test_*.py
```

- [ ] **Step 2: Write `exporter/Dockerfile`**

```dockerfile
FROM python:3.13-slim

# Without this, Python block-buffers stdout when it isn't a TTY, so log
# output doesn't reach `docker logs` promptly — confirmed during design by
# running the exporter and finding its logs weren't flushed until exit.
ENV PYTHONUNBUFFERED=1

RUN useradd -u 1000 -m exporter
WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY rcon.py exporter.py .

USER exporter

EXPOSE 8000

CMD ["python3", "exporter.py"]
```

- [ ] **Step 3: Build the image locally**

Run:
```bash
docker build ./exporter -t factorio-exporter:local-test
```
Expected: build succeeds.

- [ ] **Step 4: Boot it against a real Factorio server and verify real metrics come through**

You need a running Factorio server reachable from wherever you run this (either the maintainer's Pi at `pepos.local:27015`, password from `.env` on the Pi, or your own locally-booted instance — see the main README's "Building locally" / "Quick start" sections if you need to start one). Run:

```bash
docker run -d --name exporter-verify \
  -p 8000:8000 \
  -e FACTORIO_HOST=<factorio-host> \
  -e RCON_PORT=27015 \
  -e RCON_PASSWORD=<rcon-password> \
  -e POLL_INTERVAL_SECONDS=5 \
  factorio-exporter:local-test

sleep 12
curl -s http://localhost:8000/metrics | grep -E "^factorio_"
docker logs exporter-verify
```

Expected: at least `factorio_tick_total` and `factorio_players_connected` appear with real, non-placeholder numeric values (confirmed during design: `factorio_tick_total 164302.0`, `factorio_players_connected 0.0` against the maintainer's Pi). `docker logs` shows `[exporter] connected to RCON` — if you only see the "serving metrics on..." line and nothing after, `PYTHONUNBUFFERED` isn't taking effect; double check Step 2.

- [ ] **Step 5: Clean up**

```bash
docker rm -f exporter-verify
docker rmi factorio-exporter:local-test
```

- [ ] **Step 6: Commit**

```bash
git add exporter/Dockerfile exporter/.dockerignore
git commit -m "$(cat <<'EOF'
Add exporter Dockerfile, verified building and serving real metrics against a live server

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Compose stack, Grafana/Prometheus/Loki/Promtail provisioning, dashboards, docs

**Files:**
- Create: `examples/docker-compose.observability.yml`
- Create: `examples/.env.observability.example`
- Create: `observability/prometheus.yml`
- Create: `observability/loki-config.yml`
- Create: `observability/promtail-config.yml`
- Create: `observability/grafana/provisioning/datasources/datasources.yml`
- Create: `observability/grafana/provisioning/dashboards/dashboards.yml`
- Create: `observability/grafana/dashboards/factorio-stats.json`
- Create: `observability/grafana/dashboards/factorio-logs.json`
- Modify: `README.md` (new section after the existing `## Running it on a Raspberry Pi 5` section, i.e. inserted before the `## Keeping a world running while you work` heading)

**Interfaces:**
- Consumes: `exporter/Dockerfile` build context (Task 3); the main image's existing `CONSOLE_LOG` env var (pre-existing, no change needed there).
- Produces: nothing consumed by later tasks — Task 5 and 6 touch CI files, independent of this task's contents beyond both referencing the same `exporter/` directory Task 3 already created.

- [ ] **Step 1: Write `observability/prometheus.yml`**

```yaml
global:
  scrape_interval: 15s

scrape_configs:
  - job_name: factorio-exporter
    static_configs:
      - targets: ["exporter:8000"]
```

- [ ] **Step 2: Write `observability/loki-config.yml`**

Verified booting cleanly and reaching `/ready` in ~20 seconds during design.

```yaml
auth_enabled: false

server:
  http_listen_port: 3100

common:
  path_prefix: /loki
  storage:
    filesystem:
      chunks_directory: /loki/chunks
      rules_directory: /loki/rules
  replication_factor: 1
  ring:
    kvstore:
      store: inmemory

schema_config:
  configs:
    - from: 2024-01-01
      store: tsdb
      object_store: filesystem
      schema: v13
      index:
        prefix: index_
        period: 24h
```

- [ ] **Step 3: Write `observability/promtail-config.yml`**

Verified shipping a real log line successfully to Loki during design.

```yaml
server:
  http_listen_port: 9080

positions:
  filename: /tmp/positions.yaml

clients:
  - url: http://loki:3100/loki/api/v1/push

scrape_configs:
  - job_name: factorio
    static_configs:
      - targets: [localhost]
        labels:
          job: factorio
          __path__: /var/log/factorio/console.log
```

- [ ] **Step 4: Write the Grafana provisioning files**

Create `observability/grafana/provisioning/datasources/datasources.yml`:

```yaml
apiVersion: 1

datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
  - name: Loki
    type: loki
    access: proxy
    url: http://loki:3100
```

Create `observability/grafana/provisioning/dashboards/dashboards.yml`:

```yaml
apiVersion: 1

providers:
  - name: factorio
    folder: Factorio
    type: file
    updateIntervalSeconds: 30
    options:
      path: /var/lib/grafana/dashboards
```

- [ ] **Step 5: Write the stats dashboard**

Create `observability/grafana/dashboards/factorio-stats.json`:

```json
{
  "title": "Factorio Stats",
  "schemaVersion": 39,
  "version": 1,
  "time": { "from": "now-1h", "to": "now" },
  "refresh": "10s",
  "panels": [
    {
      "id": 1,
      "title": "UPS",
      "type": "timeseries",
      "datasource": { "type": "prometheus", "uid": "Prometheus" },
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 0 },
      "targets": [
        { "expr": "rate(factorio_tick_total[1m])", "legendFormat": "UPS", "refId": "A" }
      ]
    },
    {
      "id": 2,
      "title": "Players Connected",
      "type": "stat",
      "datasource": { "type": "prometheus", "uid": "Prometheus" },
      "gridPos": { "h": 8, "w": 12, "x": 12, "y": 0 },
      "targets": [
        { "expr": "factorio_players_connected", "legendFormat": "Players", "refId": "A" }
      ]
    },
    {
      "id": 3,
      "title": "Item Production Rate",
      "type": "timeseries",
      "datasource": { "type": "prometheus", "uid": "Prometheus" },
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 8 },
      "targets": [
        { "expr": "rate(factorio_item_produced_total[5m])", "legendFormat": "{{item}}", "refId": "A" }
      ]
    },
    {
      "id": 4,
      "title": "Item Consumption Rate",
      "type": "timeseries",
      "datasource": { "type": "prometheus", "uid": "Prometheus" },
      "gridPos": { "h": 8, "w": 12, "x": 12, "y": 8 },
      "targets": [
        { "expr": "rate(factorio_item_consumed_total[5m])", "legendFormat": "{{item}}", "refId": "A" }
      ]
    },
    {
      "id": 5,
      "title": "Power Produced (W)",
      "type": "timeseries",
      "datasource": { "type": "prometheus", "uid": "Prometheus" },
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 16 },
      "targets": [
        { "expr": "rate(factorio_power_produced_joules_total[1m])", "legendFormat": "network {{network_id}}", "refId": "A" }
      ]
    },
    {
      "id": 6,
      "title": "Power Consumed (W)",
      "type": "timeseries",
      "datasource": { "type": "prometheus", "uid": "Prometheus" },
      "gridPos": { "h": 8, "w": 12, "x": 12, "y": 16 },
      "targets": [
        { "expr": "rate(factorio_power_consumed_joules_total[1m])", "legendFormat": "network {{network_id}}", "refId": "A" }
      ]
    }
  ]
}
```

- [ ] **Step 6: Write the logs dashboard**

Create `observability/grafana/dashboards/factorio-logs.json`:

```json
{
  "title": "Factorio Logs",
  "schemaVersion": 39,
  "version": 1,
  "time": { "from": "now-1h", "to": "now" },
  "refresh": "10s",
  "panels": [
    {
      "id": 1,
      "title": "Server Console",
      "type": "logs",
      "datasource": { "type": "loki", "uid": "Loki" },
      "gridPos": { "h": 20, "w": 24, "x": 0, "y": 0 },
      "targets": [
        { "expr": "{job=\"factorio\"}", "refId": "A" }
      ],
      "options": {
        "showTime": true,
        "sortOrder": "Descending",
        "wrapLogMessage": true
      }
    }
  ]
}
```

- [ ] **Step 7: Write the compose file**

Create `examples/docker-compose.observability.yml`:

```yaml
# Factorio + a full Grafana observability stack: factory/server stats via
# Prometheus, server logs via Loki. One `docker compose up -d` and both
# dashboards are already provisioned — no manual datasource or dashboard
# setup in the Grafana UI.
#
# The Stats dashboard can be made public (Grafana's built-in public-dashboard
# feature, a UI toggle on the dashboard's share menu) without exposing the
# Logs dashboard, which stays behind normal Grafana admin auth.

services:
  factorio:
    image: ghcr.io/aconti90/factorio-headless:stable
    container_name: factorio
    restart: unless-stopped

    ports:
      - "34197:34197/udp"
      - "127.0.0.1:27015:27015/tcp"

    volumes:
      - ./data:/factorio

    environment:
      RCON_PASSWORD: "${RCON_PASSWORD:?set RCON_PASSWORD in .env}"
      # Ships the server console to a file on the volume, which promtail
      # tails below. Existing entrypoint.sh support — no image change needed.
      CONSOLE_LOG: /factorio/console.log

  exporter:
    build: ../exporter
    container_name: factorio-exporter
    restart: unless-stopped
    depends_on:
      - factorio
    environment:
      FACTORIO_HOST: factorio
      RCON_PORT: "27015"
      RCON_PASSWORD: "${RCON_PASSWORD:?set RCON_PASSWORD in .env}"
      POLL_INTERVAL_SECONDS: "10"

  prometheus:
    image: prom/prometheus:v3.15.0
    container_name: factorio-prometheus
    restart: unless-stopped
    volumes:
      - ../observability/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - prometheus-data:/prometheus

  loki:
    image: grafana/loki:3.7.8
    container_name: factorio-loki
    restart: unless-stopped
    volumes:
      - ../observability/loki-config.yml:/etc/loki/local-config.yaml:ro
      - loki-data:/loki
    command: ["-config.file=/etc/loki/local-config.yaml"]

  promtail:
    image: grafana/promtail:3.6.8
    container_name: factorio-promtail
    restart: unless-stopped
    depends_on:
      - loki
    volumes:
      - ../observability/promtail-config.yml:/etc/promtail/config.yml:ro
      - ./data:/var/log/factorio:ro
    command: ["-config.file=/etc/promtail/config.yml"]

  grafana:
    image: grafana/grafana:13.2.2
    container_name: factorio-grafana
    restart: unless-stopped
    depends_on:
      - prometheus
      - loki
    ports:
      - "3000:3000"
    environment:
      GF_SECURITY_ADMIN_PASSWORD: "${GRAFANA_ADMIN_PASSWORD:?set GRAFANA_ADMIN_PASSWORD in .env}"
    volumes:
      - ../observability/grafana/provisioning:/etc/grafana/provisioning:ro
      - ../observability/grafana/dashboards:/var/lib/grafana/dashboards:ro
      - grafana-data:/var/lib/grafana

volumes:
  prometheus-data:
  loki-data:
  grafana-data:
```

- [ ] **Step 8: Write the env example**

Create `examples/.env.observability.example`:

```
# Copy to .env next to docker-compose.observability.yml and fill in.
#   cp .env.observability.example .env

# Required: shared between the factorio and exporter services.
RCON_PASSWORD=change-me

# Required: Grafana admin login. Change this from the default.
GRAFANA_ADMIN_PASSWORD=change-me
```

- [ ] **Step 9: Add the README section**

In `README.md`, insert this new section immediately after the existing `## Running it on a Raspberry Pi 5` section and before the `## Keeping a world running while you work` heading:

```markdown
## Observability: stats and logs dashboards

`examples/docker-compose.observability.yml` runs Factorio alongside a full
Grafana stack — Prometheus for factory/server stats (item production rates,
UPS, player count, power), Loki for readable server logs — with both
dashboards already provisioned:

```bash
cp examples/docker-compose.observability.yml docker-compose.yml
cp examples/.env.observability.example .env      # set RCON_PASSWORD and GRAFANA_ADMIN_PASSWORD
docker compose up -d
```

Open Grafana at `http://localhost:3000` (login with the admin password you
set) and both the **Factorio Stats** and **Factorio Logs** dashboards are
already there, under the "Factorio" folder — no manual datasource or
dashboard setup.

To share just the stats dashboard (e.g. on a public status page) without
exposing the logs dashboard or Grafana login access, use Grafana's built-in
public-dashboard feature: open the Stats dashboard, use the share menu's
"Public dashboard" option, and enable it. The Logs dashboard stays behind
normal Grafana authentication.

The exporter polls Factorio over RCON, so it needs the same `RCON_PASSWORD`
the `factorio` service uses — no separate credential.
```

- [ ] **Step 10: Build the exporter and validate the full compose file locally**

Run:
```bash
docker build ./exporter -t factorio-exporter:local-test
cd examples
cp .env.observability.example .env
# edit .env: set real RCON_PASSWORD and GRAFANA_ADMIN_PASSWORD
docker compose -f docker-compose.observability.yml --env-file .env config
```
Expected: valid merged config printed, no errors. This only validates the YAML — Step 11 actually boots it.

- [ ] **Step 11: Boot the full stack and verify end-to-end**

```bash
docker compose -f docker-compose.observability.yml --env-file .env up -d
sleep 45   # Loki takes ~20s to become ready; give the whole stack margin
curl -s -u admin:<your-grafana-admin-password> http://localhost:3000/api/search | python3 -m json.tool
```
Expected: JSON listing both "Factorio Stats" and "Factorio Logs" dashboards under a "Factorio" folder (verified working during design with this exact provisioning structure). Then:
```bash
curl -s -u admin:<your-grafana-admin-password> http://localhost:3000/api/datasources | python3 -m json.tool
```
Expected: both "Prometheus" and "Loki" datasources listed.

- [ ] **Step 12: Clean up**

```bash
docker compose -f docker-compose.observability.yml --env-file .env down -v
docker rmi factorio-exporter:local-test
```

- [ ] **Step 13: Commit**

```bash
git add examples/docker-compose.observability.yml examples/.env.observability.example \
  observability/ README.md
git commit -m "$(cat <<'EOF'
Add observability compose stack: Prometheus/Loki/Grafana with provisioned dashboards

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: CI integration test for the exporter

**Files:**
- Modify: `.github/workflows/ci.yml` (extend the existing `build-smoke` job)

**Interfaces:**
- Consumes: `exporter/Dockerfile` (Task 3) — this job builds it directly, no dependency on Task 4's compose file or Task 6's published image.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Add exporter build + integration steps to the smoke test job**

In `.github/workflows/ci.yml`, the `build-smoke` job currently ends with the "Smoke test — server boots..." step. Add these two new steps immediately after it (after the existing `docker logs factorio-ci | tail -20` line, staying inside the same job so it reuses the already-running `factorio-ci` container):

```yaml
      - name: Build exporter image
        uses: docker/build-push-action@v7
        with:
          context: ./exporter
          push: false
          load: true
          tags: factorio-exporter:ci
          cache-from: type=gha
          cache-to: type=gha,mode=max

      - name: Exporter integration test — real metrics from the running server
        run: |
          set -euo pipefail
          docker run -d --name exporter-ci \
            --network container:factorio-ci \
            -e FACTORIO_HOST=127.0.0.1 \
            -e RCON_PASSWORD=ci-test \
            -e POLL_INTERVAL_SECONDS=5 \
            factorio-exporter:ci

          for i in $(seq 1 12); do
            if curl -sf http://127.0.0.1:8000/metrics >/dev/null; then break; fi
            sleep 5
          done

          metrics="$(curl -sf http://127.0.0.1:8000/metrics)"
          echo "${metrics}" | grep -q '^factorio_tick_total' || {
            echo "factorio_tick_total missing from exporter output"; echo "${metrics}"; exit 1; }
          echo "${metrics}" | grep -q '^factorio_players_connected' || {
            echo "factorio_players_connected missing from exporter output"; echo "${metrics}"; exit 1; }

          docker logs exporter-ci
          docker rm -f exporter-ci
```

Note: `--network container:factorio-ci` puts the exporter container inside the same network namespace as the already-running `factorio-ci` container from the smoke test above, so `FACTORIO_HOST=127.0.0.1` reaches its RCON port directly — no separate Docker network or compose setup needed for this test.

- [ ] **Step 2: Validate the YAML**

Run: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/ci.yml'))"`
Expected: no output (valid YAML).

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "$(cat <<'EOF'
Add exporter integration test to CI: real metrics from a real running server

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: CI publish workflow for the exporter image

**Files:**
- Create: `.github/workflows/exporter-build.yml`

**Interfaces:**
- Consumes: `exporter/Dockerfile` (Task 3).
- Produces: nothing consumed by later tasks — this is the last task.

- [ ] **Step 1: Write the workflow**

Create `.github/workflows/exporter-build.yml`:

```yaml
name: Build & publish exporter

# Deliberately simpler than build.yml: the exporter has no upstream release
# to track, so none of that workflow's version-probing/architecture-discovery
# logic applies here. Just build and publish on every change to exporter/.
on:
  push:
    branches: [main]
    paths:
      - 'exporter/**'
      - '.github/workflows/exporter-build.yml'
  workflow_dispatch: {}

env:
  REGISTRY: ghcr.io

jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write

    steps:
      - uses: actions/checkout@v7

      - name: Compute image name
        id: image
        run: echo "name=${REGISTRY}/${GITHUB_REPOSITORY,,}-exporter" >> "$GITHUB_OUTPUT"

      - uses: docker/setup-qemu-action@v4
        with:
          platforms: arm64

      - uses: docker/setup-buildx-action@v4

      - uses: docker/login-action@v4
        with:
          registry: ${{ env.REGISTRY }}
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Log in to Docker Hub
        if: vars.DOCKERHUB_USERNAME != ''
        uses: docker/login-action@v3
        with:
          username: ${{ vars.DOCKERHUB_USERNAME }}
          password: ${{ secrets.DOCKERHUB_TOKEN }}

      - name: Derive tags
        id: tags
        env:
          GHCR_IMAGE: ${{ steps.image.outputs.name }}
          DOCKERHUB_USERNAME: ${{ vars.DOCKERHUB_USERNAME }}
        run: |
          set -euo pipefail
          repo_name="${GITHUB_REPOSITORY#*/}"
          sha_short="${GITHUB_SHA:0:7}"

          images=("${GHCR_IMAGE}")
          if [ -n "${DOCKERHUB_USERNAME}" ]; then
            images+=("${DOCKERHUB_USERNAME,,}/${repo_name,,}-exporter")
          fi

          tags=""
          for image in "${images[@]}"; do
            img_tags="${image}:latest,${image}:${sha_short}"
            tags="${tags:+${tags},}${img_tags}"
          done

          echo "tags=${tags}" >> "$GITHUB_OUTPUT"
          echo "Tagging: ${tags}"

      - name: Build and push
        uses: docker/build-push-action@v7
        with:
          context: ./exporter
          platforms: linux/amd64,linux/arm64
          push: true
          tags: ${{ steps.tags.outputs.tags }}
          cache-from: type=gha
          cache-to: type=gha,mode=max
```

- [ ] **Step 2: Validate the YAML**

Run: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/exporter-build.yml'))"`
Expected: no output.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/exporter-build.yml
git commit -m "$(cat <<'EOF'
Add CI workflow to build and publish the exporter image

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review Notes

- **Spec coverage:** RCON client (Task 1), exporter metrics/polling using the verified cumulative-counter pattern (Task 2), exporter packaging with a real live-server boot verification (Task 3), full compose stack with all four provisioning/dashboard pieces plus the `CONSOLE_LOG`-based logs pipeline and README docs (Task 4), CI integration test proving real metrics flow in CI (Task 5), exporter publish workflow (Task 6) — every component in the design spec maps to a task. The public-dashboard exposure-control mechanism is documented in Task 4's README section (Step 9); the API call itself is a one-time manual UI action by the operator, not something to automate, matching the spec.
- **Placeholder scan:** no TBD/TODO; every step has literal file content or an exact command with a stated expected result, including real values observed during design (e.g. `factorio_tick_total 164302.0`) as verification anchors.
- **Type/name consistency:** metric names (`factorio_item_produced_total`, `factorio_item_consumed_total`, `factorio_tick_total`, `factorio_players_connected`, `factorio_power_produced_joules_total`, `factorio_power_consumed_joules_total`) are identical across Task 2's implementation, Task 2's tests, Task 4's dashboard JSON PromQL queries, and Task 5's CI assertions. `RconClient`/`RconError` are used identically in Task 1 and Task 2. The Grafana datasource names (`Prometheus`, `Loki`) match between Task 4's `datasources.yml` and the `uid` references in both dashboard JSON files.
- **Version pins verified, not assumed:** every third-party image tag in this plan (`prom/prometheus:v3.15.0`, `grafana/loki:3.7.8`, `grafana/promtail:3.6.8`, `grafana/grafana:13.2.2`) was pulled and actually booted during design — including catching that Prometheus's tags need a `v` prefix while the others don't, which would otherwise have been a silent `docker build`/`pull` failure discovered only at implementation time.
