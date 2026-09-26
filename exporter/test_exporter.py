import json
import time
import unittest

import exporter
from exporter import (
    LAST_POLL_SUCCESS_TIMESTAMP,
    RESEARCH_ACTIVE,
    parse_entity_build_stats,
    parse_fluid_stats,
    parse_globals,
    parse_item_stats,
    parse_kill_stats,
    parse_power_stats,
    parse_turret_status,
    poll_once,
)


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

    def test_parse_power_stats_dedupes_by_network(self):
        # Matches the real shape returned by the power-stats Lua command: one
        # entry per distinct electric_network_id, keyed as a JSON string.
        response = json.dumps({"3": {"input": {"solar-panel": 500}, "output": {"electric-mining-drill": 200}}})
        result = parse_power_stats(response)
        self.assertEqual(result, {"3": ({"solar-panel": 500}, {"electric-mining-drill": 200})})

    def test_parse_power_stats_empty(self):
        self.assertEqual(parse_power_stats("{}"), {})


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


class FakeRconClient:
    """Stands in for RconClient in poll_once() tests: returns a canned JSON
    response per command, keyed by exact command text so a poll_once change
    that adds/reorders RCON calls fails loudly instead of silently."""

    def __init__(self, research="", research_progress=0.0):
        self._responses = {
            exporter._ITEM_STATS_COMMAND: json.dumps({"input": {}, "output": {}}),
            exporter._GLOBALS_COMMAND: json.dumps({
                "tick": 1,
                "players": 0,
                "evolution": 0.0,
                "research": research,
                "research_progress": research_progress,
                "pollution": 0.0,
            }),
            exporter._POWER_COMMAND: json.dumps({}),
            exporter._KILL_STATS_COMMAND: json.dumps({"input": {}, "output": {}}),
            exporter._TURRET_STATUS_COMMAND: json.dumps({"no_ammo": [], "no_power": []}),
            exporter._FLUID_STATS_COMMAND: json.dumps({"input": {}, "output": {}}),
            exporter._ENTITY_BUILD_COMMAND: json.dumps({}),
        }

    def command(self, command):
        if command not in self._responses:
            raise AssertionError(f"FakeRconClient received an unexpected command: {command}")
        return self._responses[command]


class TestPollOnceResearchActiveReset(unittest.TestCase):
    """Regression coverage for the _last_active_research reset logic in
    poll_once(). A Gauge only reports labels it has explicitly .set(); without
    resetting the previous technology's label to 0 when research moves on,
    that label stays stuck at 1 forever. See exporter.py's module-level
    comment above _last_active_research."""

    def setUp(self):
        # _last_active_research is the one piece of cross-poll state in the
        # exporter; reset it so this test doesn't depend on run order.
        exporter._last_active_research = None

    def tearDown(self):
        exporter._last_active_research = None

    def test_switching_active_research_resets_previous_label_to_zero(self):
        poll_once(FakeRconClient(research="automation-2", research_progress=0.5))
        self.assertEqual(RESEARCH_ACTIVE.labels(technology="automation-2")._value.get(), 1)

        poll_once(FakeRconClient(research="automation-3", research_progress=0.0))
        self.assertEqual(
            RESEARCH_ACTIVE.labels(technology="automation-2")._value.get(), 0,
            "previous technology's label must be reset to 0, or it stays stuck at 1 forever",
        )
        self.assertEqual(RESEARCH_ACTIVE.labels(technology="automation-3")._value.get(), 1)

    def test_research_finishing_with_nothing_queued_resets_label(self):
        poll_once(FakeRconClient(research="automation-2", research_progress=0.9))
        self.assertEqual(RESEARCH_ACTIVE.labels(technology="automation-2")._value.get(), 1)

        # Nothing queued next: current_research comes back as '' (no active tech).
        poll_once(FakeRconClient(research="", research_progress=0.0))
        self.assertEqual(
            RESEARCH_ACTIVE.labels(technology="automation-2")._value.get(), 0,
            "label must be reset to 0 when research stops rather than switches",
        )


class TestPollOnceLastSuccessTimestamp(unittest.TestCase):
    """LAST_POLL_SUCCESS_TIMESTAMP must only advance once every RCON call in
    poll_once() (item stats, globals, power, kills, turrets, fluids,
    entity-builds) has succeeded — it's the CI signal that a full poll cycle
    actually completed, not just that the metric was registered on import."""

    def test_set_after_full_successful_poll(self):
        before = time.time()
        poll_once(FakeRconClient())
        after = time.time()
        self.assertGreaterEqual(LAST_POLL_SUCCESS_TIMESTAMP._value.get(), before)
        self.assertLessEqual(LAST_POLL_SUCCESS_TIMESTAMP._value.get(), after)


if __name__ == "__main__":
    unittest.main()
