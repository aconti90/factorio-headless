import json
import unittest

from exporter import parse_globals, parse_item_stats, parse_kill_stats, parse_power_stats, parse_turret_status


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


if __name__ == "__main__":
    unittest.main()
