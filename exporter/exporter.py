"""Factorio RCON -> Prometheus metrics exporter."""
import json
import os
import struct
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

    # input=produced, output=consumed — same convention as item stats above; consistent
    # with Factorio's documented LuaFlowStatistics semantics across item/fluid/electric
    # flows, though not independently live-tested with real power generation for this
    # specific case.
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
        except (RconError, ConnectionError, OSError, ValueError, KeyError, TypeError, AttributeError, struct.error) as exc:
            print(f"[exporter] WARNING: poll failed ({exc}), will reconnect next cycle")
            if client is not None:
                client.close()
            client = None
        time.sleep(poll_interval)


if __name__ == "__main__":
    main()
