# Factorio observability stack: Grafana dashboards for stats and logs

## Problem

Nobody running this image — including the maintainer, running a real server
on a Raspberry Pi 5 — has any visibility into what their factory is actually
doing beyond `docker logs`. The established competing image
(`factoriotools/factorio-docker`) has no observability story either. Factory
production stats, server performance (UPS), and readable server logs are all
things a self-hoster genuinely wants, and none of it exists today.

Factorio's RCON interface (already exposed by this image) gives access to
the game's Lua API, which exposes exactly the data needed: item production
statistics, tick count, connected player count, and per-network power flow.
This was verified live against a real running server (Factorio 2.1.20,
arm64, on the maintainer's Pi 5) during design — every API call this spec
relies on was actually executed over RCON and its real response inspected,
not assumed from documentation.

## Goal

A `docker compose up` that gets you Factorio plus a working Grafana instance
with two pre-provisioned dashboards: factory/server stats (item production
rates, UPS, player count, power) and server logs — with the stats dashboard
independently shareable (e.g. on a public status page) without exposing the
logs dashboard.

## Non-goals

- **Changes to the main `factorio-headless` image.** Everything here is new,
  additive components plus one existing-but-unused env var (`CONSOLE_LOG`)
  turned on in the compose example. The main image, its entrypoint, and its
  CI/publishing pipeline are untouched.
- **Historical/long-term metric retention tuning.** Prometheus and Loki ship
  with their own sane defaults; this spec doesn't attempt to configure
  custom retention policies, downsampling, or remote-write. An operator who
  wants that can change the provided config themselves.
- **Authentication/TLS for the bundled Prometheus, Loki, or Grafana beyond
  Grafana's own built-in admin auth.** These services are designed to run on
  a private network or behind the operator's own reverse proxy, same as the
  main image's RCON port is today.
- **A generic "any Factorio server" exporter.** This is built and tested
  specifically against this repo's image and its `CONSOLE_LOG`/RCON
  conventions.

## Verified technical foundation

All of the following was executed live over RCON against a real server
during design, not assumed:

- Factorio 2.0+ moved JSON encoding from `game.table_to_json` to
  `helpers.table_to_json` — the old name no longer exists.
- `game.forces.player.get_item_production_statistics(surface)` returns an
  object with `.input_counts` (items produced, cumulative) and
  `.output_counts` (items consumed, cumulative) — both single calls
  returning every item at once as a `{item_name: count}` table.
- `.get_flow_count{name=, category=, precision_index=, count=}` exists as an
  alternative windowed-rate query, but requires `category` (`'input'` /
  `'output'`), not the `input=true`/`input=false` boolean some older
  documentation implies. Not used in this design — see "Metrics format"
  below for why cumulative counters were chosen instead.
- Any entity connected to a power network exposes
  `.electric_network_statistics` (same `.input_counts`/`.output_counts`
  shape as item stats) and a stable `.electric_network_id`, which lets the
  exporter deduplicate multiple poles reporting the same network.
- `game.tick` and `#game.connected_players` are both plain, cheap globals.

## Architecture

Two new independent pieces, both driven by the same existing RCON interface
and `CONSOLE_LOG` file the main image already supports:

```
                    ┌─────────────────────────────────────────┐
                    │              factorio (existing image)   │
                    │  RCON :27015          CONSOLE_LOG file →  │
                    └──────┬─────────────────────┬─────────────┘
                           │                      │
                  polls via RCON          tails log file (shared volume)
                           │                      │
                    ┌──────▼──────┐        ┌──────▼──────┐
                    │  exporter    │        │  promtail    │
                    │ (new image)  │        │ (official)   │
                    │ :8000/metrics│        └──────┬───────┘
                    └──────┬───────┘               │
                            scraped by              ships to
                    ┌──────▼───────┐        ┌──────▼───────┐
                    │  prometheus   │        │    loki       │
                    │  (official)   │        │  (official)   │
                    └──────┬───────┘        └──────┬───────┘
                            │  both queried by Grafana  │
                            └────────────┬────────────┘
                                   ┌──────▼───────┐
                                   │   grafana     │
                                   │ Stats (public)│
                                   │ Logs (private)│
                                   └───────────────┘
```

## Component 1: the exporter (new image)

New `exporter/` directory: `exporter/Dockerfile` (`python:3.13-slim`, one
dependency — `prometheus_client`), `exporter/exporter.py`.

**Behavior:** on an interval (`POLL_INTERVAL_SECONDS`, default 10), connects
to Factorio's RCON (`FACTORIO_HOST`, `RCON_PORT` default 27015,
`RCON_PASSWORD` — the same value the `factorio` service already uses), runs
a small set of Lua queries via `/sc`, and updates Prometheus metrics served
on `:8000/metrics` via `prometheus_client.start_http_server`.

**Metrics — all cumulative counters, no exporter-side rate math:**

| Metric | Type | Labels | Source |
|---|---|---|---|
| `factorio_item_produced_total` | Counter | `item` | `get_item_production_statistics(surface).input_counts` |
| `factorio_item_consumed_total` | Counter | `item` | same object's `.output_counts` |
| `factorio_tick_total` | Counter | — | `game.tick` |
| `factorio_players_connected` | Gauge | — | `#game.connected_players` |
| `factorio_power_produced_joules_total` | Counter | `network_id` | one pole's `.electric_network_statistics.input_counts`, deduped by `.electric_network_id` |
| `factorio_power_consumed_joules_total` | Counter | `network_id` | same object's `.output_counts` |

**Why cumulative counters, not `get_flow_count`'s windowed rates:** Prometheus's
whole model is built around exposing monotonic counters and letting the
query layer compute rates (`rate(factorio_item_produced_total[5m])` in
PromQL) — this is the idiomatic pattern, and it means the exporter needs no
state between polls at all. `get_flow_count` was verified working but would
require one RCON call per item per direction per poll (an N+1 problem for a
base producing many item types); `.input_counts`/`.output_counts` returns
every item in one call regardless of how many there are, so poll cost stays
flat as the factory grows.

**Connection resilience:** if RCON isn't reachable yet (Factorio still
booting) or a poll fails, the exporter logs a warning and retries on the
next interval rather than crashing — matches the main image's own
"one failure shouldn't take the whole thing down" philosophy.

## Component 2: logs via the existing `CONSOLE_LOG` support

No new code in the main image. The compose example sets
`CONSOLE_LOG=/factorio/console.log` on the `factorio` service — an env var
`entrypoint.sh` already wires straight into `--console-log`. `promtail`
(official `grafana/promtail` image) mounts the same named volume read-only
and tails that file, shipping it to `loki` (official `grafana/loki` image,
single-node filesystem storage — no external dependencies).

## Component 3: the compose stack and Grafana provisioning

New `examples/docker-compose.observability.yml` with six services:
`factorio`, `exporter`, `prometheus`, `loki`, `promtail`, `grafana`.

New `observability/` directory, one small config file per service rather
than one large blob:

```
observability/
  prometheus.yml                                    # scrapes exporter:8000
  loki-config.yml                                    # single-node, filesystem storage
  promtail-config.yml                                 # tails the shared CONSOLE_LOG file
  grafana/provisioning/datasources/datasources.yml     # Prometheus + Loki, auto-registered
  grafana/provisioning/dashboards/dashboards.yml        # provider pointing at the folder below
  grafana/dashboards/factorio-stats.json
  grafana/dashboards/factorio-logs.json
```

Grafana's own state (admin credentials, the public-dashboard flag on the
Stats dashboard) persists on its own named volume, so it survives restarts
without needing to be re-configured through the UI each time.

**Exposure control:** the Stats dashboard is marked public via Grafana's
built-in public-dashboard feature (a UI/API toggle, not a separate
deployment) so it can be shared without exposing Grafana login access. The
Logs dashboard is left private, behind Grafana's normal admin
authentication — the compose file requires the operator to set a real
Grafana admin password via `.env`, same pattern as `RCON_PASSWORD` today.

## CI / publishing for the exporter image

A new, deliberately simpler workflow, `exporter-build.yml`, separate from
the main `build.yml`. The exporter has no upstream release to track — none
of `build.yml`'s version-probing/architecture-discovery logic applies.
Triggers on pushes to `main` touching `exporter/**`, builds a native
multi-arch image (amd64 + arm64 — directly useful, since this was verified
on a Pi), and publishes `:latest` plus a short-sha tag to both GHCR and
Docker Hub, matching the main image's dual-registry publishing.

## Testing

- **Unit tests** (Python stdlib `unittest`, no new test framework
  dependency) for the exporter's pure logic: RCON packet encode/decode
  (the same protocol prototyped and verified live against the Pi during
  design) and metric-value extraction from RCON responses.
- **A real CI integration test** — stronger than what was possible for the
  mod-auto-update feature, because here both ends are under this repo's
  control: `ci.yml`'s existing smoke test (which already boots a real
  Factorio container and waits for its healthcheck) is extended to also
  boot the exporter pointed at that same container, wait for its
  `/metrics` endpoint, and curl it to confirm valid Prometheus text
  exposition format with the expected metric names present. No third-party
  dependency in the loop, so this runs in CI rather than being deferred to
  manual verification.
- `docker compose config` validation for the new compose file (same pattern
  `scripts/lint.sh` already uses for the other examples), plus a JSON
  syntax check on the two dashboard files and the Grafana/Prometheus/Loki
  config files.
