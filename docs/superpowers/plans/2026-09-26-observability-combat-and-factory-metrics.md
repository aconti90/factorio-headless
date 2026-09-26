# Observability Combat and Factory Metrics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the existing Factorio exporter and Grafana dashboard with combat metrics (kills, losses, turret ammo/power health) and broader factory metrics (evolution factor, research progress, pollution, fluid throughput, entity-build counts).

**Architecture:** Pure extension of the existing single-file exporter (`exporter/exporter.py`) — new Prometheus collectors, new Lua RCON commands, new parsing functions, all following the exact patterns already established (cumulative counters via `.labels(...)._value.set()`, the existing `_GLOBALS_COMMAND` gains four new cheap single-value fields rather than becoming separate round-trips). New panels on the existing `factorio-stats.json` dashboard. No new files, no new services, no architecture changes.

**Tech Stack:** Same as the existing exporter — Python stdlib, `prometheus_client`, the existing RCON client (`exporter/rcon.py`, unmodified by this plan).

## Global Constraints

- Every new metric is a Counter (cumulative, `.labels(...)._value.set()`, never `.inc()`) or a Gauge (instantaneous, `.set()`), matching the existing convention exactly.
- `LuaForce.get_kill_count_statistics(surface)`, not `.kills` — the latter doesn't exist (confirmed live: errors with "doesn't contain key kills").
- `LuaForce.get_evolution_factor(surface)`, not `.evolution_factor` — the latter doesn't exist either (confirmed live: same error class).
- `input_counts` = this force's own actions (kills made, fluid produced); `output_counts` = the reverse (this force's own losses, fluid consumed) — same convention as every existing flow-statistics metric, verified live for kills specifically (a synthetic kill "by" the player force landed in `input_counts`; a synthetic loss "by" the enemy force landed in `output_counts`).
- Turret ammo/power status is exposed as an aggregate count (`factorio_turrets_without_ammo`, `factorio_turrets_without_power`) — no per-turret Prometheus labels. When either is nonzero, the exporter logs the specific turret position(s) via `print(...)` (visible in `docker logs` / the Logs dashboard), matching the existing log style (`[exporter] ...` prefix).
- No new credential env vars, no new files, no new services — this plan only modifies `exporter/exporter.py`, `exporter/test_exporter.py`, `observability/grafana/dashboards/factorio-stats.json`, and `.github/workflows/ci.yml`.
- `parse_globals`'s return type changes from a 2-tuple `(tick, players)` to a dict with keys `tick`, `players`, `evolution`, `research`, `research_progress`, `pollution` — this is an intentional, in-place change to an existing internal function (not a new parallel function), since the design spec explicitly folds these new fields into the existing `_GLOBALS_COMMAND` rather than adding separate round-trips. The existing `test_parse_globals` test and its one call site in `poll_once` both need updating to match — this is expected, not a regression.

---

### Task 1: Kills, losses, and turret ammo/power metrics

**Files:**
- Modify: `exporter/exporter.py` (add new collectors, Lua commands, parsing functions; extend `poll_once`)
- Modify: `exporter/test_exporter.py` (add tests for the new parsing functions)

**Interfaces:**
- Consumes: `client.command(str) -> str` from `exporter.rcon.RconClient` (unchanged, already in use elsewhere in this file).
- Produces: `parse_kill_stats(response) -> (dict, dict)`, `parse_turret_status(response) -> (list, list)`. Task 4's CI check doesn't depend on these directly (it checks `factorio_evolution_factor`/`factorio_pollution` from Task 2), so this task has no downstream consumers within this plan — it's independently complete and testable.

- [ ] **Step 1: Write the failing tests**

Add this new test class to `exporter/test_exporter.py`, right after the existing `TestParsing` class's last method (`test_parse_power_stats_empty`) and its blank line, before the `if __name__ == "__main__":` block. Also add `parse_kill_stats, parse_turret_status` to the existing `from exporter import ...` line at the top of the file, so it reads:

```python
from exporter import parse_globals, parse_item_stats, parse_kill_stats, parse_power_stats, parse_turret_status
```

New test class:

```python
class TestKillAndTurretParsing(unittest.TestCase):
    def test_parse_kill_stats(self):
        response = json.dumps({"input": {"small-biter": 3}, "output": {"stone-wall": 1}})
        kills_in, kills_out = parse_kill_stats(response)
        self.assertEqual(kills_in, {"small-biter": 3})
        self.assertEqual(kills_out, {"stone-wall": 1})

    def test_parse_kill_stats_empty(self):
        self.assertEqual(parse_kill_stats(json.dumps({"input": {}, "output": {}})), ({}, {}))

    def test_parse_turret_status(self):
        response = json.dumps({"no_ammo": [{"x": 30, "y": 30}], "no_power": []})
        no_ammo, no_power = parse_turret_status(response)
        self.assertEqual(no_ammo, [{"x": 30, "y": 30}])
        self.assertEqual(no_power, [])

    def test_parse_turret_status_empty(self):
        self.assertEqual(parse_turret_status(json.dumps({"no_ammo": [], "no_power": []})), ([], []))
```

- [ ] **Step 2: Run the tests and confirm they fail**

Run: `cd exporter && python3 test_exporter.py`
Expected: FAIL — `ImportError: cannot import name 'parse_kill_stats' from 'exporter'` (the functions don't exist yet).

- [ ] **Step 3: Add the new collectors, Lua commands, and parsing functions**

In `exporter/exporter.py`, immediately after the existing collector declarations (after the `POWER_CONSUMED = Counter(...)` line and before the `# All three commands verified live...` comment), insert:

```python
KILLS = Counter("factorio_kills_total", "Cumulative enemy entities killed by this force", ["entity"])
LOSSES = Counter("factorio_losses_total", "Cumulative entities of this force destroyed", ["entity"])
TURRETS_WITHOUT_AMMO = Gauge("factorio_turrets_without_ammo", "Ammo turrets currently out of ammo")
TURRETS_WITHOUT_POWER = Gauge("factorio_turrets_without_power", "Electric turrets currently out of power")
```

Then, after the existing `_POWER_COMMAND = (...)` block (after its closing `)`), insert:

```python

# Verified live: a synthetic kill "by" the player force landed in input_counts;
# a synthetic loss "by" the enemy force landed in output_counts.
_KILL_STATS_COMMAND = (
    "/sc local stats = game.forces.player.get_kill_count_statistics(game.surfaces[1]) "
    "rcon.print(helpers.table_to_json({input=stats.input_counts, output=stats.output_counts}))"
)

# Verified live: an unloaded ammo turret's turret_ammo inventory reports
# is_empty() == true; an unpowered electric turret's .energy reads 0.
_TURRET_STATUS_COMMAND = (
    "/sc local no_ammo = {} local no_power = {} "
    "for _, t in pairs(game.surfaces[1].find_entities_filtered{type='ammo-turret'}) do "
    "if t.get_inventory(defines.inventory.turret_ammo).is_empty() then "
    "table.insert(no_ammo, {x=t.position.x, y=t.position.y}) end end "
    "for _, t in pairs(game.surfaces[1].find_entities_filtered{type='electric-turret'}) do "
    "if t.energy == 0 then table.insert(no_power, {x=t.position.x, y=t.position.y}) end end "
    "rcon.print(helpers.table_to_json({no_ammo=no_ammo, no_power=no_power}))"
)
```

Then, after the existing `parse_power_stats` function definition (after its closing `}` and blank line), insert:

```python
def parse_kill_stats(response):
    """Parses the JSON body of _KILL_STATS_COMMAND into (input_counts, output_counts) dicts."""
    data = json.loads(response)
    return data.get("input", {}), data.get("output", {})


def parse_turret_status(response):
    """Parses the JSON body of _TURRET_STATUS_COMMAND into (no_ammo_positions, no_power_positions) lists of {x, y} dicts."""
    data = json.loads(response)
    return data.get("no_ammo", []), data.get("no_power", [])
```

- [ ] **Step 4: Extend `poll_once` to call the new commands**

In `exporter/exporter.py`, in `poll_once`, after the existing power-stats block (the `for network_id, (power_in, power_out) in parse_power_stats(...)` loop and its two `.labels(...)` lines) and before the function's closing (there is no explicit `return` — the function just ends), insert:

```python

    kills_in, kills_out = parse_kill_stats(client.command(_KILL_STATS_COMMAND))
    for entity_name, count in kills_in.items():
        KILLS.labels(entity=entity_name)._value.set(count)
    for entity_name, count in kills_out.items():
        LOSSES.labels(entity=entity_name)._value.set(count)

    no_ammo, no_power = parse_turret_status(client.command(_TURRET_STATUS_COMMAND))
    TURRETS_WITHOUT_AMMO.set(len(no_ammo))
    TURRETS_WITHOUT_POWER.set(len(no_power))
    for pos in no_ammo:
        print(f"[exporter] turret out of ammo at ({pos['x']}, {pos['y']})")
    for pos in no_power:
        print(f"[exporter] turret out of power at ({pos['x']}, {pos['y']})")
```

- [ ] **Step 5: Run the tests and confirm they pass**

Run: `cd exporter && python3 test_exporter.py -v`
Expected: all tests pass, including the 4 new ones (`test_parse_kill_stats`, `test_parse_kill_stats_empty`, `test_parse_turret_status`, `test_parse_turret_status_empty`).

- [ ] **Step 6: Verify against the real running server**

You need a running Factorio server reachable from wherever you run this — either the maintainer's Pi (RCON reachable via `docker exec -it factorio-exporter python3 ...` from the Pi itself, matching how this was verified during design) or your own local instance. Build and boot the exporter the same way Task 3 of the original observability plan did:

```bash
docker build ./exporter -t factorio-exporter:task1-verify
docker run -d --name exporter-task1-verify \
  -p 8000:8000 \
  -e FACTORIO_HOST=<factorio-host> \
  -e RCON_PORT=27015 \
  -e RCON_PASSWORD=<rcon-password> \
  -e POLL_INTERVAL_SECONDS=5 \
  factorio-exporter:task1-verify

sleep 12
curl -s http://localhost:8000/metrics | grep -E "^factorio_(kills|losses|turrets)_"
docker logs exporter-task1-verify
```

Expected: `factorio_turrets_without_ammo` and `factorio_turrets_without_power` appear with real numeric values (likely `0.0` unless the real base actually has an empty/unpowered turret right now — either is a valid, real result). `factorio_kills_total`/`factorio_losses_total` will only show entries if the force has actually made a kill or lost something since the game started — an empty result (no `factorio_kills_total` lines at all) is expected and correct on a base with no combat history yet, since Prometheus Counters with labels don't appear in `/metrics` until `.labels(...)` has been called at least once with that label value.

- [ ] **Step 7: Clean up**

```bash
docker rm -f exporter-task1-verify
docker rmi factorio-exporter:task1-verify
```

- [ ] **Step 8: Commit**

```bash
git add exporter/exporter.py exporter/test_exporter.py
git commit -m "$(cat <<'EOF'
Add kills/losses and turret ammo/power metrics to the exporter

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Evolution, research, pollution, fluid throughput, and entity-build metrics

**Files:**
- Modify: `exporter/exporter.py` (extend `_GLOBALS_COMMAND`/`parse_globals`; add new collectors, commands, parsing functions; extend `poll_once`)
- Modify: `exporter/test_exporter.py` (replace the existing `test_parse_globals` test to match the new dict return shape; add tests for the new parsing functions)

**Interfaces:**
- Consumes: `client.command(str) -> str` (unchanged). Does not depend on Task 1 — both tasks independently extend `poll_once` and can be implemented in either order, but this plan sequences Task 2 after Task 1 for a cleaner diff history.
- Produces: `parse_globals(response) -> dict` with keys `tick` (int), `players` (int), `evolution` (float), `research` (str, `""` if none), `research_progress` (float), `pollution` (float) — **this changes the existing function's return type from a 2-tuple to a dict.** `parse_fluid_stats(response) -> (dict, dict)`. `parse_entity_build_stats(response) -> dict`. Task 4 consumes `factorio_evolution_factor` and `factorio_pollution` by name (defined in this task) for its CI check.

- [ ] **Step 1: Write the failing tests**

In `exporter/test_exporter.py`, first update the import line (from Task 1) to also import the new functions:

```python
from exporter import (
    parse_entity_build_stats,
    parse_fluid_stats,
    parse_globals,
    parse_item_stats,
    parse_kill_stats,
    parse_power_stats,
    parse_turret_status,
)
```

Then **replace** the existing `test_parse_globals` method (inside `TestParsing`, currently reading `tick, players = parse_globals(response)`) with:

```python
    def test_parse_globals(self):
        response = json.dumps({
            "tick": 164302,
            "players": 2,
            "evolution": 0.1565,
            "research": "automation-2",
            "research_progress": 0.42,
            "pollution": 802.78,
        })
        data = parse_globals(response)
        self.assertEqual(data["tick"], 164302)
        self.assertEqual(data["players"], 2)
        self.assertAlmostEqual(data["evolution"], 0.1565)
        self.assertEqual(data["research"], "automation-2")
        self.assertAlmostEqual(data["research_progress"], 0.42)
        self.assertAlmostEqual(data["pollution"], 802.78)

    def test_parse_globals_no_research(self):
        response = json.dumps({
            "tick": 1,
            "players": 0,
            "evolution": 0.0,
            "research": "",
            "research_progress": 0.0,
            "pollution": 0.0,
        })
        data = parse_globals(response)
        self.assertEqual(data["research"], "")
```

Then add this new test class after `TestKillAndTurretParsing` (from Task 1), before `if __name__ == "__main__":`:

```python
class TestFactoryWideParsing(unittest.TestCase):
    def test_parse_fluid_stats(self):
        response = json.dumps({"input": {"water": 16456.2}, "output": {"steam": 161162.7}})
        fluid_in, fluid_out = parse_fluid_stats(response)
        self.assertEqual(fluid_in, {"water": 16456.2})
        self.assertEqual(fluid_out, {"steam": 161162.7})

    def test_parse_fluid_stats_empty(self):
        self.assertEqual(parse_fluid_stats(json.dumps({"input": {}, "output": {}})), ({}, {}))

    def test_parse_entity_build_stats(self):
        response = json.dumps({"transport-belt": 530, "stone-wall": 134})
        self.assertEqual(parse_entity_build_stats(response), {"transport-belt": 530, "stone-wall": 134})

    def test_parse_entity_build_stats_empty(self):
        self.assertEqual(parse_entity_build_stats(json.dumps({})), {})
```

- [ ] **Step 2: Run the tests and confirm they fail**

Run: `cd exporter && python3 test_exporter.py`
Expected: FAIL — either an `ImportError` (new functions don't exist) or a `KeyError`/`TypeError` from `test_parse_globals` (since `parse_globals` still returns a 2-tuple, not a dict).

- [ ] **Step 3: Extend `_GLOBALS_COMMAND` and `parse_globals`, add new collectors and commands**

In `exporter/exporter.py`, replace the existing `_GLOBALS_COMMAND` line:

```python
_GLOBALS_COMMAND = "/sc rcon.print(helpers.table_to_json({tick=game.tick, players=#game.connected_players}))"
```

with:

```python
# Evolution/research/pollution are cheap single-value reads, folded into this
# same command rather than becoming separate RCON round-trips.
_GLOBALS_COMMAND = (
    "/sc local research = game.forces.player.current_research "
    "rcon.print(helpers.table_to_json({"
    "tick=game.tick, players=#game.connected_players, "
    "evolution=game.forces.enemy.get_evolution_factor(game.surfaces[1]), "
    "research=research and research.name or '', "
    "research_progress=game.forces.player.research_progress, "
    "pollution=game.surfaces[1].get_total_pollution()"
    "}))"
)
```

Replace the existing `parse_globals` function:

```python
def parse_globals(response):
    """Parses the JSON body of _GLOBALS_COMMAND into (tick, players) ints."""
    data = json.loads(response)
    return int(data["tick"]), int(data["players"])
```

with:

```python
def parse_globals(response):
    """Parses the JSON body of _GLOBALS_COMMAND into a dict with keys tick (int),
    players (int), evolution (float), research (str, '' if none),
    research_progress (float), and pollution (float)."""
    data = json.loads(response)
    return {
        "tick": int(data["tick"]),
        "players": int(data["players"]),
        "evolution": float(data["evolution"]),
        "research": data["research"],
        "research_progress": float(data["research_progress"]),
        "pollution": float(data["pollution"]),
    }
```

Add these new collectors, immediately after the `TURRETS_WITHOUT_POWER = Gauge(...)` line added in Task 1:

```python
EVOLUTION_FACTOR = Gauge("factorio_evolution_factor", "Enemy evolution factor (0-1)")
RESEARCH_PROGRESS = Gauge("factorio_research_progress", "Progress of the currently active research (0-1)")
RESEARCH_ACTIVE = Gauge("factorio_research_active", "1 while this technology is the active research", ["technology"])
FLUID_PRODUCED = Counter("factorio_fluid_produced_total", "Cumulative fluid produced", ["fluid"])
FLUID_CONSUMED = Counter("factorio_fluid_consumed_total", "Cumulative fluid consumed", ["fluid"])
ENTITIES_BUILT = Counter("factorio_entities_built_total", "Cumulative entities ever built", ["entity"])
POLLUTION = Gauge("factorio_pollution", "Total pollution currently on the surface")

# Tracks the previously-active research so its factorio_research_active label
# can be reset to 0 when research moves on — the one piece of state in this
# otherwise-stateless exporter, needed because a Gauge label that's never
# explicitly reset stays stuck at its last value forever.
_last_active_research = None
```

Add these new Lua commands, after the `_TURRET_STATUS_COMMAND = (...)` block added in Task 1:

```python

_FLUID_STATS_COMMAND = (
    "/sc local stats = game.forces.player.get_fluid_production_statistics(game.surfaces[1]) "
    "rcon.print(helpers.table_to_json({input=stats.input_counts, output=stats.output_counts}))"
)

_ENTITY_BUILD_COMMAND = (
    "/sc local stats = game.forces.player.get_entity_build_count_statistics(game.surfaces[1]) "
    "rcon.print(helpers.table_to_json(stats.input_counts))"
)
```

Add these new parsing functions, after `parse_turret_status` (added in Task 1):

```python
def parse_fluid_stats(response):
    """Parses the JSON body of _FLUID_STATS_COMMAND into (input_counts, output_counts) dicts."""
    data = json.loads(response)
    return data.get("input", {}), data.get("output", {})


def parse_entity_build_stats(response):
    """Parses the JSON body of _ENTITY_BUILD_COMMAND into a {entity: count} dict."""
    return json.loads(response)
```

- [ ] **Step 4: Update `poll_once`'s existing globals call site, and add the new metric updates**

In `exporter/exporter.py`, `poll_once` currently has:

```python
    tick, players = parse_globals(client.command(_GLOBALS_COMMAND))
    TICK_TOTAL._value.set(tick)
    PLAYERS_CONNECTED.set(players)
```

Replace it with:

```python
    global _last_active_research
    globals_data = parse_globals(client.command(_GLOBALS_COMMAND))
    TICK_TOTAL._value.set(globals_data["tick"])
    PLAYERS_CONNECTED.set(globals_data["players"])
    EVOLUTION_FACTOR.set(globals_data["evolution"])
    RESEARCH_PROGRESS.set(globals_data["research_progress"])
    POLLUTION.set(globals_data["pollution"])

    current_research = globals_data["research"]
    if _last_active_research and _last_active_research != current_research:
        RESEARCH_ACTIVE.labels(technology=_last_active_research).set(0)
    if current_research:
        RESEARCH_ACTIVE.labels(technology=current_research).set(1)
    _last_active_research = current_research or None
```

Then, at the end of `poll_once` (after the turret-status block added in Task 1's Step 4), append:

```python

    fluid_in, fluid_out = parse_fluid_stats(client.command(_FLUID_STATS_COMMAND))
    for fluid_name, count in fluid_in.items():
        FLUID_PRODUCED.labels(fluid=fluid_name)._value.set(count)
    for fluid_name, count in fluid_out.items():
        FLUID_CONSUMED.labels(fluid=fluid_name)._value.set(count)

    for entity_name, count in parse_entity_build_stats(client.command(_ENTITY_BUILD_COMMAND)).items():
        ENTITIES_BUILT.labels(entity=entity_name)._value.set(count)
```

- [ ] **Step 5: Run the tests and confirm they pass**

Run: `cd exporter && python3 test_exporter.py -v`
Expected: all tests pass — `test_parse_globals` (updated), `test_parse_globals_no_research`, `test_parse_fluid_stats`, `test_parse_fluid_stats_empty`, `test_parse_entity_build_stats`, `test_parse_entity_build_stats_empty`, plus every test from Task 1 and the original exporter still passing.

- [ ] **Step 6: Verify against the real running server**

Same pattern as Task 1 Step 6:

```bash
docker build ./exporter -t factorio-exporter:task2-verify
docker run -d --name exporter-task2-verify \
  -p 8000:8000 \
  -e FACTORIO_HOST=<factorio-host> \
  -e RCON_PORT=27015 \
  -e RCON_PASSWORD=<rcon-password> \
  -e POLL_INTERVAL_SECONDS=5 \
  factorio-exporter:task2-verify

sleep 12
curl -s http://localhost:8000/metrics | grep -E "^factorio_(evolution|research|pollution|fluid|entities_built)_?"
docker logs exporter-task2-verify
```

Expected: `factorio_evolution_factor` and `factorio_pollution` show real nonzero numeric values on any base with existing enemy activity/production history. `factorio_entities_built_total` shows a real per-entity-type breakdown if anything has been built. `factorio_research_progress` and `factorio_research_active` reflect whatever is (or isn't) currently queued — both being absent/zero is valid if nothing is queued. `factorio_fluid_produced_total`/`factorio_fluid_consumed_total` show real water/steam (or other fluid) numbers if any fluid-handling entities exist.

- [ ] **Step 7: Clean up**

```bash
docker rm -f exporter-task2-verify
docker rmi factorio-exporter:task2-verify
```

- [ ] **Step 8: Commit**

```bash
git add exporter/exporter.py exporter/test_exporter.py
git commit -m "$(cat <<'EOF'
Add evolution, research, pollution, fluid, and entity-build metrics to the exporter

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Dashboard panels for the new metrics

**Files:**
- Modify: `observability/grafana/dashboards/factorio-stats.json`

**Interfaces:**
- Consumes: the exact metric names defined in Tasks 1-2 (`factorio_kills_total`, `factorio_losses_total`, `factorio_turrets_without_ammo`, `factorio_turrets_without_power`, `factorio_evolution_factor`, `factorio_research_active`, `factorio_research_progress`, `factorio_fluid_produced_total`, `factorio_fluid_consumed_total`, `factorio_entities_built_total`, `factorio_pollution`).
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Add the new panels**

The existing dashboard's last two panels (ids 5 and 6, "Power Produced (W)" and "Power Consumed (W)") end at `"gridPos": {"h": 8, "w": 12, "x": 12, "y": 16}`. In `observability/grafana/dashboards/factorio-stats.json`, find the closing `}` of panel id 6 (the last element currently in the `panels` array, right before the array's closing `]`), and insert these 10 new panel objects after it (add a comma after panel 6's closing `}` first):

```json
    {
      "id": 7,
      "title": "Kills",
      "type": "piechart",
      "datasource": { "type": "prometheus", "uid": "Prometheus" },
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 24 },
      "targets": [
        { "expr": "factorio_kills_total", "legendFormat": "{{entity}}", "refId": "A" }
      ]
    },
    {
      "id": 8,
      "title": "Losses",
      "type": "piechart",
      "datasource": { "type": "prometheus", "uid": "Prometheus" },
      "gridPos": { "h": 8, "w": 12, "x": 12, "y": 24 },
      "targets": [
        { "expr": "factorio_losses_total", "legendFormat": "{{entity}}", "refId": "A" }
      ]
    },
    {
      "id": 9,
      "title": "Turrets Without Ammo",
      "type": "stat",
      "datasource": { "type": "prometheus", "uid": "Prometheus" },
      "gridPos": { "h": 8, "w": 6, "x": 0, "y": 32 },
      "targets": [
        { "expr": "factorio_turrets_without_ammo", "legendFormat": "No ammo", "refId": "A" }
      ],
      "fieldConfig": {
        "defaults": {
          "thresholds": {
            "mode": "absolute",
            "steps": [
              { "color": "green", "value": null },
              { "color": "red", "value": 1 }
            ]
          }
        }
      }
    },
    {
      "id": 10,
      "title": "Turrets Without Power",
      "type": "stat",
      "datasource": { "type": "prometheus", "uid": "Prometheus" },
      "gridPos": { "h": 8, "w": 6, "x": 6, "y": 32 },
      "targets": [
        { "expr": "factorio_turrets_without_power", "legendFormat": "No power", "refId": "A" }
      ],
      "fieldConfig": {
        "defaults": {
          "thresholds": {
            "mode": "absolute",
            "steps": [
              { "color": "green", "value": null },
              { "color": "red", "value": 1 }
            ]
          }
        }
      }
    },
    {
      "id": 11,
      "title": "Evolution Factor",
      "type": "gauge",
      "datasource": { "type": "prometheus", "uid": "Prometheus" },
      "gridPos": { "h": 8, "w": 6, "x": 12, "y": 32 },
      "targets": [
        { "expr": "factorio_evolution_factor", "legendFormat": "Evolution", "refId": "A" }
      ],
      "fieldConfig": {
        "defaults": {
          "min": 0,
          "max": 1,
          "unit": "percentunit"
        }
      }
    },
    {
      "id": 12,
      "title": "Research",
      "type": "stat",
      "datasource": { "type": "prometheus", "uid": "Prometheus" },
      "gridPos": { "h": 8, "w": 6, "x": 18, "y": 32 },
      "targets": [
        { "expr": "factorio_research_active", "legendFormat": "{{technology}}", "refId": "A" },
        { "expr": "factorio_research_progress", "legendFormat": "Progress", "refId": "B" }
      ]
    },
    {
      "id": 13,
      "title": "Fluid Production Rate",
      "type": "timeseries",
      "datasource": { "type": "prometheus", "uid": "Prometheus" },
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 40 },
      "targets": [
        { "expr": "rate(factorio_fluid_produced_total[5m])", "legendFormat": "{{fluid}}", "refId": "A" }
      ]
    },
    {
      "id": 14,
      "title": "Fluid Consumption Rate",
      "type": "timeseries",
      "datasource": { "type": "prometheus", "uid": "Prometheus" },
      "gridPos": { "h": 8, "w": 12, "x": 12, "y": 40 },
      "targets": [
        { "expr": "rate(factorio_fluid_consumed_total[5m])", "legendFormat": "{{fluid}}", "refId": "A" }
      ]
    },
    {
      "id": 15,
      "title": "Entities Built",
      "type": "table",
      "datasource": { "type": "prometheus", "uid": "Prometheus" },
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 48 },
      "targets": [
        { "expr": "factorio_entities_built_total", "legendFormat": "{{entity}}", "refId": "A", "format": "table", "instant": true }
      ]
    },
    {
      "id": 16,
      "title": "Pollution",
      "type": "timeseries",
      "datasource": { "type": "prometheus", "uid": "Prometheus" },
      "gridPos": { "h": 8, "w": 12, "x": 12, "y": 48 },
      "targets": [
        { "expr": "factorio_pollution", "legendFormat": "Pollution", "refId": "A" }
      ]
    }
```

- [ ] **Step 2: Validate the JSON**

Run: `python3 -c "import json; json.load(open('observability/grafana/dashboards/factorio-stats.json'))"`
Expected: no output (valid JSON).

- [ ] **Step 3: Provision it into a real Grafana and verify the panels load without errors**

```bash
docker rm -f grafana-task3-verify 2>/dev/null
docker run -d --name grafana-task3-verify -p 3000:3000 \
  -e GF_SECURITY_ADMIN_PASSWORD=verify-test \
  -v "$(pwd)/observability/grafana/provisioning:/etc/grafana/provisioning:ro" \
  -v "$(pwd)/observability/grafana/dashboards:/var/lib/grafana/dashboards:ro" \
  grafana/grafana:13.2.2

sleep 10
curl -s -u admin:verify-test http://localhost:3000/api/search | python3 -m json.tool
```

Expected: JSON listing the "Factorio Stats" dashboard (this doesn't have a live Prometheus behind it, so panel *data* won't render, but this confirms Grafana parses the dashboard JSON without a provisioning error — check `docker logs grafana-task3-verify` for any `level=error` lines mentioning "factorio-stats" or a panel/schema problem if the search comes back empty).

- [ ] **Step 4: Clean up**

```bash
docker rm -f grafana-task3-verify
```

- [ ] **Step 5: Commit**

```bash
git add observability/grafana/dashboards/factorio-stats.json
git commit -m "$(cat <<'EOF'
Add combat and factory-wide panels to the Factorio Stats dashboard

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: CI integration test extension

**Files:**
- Modify: `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: `factorio_evolution_factor`, `factorio_pollution` (defined in Task 2) — chosen because they're guaranteed to have real numeric values on any server that's been running for even a few ticks, unlike kills/losses (which need actual combat history) or research/fluids (which need specific base setups) — the same reasoning the existing CI check already uses for `factorio_tick_total`/`factorio_players_connected`.
- Produces: nothing consumed by later tasks — this is the last task.

- [ ] **Step 1: Extend the exporter integration test step**

In `.github/workflows/ci.yml`, find the "Exporter integration test — real metrics from the running server" step. It currently ends with:

```yaml
          curl -sf http://127.0.0.1:8000/metrics | grep -q '^factorio_players_connected' || {
            echo "factorio_players_connected missing from exporter output"; exit 1; }
```

Immediately after that block (and before the `# Don't fail on a WARNING here...` comment / `docker logs exporter-ci` line that follows it), insert:

```bash

          metrics_final="$(curl -sf http://127.0.0.1:8000/metrics)"
          echo "${metrics_final}" | grep -q '^factorio_evolution_factor' || {
            echo "factorio_evolution_factor missing from exporter output"; exit 1; }
          echo "${metrics_final}" | grep -q '^factorio_pollution' || {
            echo "factorio_pollution missing from exporter output"; exit 1; }
```

- [ ] **Step 2: Validate the YAML**

Run: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/ci.yml'))"`
Expected: no output (valid YAML).

- [ ] **Step 3: Run the full local test suite one more time**

```bash
cd exporter && python3 test_rcon.py && python3 test_exporter.py -v
```
Expected: all tests pass (2 from `test_rcon.py`, plus every test in `test_exporter.py` across the original file and Tasks 1-2's additions).

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "$(cat <<'EOF'
Extend CI's exporter integration test to check the new globals fields

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review Notes

- **Spec coverage:** kills/losses (Task 1), turret ammo/power (Task 1), evolution factor/research/pollution folded into the globals command (Task 2), fluid throughput (Task 2), entity-build counts (Task 2), all dashboard panels including the pie charts and the red/green turret stat panels (Task 3), CI coverage of the new globals fields (Task 4) — every metric and panel in the design spec maps to a task. The spec's Non-goals (event-handler-based "under attack" detection, push notifications, per-turret Prometheus labels, "currently standing" entity counts) are correctly absent from every task.
- **Placeholder scan:** no TBD/TODO; every step has literal file content or an exact command with a stated expected result.
- **Type/name consistency:** `parse_kill_stats`, `parse_turret_status` (Task 1) and `parse_fluid_stats`, `parse_entity_build_stats`, the updated `parse_globals` (Task 2) are used identically in their own task's `poll_once` edit and their own test file additions. All eleven new metric names (`factorio_kills_total`, `factorio_losses_total`, `factorio_turrets_without_ammo`, `factorio_turrets_without_power`, `factorio_evolution_factor`, `factorio_research_progress`, `factorio_research_active`, `factorio_fluid_produced_total`, `factorio_fluid_consumed_total`, `factorio_entities_built_total`, `factorio_pollution`) are spelled identically between Tasks 1-2's Python code and Task 3's dashboard JSON PromQL expressions.
- **The `parse_globals` breaking change is called out explicitly** in Global Constraints and in Task 2's own Interfaces section, precisely because a reviewer or implementer skimming only Task 2 could otherwise mistake the changed return type for a regression rather than the intended, spec-mandated behavior.
- **Verified live, not guessed:** every Lua API this plan relies on (`get_kill_count_statistics`, `get_evolution_factor`, `get_fluid_production_statistics`, `get_entity_build_count_statistics`, `get_total_pollution`, the turret ammo/energy checks) was executed against the real running server during design, including two cases where the first-guessed name was wrong and had to be corrected against real error output.
