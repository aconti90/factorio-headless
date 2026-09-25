# factorio-server-docker

Multi-arch Docker images for the **Factorio headless server**, built automatically
for every upstream release on both the stable and experimental channels.

[![CI](https://github.com/aconti90/factorio-headless/actions/workflows/ci.yml/badge.svg)](https://github.com/aconti90/factorio-headless/actions/workflows/ci.yml)
[![Release watch](https://github.com/aconti90/factorio-headless/actions/workflows/release-watch.yml/badge.svg)](https://github.com/aconti90/factorio-headless/actions/workflows/release-watch.yml)
[![Docker pulls](https://img.shields.io/docker/pulls/aconti90/factorio-headless)](https://hub.docker.com/r/aconti90/factorio-headless)
[![Image size](https://img.shields.io/docker/image-size/aconti90/factorio-headless/stable)](https://hub.docker.com/r/aconti90/factorio-headless)
[![License](https://img.shields.io/github/license/aconti90/factorio-headless)](LICENSE)

```
ghcr.io/aconti90/factorio-headless
docker.io/aconti90/factorio-headless *
```

\* Optional — see "Setting it up as your own" below.

| | |
|---|---|
| **Architectures** | `linux/amd64`, `linux/arm64` — native builds, no emulation at runtime |
| **Channels** | `stable` and `experimental`, tracked independently |
| **Updates** | Automatic, within hours of an upstream release |
| **Base** | `debian:trixie-slim`, runs as a non-root user |
| **Supply chain** | Checksum-verified downloads where upstream publishes sums, plus SBOM and signed build provenance |

---

## Setting it up as your own

```bash
git remote add origin git@github.com:you/factorio-server-docker.git
scripts/init.sh                 # rewrites the aconti90/factorio-headless placeholders
git add -A && git commit -m "Initial commit" && git push
```

Then, once on GitHub:

1. **Settings → Actions → General → Workflow permissions** → *Read and write
   permissions*, so the workflow can push to the registry.
2. **Actions → "Watch for Factorio releases" → Run workflow** to publish the
   first images. After that it runs on its own schedule.
3. Make the package public from the repo's **Packages** sidebar → package
   settings → *Change visibility*, if you want others to pull it. Public images
   on ghcr.io have no storage or bandwidth cost, and public repos get unlimited
   Actions minutes — the whole pipeline runs on the free tier.
4. *(Optional)* To also publish to Docker Hub, add a repository **variable**
   named `DOCKERHUB_USERNAME` (your Docker Hub username) and a repository
   **secret** named `DOCKERHUB_TOKEN` (an access token with Read, Write,
   Delete scope, from Docker Hub's Account Settings → Security → New Access
   Token) under **Settings → Secrets and variables → Actions**. Leave both
   unset to publish to GHCR only — nothing else changes. Setting the config
   only affects future publishes (see step 2 above to trigger one
   immediately) — it won't retroactively publish versions already on GHCR.

## Why another Factorio image?

In September 2026 Wube [shipped a native ARM64 Linux port](https://www.factorio.com/blog/post/fff-446)
of Factorio, headless server included — they used a Raspberry Pi 5 as the
dedicated test runner for it. Until then, running a Factorio server on ARM
hardware meant x86 emulation via box64 or QEMU, with the performance cost and
"expect crashes and lag" caveats that came with it.

The existing community images predate that release and still build around the
emulation path. This one ships **genuinely native binaries for both
architectures** in a single manifest, so `docker pull` gets the right one
automatically and a Pi runs Factorio at full speed.

## Quick start

```bash
docker run -d \
  --name factorio \
  -p 34197:34197/udp \
  -p 27015:27015/tcp \
  -v "$PWD/factorio-data:/factorio" \
  -e RCON_PASSWORD=change-me \
  --restart unless-stopped \
  --stop-timeout 120 \
  ghcr.io/aconti90/factorio-headless:stable
```

On first run the image lays out the data volume, renders a `server-settings.json`
from the environment, generates a fresh map, and starts serving. Connect from the
game via **Multiplayer → Connect to address** using `your-host:34197`.

With Compose, copy an example and edit it:

```bash
cp examples/docker-compose.yml docker-compose.yml
cp examples/.env.example .env      # set RCON_PASSWORD
docker compose up -d
```

## Tags

| Tag | Tracks |
|---|---|
| `latest` | newest **stable** release |
| `stable` | newest stable release |
| `experimental` | newest experimental release |
| `2`, `2.0` | newest stable release in that series |
| `2.0.77` | one exact release, never moves |

Pin an exact version for anything you care about. The floating `2` / `2.0` /
`latest` tags deliberately only ever follow the **stable** channel, so an
experimental build cannot silently land on a server that asked for `:2`.

> [!IMPORTANT]
> **ARM64 is currently published on the experimental channel only.** At the time
> of writing, `stable` (2.0.77) has no arm64 headless build upstream — the
> download 404s — while `experimental` (2.1.19) has one. This is not a choice
> this project makes; the build workflow probes what upstream actually publishes
> for each release and builds only those architectures. On a Pi today that means
> using `:experimental`. When arm64 reaches stable, `:stable` gains it with no
> change here.

## Configuration

Everything is environment variables. `server-settings.json` is re-rendered from
them on every start, so the environment is the single source of truth. Set
`UPDATE_CONFIG=false` if you would rather hand-edit the file on the volume and
have the image leave it alone.

### Server identity

| Variable | Default | Notes |
|---|---|---|
| `NAME` | `Factorio` | Shown in the server browser |
| `DESCRIPTION` | `A Factorio server running in Docker` | |
| `TAGS` | — | Comma-separated |
| `MAX_PLAYERS` | `0` | `0` = unlimited |

### Visibility and access

| Variable | Default | Notes |
|---|---|---|
| `VISIBILITY_PUBLIC` | `false` | Requires `FACTORIO_USERNAME` + `FACTORIO_TOKEN` |
| `VISIBILITY_LAN` | `true` | |
| `FACTORIO_USERNAME` | — | From your factorio.com profile |
| `FACTORIO_TOKEN` | — | From <https://factorio.com/profile> |
| `GAME_PASSWORD` | — | Password to join |
| `REQUIRE_USER_VERIFICATION` | `true` | Verify players against Factorio auth |
| `ADMINS` | — | Comma-separated usernames |
| `WHITELIST` | — | Comma-separated; enables whitelist mode when set |

### Gameplay

| Variable | Default | Notes |
|---|---|---|
| `AUTO_PAUSE` | `true` | **Set `false` to keep the factory running while nobody is connected** |
| `AUTO_PAUSE_WHEN_PLAYERS_CONNECT` | `false` | |
| `ONLY_ADMINS_CAN_PAUSE_THE_GAME` | `true` | |
| `AFK_AUTOKICK_INTERVAL` | `0` | Minutes; `0` disables |

### Saves

| Variable | Default | Notes |
|---|---|---|
| `SAVE_NAME` | `default` | Name used when generating the first map |
| `GENERATE_NEW_SAVE` | `true` | Create a map when the volume has none |
| `LOAD_LATEST_SAVE` | `true` | Load newest save rather than `SAVE_NAME` |
| `AUTOSAVE_INTERVAL` | `10` | Minutes |
| `AUTOSAVE_SLOTS` | `5` | |
| `NON_BLOCKING_SAVING` | `false` | Avoids a stutter on save; uses more RAM |

### Mods

Drop mod zips into the `mods/` directory on the volume and restart the
container — same as a normal Factorio install.

To keep mods already there up to date automatically, set `UPDATE_MODS=true`.
On every boot the image checks each mod against the Factorio mod portal and
replaces it if a newer version compatible with the running server exists.
This only updates mods that are already present; it does not install new
ones or resolve dependencies.

| Variable | Default | Notes |
|---|---|---|
| `UPDATE_MODS` | `false` | Check mods against the portal and update them on boot. Requires `FACTORIO_USERNAME`/`FACTORIO_TOKEN`. |
| `MODS_IGNORE` | — | Comma-separated mod names to exclude from updates |

The update check runs before the server starts, so it delays startup and needs
outbound HTTPS access to `mods.factorio.com`. If `UPDATE_MODS=true` and
`FACTORIO_USERNAME`/`FACTORIO_TOKEN` aren't set, the container refuses to
start. A mod the portal doesn't recognize (e.g. a private/local mod) is left
untouched with a logged warning, not treated as an error.

### Container

| Variable | Default | Notes |
|---|---|---|
| `PUID` / `PGID` | `845` | Set to your host user so saves stay editable |
| `PORT` | `34197` | Game port (UDP) |
| `RCON_PORT` | `27015` | |
| `RCON_PASSWORD` | *generated* | A random one is generated and logged if unset |
| `BIND` | — | Bind to a specific interface |
| `EXTRA_ARGS` | — | Passed straight to the server binary |

## Running it on a Raspberry Pi 5

`examples/docker-compose.pi.yml` is a working starting point. The things that
actually matter:

- **Use `:experimental`** for now — see the note above on arm64 availability.
- **Put the data volume on something that isn't an SD card** if you can. Autosaves
  are the dominant write load, and SD cards wear out under it. An NVMe HAT or a
  USB SSD is a meaningful reliability upgrade; if you're stuck on SD, raise
  `AUTOSAVE_INTERVAL` and lower `AUTOSAVE_SLOTS`.
- **RAM is not the constraint.** A headless server is comfortable in well under
  2 GB for a normal base. The Pi's single-core speed is what eventually caps how
  large a factory you can run before UPS drops below 60.
- **Factorio is UDP.** An HTTP-oriented tunnel (Cloudflare Tunnel and friends)
  will not carry it. Either forward UDP 34197 on your router, or put the server
  and your clients on a WireGuard/Tailscale network and connect over that — which
  also avoids exposing the port publicly at all.

## Observability: stats and logs dashboards

`examples/docker-compose.observability.yml` runs Factorio alongside a full
Grafana stack — Prometheus for factory/server stats (item production rates,
UPS, player count, power), Loki for readable server logs — with both
dashboards already provisioned:

```bash
cp examples/docker-compose.observability.yml docker-compose.yml
cp examples/.env.observability.example .env      # set RCON_PASSWORD and GRAFANA_ADMIN_PASSWORD
docker compose up -d
```

Open Grafana at `http://localhost:3000` (login with the admin password you
set) and both the **Factorio Stats** and **Factorio Logs** dashboards are
already there, under the "Factorio" folder — no manual datasource or
dashboard setup.

To share just the stats dashboard (e.g. on a public status page) without
exposing the logs dashboard or Grafana login access, use Grafana's built-in
public-dashboard feature: open the Stats dashboard, use the share menu's
"Public dashboard" option, and enable it. The Logs dashboard stays behind
normal Grafana authentication.

The exporter polls Factorio over RCON, so it needs the same `RCON_PASSWORD`
the `factorio` service uses — no separate credential.

## Keeping a world running while you work

Factorio has no failure state you can wander into: with `AUTO_PAUSE=false` the
server simulates continuously, and a base left alone for two hours is simply a
base that produced more. The only thing that can spoil it is biters, and that is
a world-generation setting rather than something the server can change later:

```bash
# Before first start — edit the map-gen settings on the volume, then let the
# image generate the map from them.
docker run --rm -v "$PWD/factorio-data:/factorio" ghcr.io/aconti90/factorio-headless:stable \
  sh -c 'cat /factorio/config/map-gen-settings.json'
```

Set `autoplace_controls.enemy-base.size` to `"none"` for a world with no biters
at all, or leave them in and set `peaceful_mode: true` in
`config/map-settings.json` so they never initiate attacks. Both must be decided
**before** the map is generated; changing them afterwards needs console commands
that disable achievements.

## Updating

The image does not self-update — that would mean a server restarting itself
without warning. Pull and recreate when you want to:

```bash
docker compose pull && docker compose up -d
```

Saves are forward-compatible, so a newer server loads an older save fine. Going
*backwards* is not supported by Factorio; keep an autosave from before an upgrade
if you plan to roll back.

Clients must match the server version exactly, so if you track `:experimental`,
your players need the experimental branch on Steam too.

## How the automation works

```
  schedule (every 6h)
        │
        ▼
  release-watch.yml ──► scripts/resolve-release.sh
        │                  ├─ GET /api/latest-releases      (version per channel)
        │                  ├─ range-probe each download URL (which arches exist)
        │                  └─ look up published sha256 sums
        │
        ├─ group channels by version, skip anything already in the registry
        ▼
  build.yml ──► buildx ──► ghcr.io + Docker Hub*  (+ SBOM; provenance attestation on ghcr.io only)
```

\* Docker Hub publishing is optional — set via the `DOCKERHUB_USERNAME` repo
variable and `DOCKERHUB_TOKEN` repo secret. Unset, the pipeline publishes to
ghcr.io only.

Three design decisions worth knowing about, since they're the ones that make it
correct rather than merely working:

**Architecture availability is discovered, not assumed.** Upstream does not ship
every architecture for every release. The workflow range-probes each download URL
(a one-byte request, not a 400 MB one) and builds the manifest from what actually
exists, so a missing arm64 build is a smaller manifest rather than a red run.

**The registry is the state.** Nothing is committed back to the repo to remember
what has been built; the workflow asks ghcr.io directly via `docker manifest
inspect`. There is no file to drift out of sync with reality.

**Downloads run on the build host, not under emulation.** The `downloader` stage
is pinned to `$BUILDPLATFORM`, so fetching and unpacking a ~400 MB tarball always
happens natively; only the final image layer is target-arch. Cross-building arm64
on free x86 runners costs essentially nothing, which is what keeps this workable
on GitHub's free tier — public repos get unlimited Actions minutes and ghcr.io
storage for public images.

Wube [asks integrators](https://forums.factorio.com/viewtopic.php?t=120853) to
poll `api/latest-releases` rather than the download endpoint, which is
rate-limited. This does that, four times a day.

## Building locally

```bash
# Current stable, your native architecture
docker build ./docker \
  --build-arg FACTORIO_VERSION="$(./scripts/resolve-release.sh stable | jq -r .version)" \
  -t factorio-server:local

# Cross-build both architectures (requires binfmt/QEMU registered)
docker buildx build ./docker \
  --platform linux/amd64,linux/arm64 \
  --build-arg FACTORIO_VERSION=2.1.19 \
  -t factorio-server:local
```

`scripts/resolve-release.sh [stable|experimental]` is the same script CI uses and
is useful on its own — it prints the current version, which architectures exist
for it, and any published checksums.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT — see [LICENSE](LICENSE). Factorio is the property of Wube Software; this
project packages the freely redistributable headless server and is not
affiliated with or endorsed by Wube.
