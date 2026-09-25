# Mod auto-update

## Problem

The image has no way to keep mods up to date. Operators drop mod zips into
the `mods/` volume directory manually today, which works, but a mod that
gets a compatibility update upstream just sits stale until someone notices
and manually re-downloads it. The most established competing image
(`factoriotools/factorio-docker`, 1.4k stars) solves this with an
`UPDATE_MODS_ON_START` env var that updates already-installed mods from the
Factorio mod portal on boot — a real feature gap, and the first thing asked
about this project's mod story when it was posted publicly.

## Goal

An opt-in env var that, on boot, checks every mod already present in the
`mods/` volume directory against the Factorio mod portal and replaces any
with a newer version compatible with the running server's Factorio version.

## Non-goals

- **Installing new mods from a declarative list.** This only updates mods
  that are already present as zips in the volume — matching how the
  existing manual drop-in workflow already works. A `MODS=name1,name2`
  style installer is a bigger feature (first-install + dependency
  resolution) and can be a separate future spec if it turns out to be
  wanted.
- **Mod dependency resolution.** Updating a mod that's already installed
  doesn't require pulling in mods it depends on — the operator installed
  the working set themselves; this just keeps each of those zips current.
- **Space Age DLC mod handling** (`elevated-rails`/`quality`/`space-age`).
  A related but separate concern — those are bundled with the game binary,
  not portal-downloaded zips, and are being scoped as their own follow-up.
- **`mod-list.json` enable/disable management.** Unrelated to versioning;
  the operator or the game itself already owns that file.
- **CI coverage of the live update path.** See Testing below.

## Environment variables

| Variable | Default | Notes |
|---|---|---|
| `UPDATE_MODS` | `false` | Opt-in, matching the existing `UPDATE_CONFIG` naming convention. When `true`, mods in the volume are checked/updated on every boot. |
| `MODS_IGNORE` | — | Comma-separated mod names to exclude from updates, parsed with the same `jqlist` helper already used for `ADMINS`/`WHITELIST`/`TAGS`. |

No new credential variables — mod-portal auth reuses the existing
`FACTORIO_USERNAME`/`FACTORIO_TOKEN` (with their existing `USERNAME`/`TOKEN`
fallback aliases), since it's the same factorio.com account either way.

## Update algorithm

A new script, `docker/update-mods.sh`, called from `entrypoint.sh` after
`server-settings.json` is rendered and before the save-file step — mods
must be correct before the server binary ever launches, including for a
fresh map generation.

1. If `UPDATE_MODS` isn't `true`, the script isn't invoked at all — zero
   behavior change from today.
2. If `UPDATE_MODS=true` and both `FACTORIO_USERNAME`/`FACTORIO_TOKEN`
   resolve empty, fail fast (`die()`, matching the entrypoint's existing
   error-handling style) rather than silently booting with stale mods.
3. Determine the running server's major.minor version via
   `"${BIN}" --version` — mod portal releases target a version line like
   `2.0`, not an exact patch release.
4. For each `<name>_<version>.zip` under `${FACTORIO_DIR}/mods`:
   - Skip if `<name>` is in `MODS_IGNORE`.
   - Query the public, unauthenticated `https://mods.factorio.com/api/mods/<name>`
     endpoint for its release list.
   - Pick the newest release whose `info_json.factorio_version` matches the
     running major.minor, and compare its version to the installed one.
   - If newer: download via that release's `download_url` with `username`
     and `token` appended as query params, verify the portal-supplied
     `sha1`, and atomically replace the old zip with the new one.
5. Every check/update/skip is logged the same way the rest of the
   entrypoint logs (`log "mod-name: 1.2.3 -> 1.3.0"`), and the token is
   masked in any logged URL — the same care already taken with
   `RCON_PASSWORD`.
6. A failure on one mod (network error, portal 404, checksum mismatch)
   logs a warning and leaves that mod untouched rather than aborting the
   whole boot. One broken or renamed mod shouldn't take the server down
   when the rest update fine — this is different from the missing-
   credentials case, which is a configuration error the operator can fix
   before ever starting the container, not a transient per-mod failure.

## Dockerfile change

Add `curl` to the runtime stage's package list (`docker/Dockerfile`,
alongside `ca-certificates gosu jq procps tini`) — the only new runtime
dependency this feature needs. `jq`, used for parsing the mod portal's
JSON responses, is already installed.

## Documentation

Add a `## Mods` section to `README.md` (there isn't one today): the
existing manual drop-in workflow, plus `UPDATE_MODS`/`MODS_IGNORE` added to
the environment variable reference tables.

## Testing

CI's existing smoke test (boot, wait for healthcheck, verify clean SIGTERM
shutdown) continues to run with `UPDATE_MODS` unset, which is the main
regression guard — proving the default path is untouched by this change.
Hitting the real mod portal from CI would be flaky and network-dependent,
so the live update path itself isn't covered by an automated CI test;
`scripts/lint.sh` (shellcheck) catches syntax/style issues in the new
script, and manually verifying an actual update against a real mod is
documented as part of the implementation plan's verification steps rather
than asserted in CI.
