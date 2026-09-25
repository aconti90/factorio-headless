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
