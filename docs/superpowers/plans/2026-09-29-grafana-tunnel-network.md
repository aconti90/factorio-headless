# Grafana Tunnel Network Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Attach Grafana to a second, named Docker network (`factorio-tunnel`) that a separate Cloudflare-tunnel compose stack can join as `external: true`, so the tunnel can reach Grafana by container name with no new host port.

**Architecture:** Add a top-level `networks:` block to `examples/docker-compose.observability.yml` defining `factorio-tunnel` (owned/created here, non-external). Give the `grafana` service an explicit `networks:` list containing both `default` (so it keeps reaching Prometheus/Loki exactly as before) and `factorio-tunnel`. No other service changes.

**Tech Stack:** Docker Compose (YAML only — no application code changes).

## Global Constraints

- Network name is exactly `factorio-tunnel` (must match what the separate, out-of-repo Cloudflare-tunnel compose file references as `external: true`).
- The existing Grafana host port publish (`${GRAFANA_PORT:-3000}:3000`) is untouched — this change is additive only, direct LAN access keeps working.
- No other service (`factorio`, `exporter`, `prometheus`, `loki`, `promtail`) changes — they all stay on `default` only, since nothing external needs to reach them.

---

### Task 1: Add the shared network and attach Grafana

**Files:**
- Modify: `examples/docker-compose.observability.yml`

**Interfaces:**
- Consumes: nothing (no earlier tasks — this is the only task in the plan)
- Produces: a Docker network named `factorio-tunnel`, created when this compose file's stack starts, that any other compose stack on the same host can join via `external: true` and reach the `factorio-grafana` container by that name over.

- [ ] **Step 1: Add the top-level `networks:` block**

At the end of the file, after the existing `volumes:` block (currently the last section, ending at `promtail-positions:`), add:

```yaml
# `factorio-tunnel` lets a separate docker-compose stack (e.g. one running
# a Cloudflare Tunnel container) join this network as `external: true` and
# reach Grafana directly by container name (http://factorio-grafana:3000),
# without publishing a new host port. Only Grafana is on it — Prometheus,
# Loki, and Promtail stay on the default network since nothing external
# needs to reach them.
networks:
  factorio-tunnel:
```

**Step 1 verify:** `git diff examples/docker-compose.observability.yml` shows the new block appended after `promtail-positions:` with correct YAML indentation (top-level `networks:` key, `factorio-tunnel:` indented two spaces under it, no value — an empty mapping is valid Compose syntax for "create this network with defaults").

- [ ] **Step 2: Attach the `grafana` service to both networks**

In the `grafana` service block (currently lines 94-109), add a `networks:` key. Insert it right after the `volumes:` block within that service (i.e., as the new last key of the `grafana` service):

```yaml
    volumes:
      - ../observability/grafana/provisioning:/etc/grafana/provisioning:ro
      - ../observability/grafana/dashboards:/var/lib/grafana/dashboards:ro
      - grafana-data:/var/lib/grafana
    networks:
      - default
      - factorio-tunnel
```

This replaces the current end of the `grafana` service (which currently ends at `- grafana-data:/var/lib/grafana` with no `networks:` key).

**Step 2 verify:** `git diff examples/docker-compose.observability.yml` shows the `networks:` key added under `grafana`, listing both `default` and `factorio-tunnel`, at the same indentation level as `volumes:`/`environment:`/`depends_on:` within that service (4 spaces).

- [ ] **Step 3: Validate the compose file parses correctly**

Run: `cd examples && docker compose -f docker-compose.observability.yml config`

Expected: valid YAML output (no parse errors), and the rendered config's `services.grafana.networks` shows both `default` and `factorio-tunnel`, and the top-level `networks` section lists `factorio-tunnel` (with no `external: true` — this compose file owns/creates it) alongside Compose's own implicit `default` entry.

If `docker compose` isn't available in this environment, at minimum validate the YAML is well-formed: `python3 -c "import yaml; yaml.safe_load(open('docker-compose.observability.yml'))"` from the `examples/` directory — this won't catch Compose-specific semantic errors (e.g. a malformed network reference) but does catch YAML syntax errors.

- [ ] **Step 4: Live smoke test (if a Docker host is available)**

From the `examples/` directory, with a valid `.env` (or the minimum required vars: `RCON_PASSWORD`, `GRAFANA_ADMIN_PASSWORD`):

```bash
docker compose -f docker-compose.observability.yml up -d
docker network inspect factorio-tunnel
docker compose -f docker-compose.observability.yml logs grafana | tail -20
```

Expected: `docker network inspect factorio-tunnel` succeeds and lists `factorio-grafana` as a connected container. Grafana's logs show it starting normally (no new errors compared to before this change) — confirm it's still reachable at `http://localhost:${GRAFANA_PORT:-3000}` and its dashboards still load data from Prometheus/Loki (proving the `default` network side of the dual-network attachment still works).

Clean up afterward: `docker compose -f docker-compose.observability.yml down`.

If no Docker host is available in this environment, note that in the task report and rely on Step 3's static validation — this is a low-risk, additive-only YAML change (an extra network attachment on one already-working service), consistent with the spec's Non-goals.

- [ ] **Step 5: Commit**

```bash
git add examples/docker-compose.observability.yml
git commit -m "$(cat <<'EOF'
Attach Grafana to a shared network for an external Cloudflare Tunnel

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```
