# Shared Docker network for Grafana + Cloudflare Tunnel

## Problem

The observability stack's `docker-compose.observability.yml` currently has no
explicit network — Grafana and the rest of the stack all join Compose's
implicit, auto-created `default` network. The maintainer runs a separate
`docker-compose` stack elsewhere on the same host for a Cloudflare Tunnel,
and wants that tunnel container to reach Grafana directly by container name,
without publishing a new host port for it.

## Goal

Grafana joins a second, named Docker network that the Cloudflare-tunnel
compose stack can attach to as well, so the tunnel container can reach
Grafana at `http://factorio-grafana:3000` over that shared network.

## Design

Add a top-level `networks:` entry to `docker-compose.observability.yml`
defining `factorio-tunnel` as a regular (non-external) bridge network — this
compose file owns and creates it. The `grafana` service joins two networks:
the implicit `default` (unchanged — this is how it already talks to
Prometheus and Loki, which stay on `default` only) and the new
`factorio-tunnel`.

The existing host port publish (`${GRAFANA_PORT:-3000}:3000`) stays as-is,
so direct LAN access keeps working exactly as before — this change is
additive only.

The separate Cloudflare-tunnel compose stack (not part of this repo)
references the same network name with `external: true` to join it:

```yaml
networks:
  factorio-tunnel:
    external: true
```

## Non-goals

- The Cloudflare-tunnel compose file itself is not part of this repo and is
  not touched by this change — only the `factorio-tunnel` external-network
  reference needed on that side is documented (in this spec and a comment
  in the compose file), not implemented here.
- No change to Prometheus, Loki, or Promtail — they stay on `default` only,
  since nothing external needs to reach them directly.
- No change to what's exposed to the LAN — the existing host port publish
  is untouched.

## Testing

`docker compose -f examples/docker-compose.observability.yml config` to
confirm the network and service definitions parse correctly, and
`docker compose -f examples/docker-compose.observability.yml up -d` on a
real host (or the CI-equivalent smoke check already covering this file) to
confirm the stack still starts cleanly with Grafana reaching Prometheus/Loki
as before, and now also visible on the new network via
`docker network inspect factorio-tunnel`.
