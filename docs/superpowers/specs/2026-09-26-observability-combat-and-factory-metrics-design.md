# Observability stack: combat, turret health, and factory-wide metrics

## Problem

The observability stack (shipped, live on a real Raspberry Pi 5) currently
covers only items, power, UPS, and player count. After using it, the
maintainer asked for combat visibility (biter
kills, buildings lost to attacks, turret health) and broader factory
metrics (pollution, evolution, research, fluids, entity counts) that came
up during the original feature's own brainstorming but were deferred.

Every new API this spec relies on was executed live against the real
running server during design, the same discipline used throughout this
project — including two cases where the first-guessed API name was wrong
and had to be corrected against real error output (`LuaForce.kills` and
`LuaForce.evolution_factor` both don't exist; the real methods are
`get_kill_count_statistics(surface)` and `get_evolution_factor(surface)`).

## Goal

Extend the existing exporter and dashboard — no new components, no new
architecture — with: kills/losses (with a pie-chart breakdown), turret
ammo/power health, evolution factor, research progress, pollution, and
fluid production/consumption and entity-build counts.

## Non-goals

- **A true "under attack" early-warning signal.** The only combat data
  exposed by the game's stat APIs is *completed kills* — there is no
  simple polled signal for "damage is happening right now but nothing has
  died yet." That would require registering a persistent `on_entity_damaged`
  event handler via RCON (verified live that Factorio's own wiki/forums
  don't document this as unsupported, but it's a genuinely different
  mechanism — an event handler that persists across polls, rather than a
  one-shot read — and hasn't been verified working end-to-end). Deferred
  to a future spec if wanted; `factorio_losses_total` increasing is the
  closest proxy this spec provides.
- **Push notifications** (email, Slack, etc.) for the turret-health or
  losses signals. This spec only adds visual (red/green) Grafana panels.
  Actual alerting would need Grafana's contact-points/notification-policy
  setup, which is a separate piece of configuration, not bundled here.
- **Per-turret detail in Prometheus.** Turret ammo/power status is exposed
  as an aggregate count (`factorio_turrets_without_ammo`,
  `factorio_turrets_without_power`), not one labeled series per turret —
  a base can have hundreds of turrets, and per-turret labels would let
  cardinality grow unbounded. When either count is nonzero, the exporter
  logs which specific turret (position), visible in the Logs dashboard.
- **"Currently standing" entity counts.** `factorio_entities_built_total`
  is a cumulative *ever-built* counter (from
  `get_entity_build_count_statistics`), not a live count of what's still
  standing — entities that were later removed or replaced are still
  counted. This is what the underlying API actually tracks; a true
  "currently standing" count would need a live entity scan, which isn't in
  scope here.

## Verified technical foundation

All executed live against the real server during design:

- `LuaForce.get_kill_count_statistics(surface)` returns a
  `LuaFlowStatistics`-shaped object: `.input_counts` = entities this force
  killed (confirmed by spawning a biter and killing it "by" the player
  force — `small-biter: 1` appeared in `input_counts`), `.output_counts` =
  this force's own entities that were killed (confirmed by spawning a
  player-owned wall and killing it "by" the enemy force —
  `stone-wall: 1` appeared in `output_counts`). Same input=ours/output=lost
  convention as every other flow-statistics API already in use.
- Ammo-turret health: `entity.get_inventory(defines.inventory.turret_ammo).is_empty()`
  correctly reports `true` for a freshly-placed, unloaded gun turret
  (confirmed) — the earlier same-named-entity test that returned `false`
  was querying an unrelated already-loaded turret already on the map, not
  a real API discrepancy.
- Electric-turret health: `entity.energy` reads `0` for a freshly-placed,
  unpowered laser turret (confirmed) — `.electric_buffer_size` gives the
  max for context but isn't needed for the simple "has zero energy" check
  this spec uses.
- `find_entities_filtered{type='ammo-turret'}` and
  `type='electric-turret'}` both return real, correct counts against a
  live base with existing turrets (8 and 1 respectively at the time of
  testing) — confirmed these are the right type strings before relying on
  them for the aggregate scan.
- `LuaForce.get_evolution_factor(surface)` (not the plain `.evolution_factor`
  attribute, which errors with "doesn't contain key" — this attribute was
  replaced by a per-surface method in 2.0, matching every other stat this
  project already reads) returns a real float against the live server
  (`0.1565...`).
- `LuaForce.current_research` (nil-able) and `.research_progress` (plain
  float, `0` when nothing queued) both read cleanly.
- `LuaForce.get_fluid_production_statistics(surface)` returns the exact
  same `LuaFlowStatistics` shape as item stats — confirmed with real water
  and steam throughput numbers from the live base.
- `LuaForce.get_entity_build_count_statistics(surface).input_counts`
  returns a real, rich per-entity-type breakdown of the live base
  (confirmed: `transport-belt: 530`, `stone-wall: 134`, `gun-turret: 6`,
  eighteen other entity types).
- `LuaSurface.get_total_pollution()` — a dedicated method added
  specifically to avoid the historically slow naive chunk-iteration
  approach — returns a real float (`802.78...`) cheaply.

## Metrics

All new metrics follow the same conventions already established: Counters
for cumulative game-tracked totals (updated via `.labels(...)._value.set()`,
never `.inc()`), Gauges for instantaneous values, `helpers.table_to_json`
in every Lua command string.

| Metric | Type | Labels | Source |
|---|---|---|---|
| `factorio_kills_total` | Counter | `entity` | `get_kill_count_statistics(surface).input_counts` |
| `factorio_losses_total` | Counter | `entity` | same object's `.output_counts` |
| `factorio_turrets_without_ammo` | Gauge | — | count of `type='ammo-turret'` entities with an empty `turret_ammo` inventory |
| `factorio_turrets_without_power` | Gauge | — | count of `type='electric-turret'` entities with `.energy == 0` |
| `factorio_evolution_factor` | Gauge | — | `game.forces.enemy.get_evolution_factor(surface)` |
| `factorio_research_progress` | Gauge | — | `force.research_progress` |
| `factorio_research_active` | Gauge | `technology` | presence-flag pattern: `1` while `current_research` matches that label, the metric is otherwise not set for other technologies this poll |
| `factorio_fluid_produced_total` | Counter | `fluid` | `get_fluid_production_statistics(surface).input_counts` |
| `factorio_fluid_consumed_total` | Counter | `fluid` | same object's `.output_counts` |
| `factorio_entities_built_total` | Counter | `entity` | `get_entity_build_count_statistics(surface).input_counts` |
| `factorio_pollution` | Gauge | — | `surface.get_total_pollution()` |

Implementation note on `factorio_research_active`: since a Gauge with a
label only reports the labels that have actually been `.set()` at least
once, and only one technology is ever active at a time, the poll loop must
avoid leaving a *previous* technology's label stuck at `1` after research
moves on. The implementation sets the current technology's label to `1`
and the previously-active one (if different) to `0` in the same poll,
rather than only ever setting the new one.

`factorio_evolution_factor`, `factorio_research_progress`,
`factorio_research_active`, and `factorio_pollution` are all cheap
single-value reads and get folded into the existing `_GLOBALS_COMMAND`
(which already reads tick and player count) rather than becoming separate
RCON round-trips.

## Dashboard changes

New panels on the existing **Factorio Stats** dashboard:

- **Kills** — pie chart, `factorio_kills_total` by `entity`.
- **Losses** — pie chart, `factorio_losses_total` by `entity`.
- **Turret status** — two stat panels (`factorio_turrets_without_ammo`,
  `factorio_turrets_without_power`), red when nonzero, green at zero.
- **Evolution factor** — gauge panel, 0–100%.
- **Research** — a stat panel combining the `technology` label from
  `factorio_research_active` as text with `factorio_research_progress` as
  the percentage value.
- **Fluid production** / **Fluid consumption** — two timeseries panels
  (`rate(...)`), matching the existing item-production panel style.
- **Entities built** — a table panel ranked by count, not a graph — with
  ~20+ distinct entity types in a real base, a table is more useful than a
  line chart for "what does my factory consist of."
- **Pollution** — timeseries showing the trend over time (rising vs.
  falling matters more than the instant value).

## Testing

Same approach as the original exporter: unit tests (Python stdlib
`unittest`) for the new pure-parsing functions
(`parse_kill_stats`/`parse_fluid_stats`/`parse_entity_build_stats`/the
extended `parse_globals`), using response shapes matching what was
actually observed live during design (not synthetic guesses). The CI
integration test (which already boots a real server and confirms
`factorio_tick_total` increases across polls) is extended to also assert
`factorio_evolution_factor` and `factorio_pollution` are present and
numeric in the scraped output, giving the new globals-command fields the
same "does this actually flow end-to-end in CI" coverage the existing
metrics already have.
