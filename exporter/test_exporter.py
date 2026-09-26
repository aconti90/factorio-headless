import json
import unittest

from exporter import (
    parse_entity_build_stats,
    parse_fluid_stats,
    parse_globals,
    parse_item_stats,
    parse_kill_stats,
    parse_power_stats,
    parse_turret_status,
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


if __name__ == "__main__":
    unittest.main()
