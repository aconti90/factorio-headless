# Mod Auto-Update Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An opt-in `UPDATE_MODS` env var that checks every mod already present in the `mods/` volume directory against the Factorio mod portal on boot, and replaces any with a newer version compatible with the running server's Factorio version.

**Architecture:** A new standalone script, `docker/update-mods.sh`, holds all the update logic (version comparison, filename parsing, ignore-list matching, the portal API calls) as small testable bash functions plus a `main()` that ties them together. `docker/entrypoint.sh` gains one new conditional block that calls this script when `UPDATE_MODS=true`, between rendering `server-settings.json` and the save-file step. The Dockerfile gains `curl` (the only new runtime dependency) and packages the new script the same way `entrypoint.sh`/`healthcheck.sh` already are.

**Tech Stack:** Bash, `curl`, `jq` (already in the image), `sort -V` for numeric version comparison (confirmed available both in the Debian runtime image and in the local dev/test environment — GNU coreutils and modern BSD/macOS `sort` both support `-V`).

## Global Constraints

- `UPDATE_MODS` defaults to `false` — zero behavior change when unset, matching the existing `UPDATE_CONFIG` naming convention.
- `MODS_IGNORE` is a comma-separated list, parsed the same way `ADMINS`/`WHITELIST`/`TAGS` already are (trim whitespace, drop empties).
- No new credential env vars — mod-portal auth reuses `FACTORIO_USERNAME`/`FACTORIO_TOKEN` (with their existing `USERNAME`/`TOKEN` fallback aliases).
- If `UPDATE_MODS=true` and both credential vars resolve empty, fail fast (`die()`) — don't silently boot with stale mods.
- A single mod's update failing (network error, portal 404, checksum mismatch) must not abort the boot — log a warning and leave that mod as-is, then continue to the next mod.
- No new mod installation, no dependency resolution, no Space Age DLC handling, no `mod-list.json` management — only version-updates for zips already present in the volume.
- No CI coverage of the live mod-portal-update path (network-dependent, would be flaky) — only the pure-logic helper functions get automated tests; the live path is verified manually.
- Token must never appear unmasked in logs, matching the existing care taken with `RCON_PASSWORD` in `docker/entrypoint.sh`.

---

### Task 1: `docker/update-mods.sh` core logic + unit tests for the pure-logic helpers

**Files:**
- Create: `docker/update-mods.sh`
- Create: `scripts/test-update-mods.sh`

**Interfaces:**
- Consumes: env vars `FACTORIO_DIR` (already set by the Dockerfile's `ENV`), `FACTORIO_HOME` (already set by the Dockerfile's `ENV`), `MODS_IGNORE` (new, optional), `FACTORIO_USERNAME`/`USERNAME`, `FACTORIO_TOKEN`/`TOKEN` (existing).
- Produces: an executable script at `docker/update-mods.sh` with `main()` as its entry point (invoked with no arguments), and these functions other tasks/tests rely on by exact name: `mod_version_newer(current, candidate)` (return code 0/1), `parse_mod_filename(basename)` (echoes `"name version"` or nothing), `is_ignored(name, comma_list)` (return code 0/1), `update_one_mod(zip_path, name, current_version, factorio_line, username, token)`.

- [ ] **Step 1: Write the failing unit test script**

Create `scripts/test-update-mods.sh`:

```bash
#!/usr/bin/env bash
# Unit tests for the pure-logic helpers in docker/update-mods.sh — the
# functions that don't need network access. Run manually or via lint.sh;
# no CI wiring for these, matching this repo's existing bash-only test
# conventions (the live mod-portal-update path is verified manually, not
# by an automated test — see docs/superpowers/specs/2026-09-25-mod-auto-update-design.md).
set -euo pipefail
cd "$(dirname "$0")/.."

# shellcheck source=docker/update-mods.sh
source docker/update-mods.sh

fail=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "${expected}" != "${actual}" ]; then
    echo "FAIL: ${desc} — expected '${expected}', got '${actual}'"
    fail=1
  else
    echo "PASS: ${desc}"
  fi
}

assert_true() {
  local desc="$1"; shift
  if "$@"; then
    echo "PASS: ${desc}"
  else
    echo "FAIL: ${desc}"
    fail=1
  fi
}

assert_false() {
  local desc="$1"; shift
  if "$@"; then
    echo "FAIL: ${desc} (expected false)"
    fail=1
  else
    echo "PASS: ${desc}"
  fi
}

assert_true  "1.3.0 is newer than 1.2.3" mod_version_newer "1.2.3" "1.3.0"
assert_false "1.2.3 is not newer than itself" mod_version_newer "1.2.3" "1.2.3"
assert_false "1.2.3 is not newer than 1.10.0" mod_version_newer "1.10.0" "1.2.3"
assert_true  "1.10.0 is newer than 1.9.0 (numeric, not lexical)" mod_version_newer "1.9.0" "1.10.0"

assert_eq "parses simple mod filename" "some-mod 1.2.3" "$(parse_mod_filename 'some-mod_1.2.3.zip')"
assert_eq "parses mod name containing underscores" "my_mod_name 0.10.5" "$(parse_mod_filename 'my_mod_name_0.10.5.zip')"
assert_eq "rejects filename with no version" "" "$(parse_mod_filename 'not-a-versioned-mod.zip')"

assert_true  "name found in ignore list" is_ignored "foo" "bar,foo,baz"
assert_true  "name found in ignore list with spaces" is_ignored "foo" "bar, foo , baz"
assert_false "name not in ignore list" is_ignored "qux" "bar,foo,baz"
assert_false "empty ignore list matches nothing" is_ignored "foo" ""

exit "${fail}"
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `chmod +x scripts/test-update-mods.sh && bash scripts/test-update-mods.sh`
Expected: FAIL — `docker/update-mods.sh: No such file or directory` (the `source` line fails, since the file doesn't exist yet).

- [ ] **Step 3: Write `docker/update-mods.sh`**

Create `docker/update-mods.sh`:

```bash
#!/usr/bin/env bash
# Updates mods already present in the mods volume directory against the
# Factorio mod portal. Invoked from entrypoint.sh only when UPDATE_MODS=true.
# Does not install new mods, resolve dependencies, or manage mod-list.json —
# it only version-bumps zips that are already there.
set -euo pipefail

FACTORIO_DIR="${FACTORIO_DIR:-/factorio}"
FACTORIO_HOME="${FACTORIO_HOME:-/opt/factorio}"
MODS_DIR="${FACTORIO_DIR}/mods"
BIN="${FACTORIO_HOME}/factorio"

log()  { printf '[update-mods] %s\n' "$*"; }
warn() { printf '[update-mods] WARNING: %s\n' "$*" >&2; }
die()  { printf '[update-mods] ERROR: %s\n' "$*" >&2; exit 1; }

# Returns success if $2 is a newer version than $1. Both are dotted numeric
# versions like "1.2.3" — compared numerically per-component via `sort -V`
# rather than lexically, since lexical comparison would rank "1.10.0" below
# "1.9.0".
mod_version_newer() {
  local current="$1" candidate="$2"
  [ "$current" != "$candidate" ] && \
    [ "$(printf '%s\n%s\n' "$current" "$candidate" | sort -V | tail -n1)" = "$candidate" ]
}

# Splits "name_1.2.3.zip" into "name version". Echoes nothing if the
# filename doesn't match that pattern. Always returns 0 regardless of
# match — callers assign its output via command substitution, and under
# `set -e` a non-zero exit from a bare `var=$(...)` assignment would abort
# the whole script, which is exactly the single-bad-mod-shouldn't-abort-
# boot behavior this script must avoid.
parse_mod_filename() {
  local base="$1"
  base="${base%.zip}"
  if [[ "$base" =~ ^(.+)_([0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
    printf '%s %s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
  fi
  return 0
}

# Returns success if $1 is present in the comma-separated list $2.
is_ignored() {
  local name="$1" list="$2" item
  IFS=',' read -ra items <<< "$list"
  for item in "${items[@]}"; do
    item="$(printf '%s' "$item" | xargs)"
    [ "$item" = "$name" ] && return 0
  done
  return 1
}

# Checks one mod against the portal and replaces it in place if a newer
# release exists for the given Factorio major.minor line. Never aborts the
# script — any failure here is logged and the mod is left as-is.
update_one_mod() {
  local zip_path="$1" name="$2" current_version="$3" factorio_line="$4"
  local username="$5" token="$6"

  local api_url="https://mods.factorio.com/api/mods/${name}"
  local releases
  if ! releases="$(curl -fsSL "${api_url}" 2>/dev/null | jq -c '.releases // []' 2>/dev/null)"; then
    warn "${name}: could not reach mod portal, leaving ${current_version} in place"
    return 0
  fi

  local best
  best="$(printf '%s' "${releases}" | jq -c --arg line "${factorio_line}" '
    [.[] | select(.info_json.factorio_version == $line)]
    | sort_by(.version | split(".") | map(tonumber))
    | last // empty
  ' 2>/dev/null)" || true

  if [ -z "${best}" ] || [ "${best}" = "null" ]; then
    log "${name}: no release for Factorio ${factorio_line}, leaving ${current_version} in place"
    return 0
  fi

  local best_version best_url best_sha1
  best_version="$(printf '%s' "${best}" | jq -r '.version')"
  best_url="$(printf '%s' "${best}" | jq -r '.download_url')"
  best_sha1="$(printf '%s' "${best}" | jq -r '.sha1')"

  if ! mod_version_newer "${current_version}" "${best_version}"; then
    log "${name}: ${current_version} is already current"
    return 0
  fi

  log "${name}: ${current_version} -> ${best_version}"

  local tmp_file="${zip_path}.new"
  if ! curl -fsSL "https://mods.factorio.com${best_url}?username=${username}&token=${token}" \
      -o "${tmp_file}" 2>/dev/null; then
    warn "${name}: download failed, leaving ${current_version} in place"
    rm -f "${tmp_file}"
    return 0
  fi

  local actual_sha1
  actual_sha1="$(sha1sum "${tmp_file}" | cut -d' ' -f1)"
  if [ "${actual_sha1}" != "${best_sha1}" ]; then
    warn "${name}: checksum mismatch after download, leaving ${current_version} in place"
    rm -f "${tmp_file}"
    return 0
  fi

  rm -f "${zip_path}"
  mv "${tmp_file}" "${MODS_DIR}/${name}_${best_version}.zip"
}

main() {
  local username="${FACTORIO_USERNAME:-${USERNAME:-}}"
  local token="${FACTORIO_TOKEN:-${TOKEN:-}}"

  if [ -z "${username}" ] || [ -z "${token}" ]; then
    die "UPDATE_MODS=true but FACTORIO_USERNAME/FACTORIO_TOKEN are not set"
  fi

  local version_output factorio_line
  version_output="$("${BIN}" --version)"
  if [[ "${version_output}" =~ Version:\ ([0-9]+)\.([0-9]+)\. ]]; then
    factorio_line="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
  else
    die "could not determine Factorio version from: ${version_output}"
  fi
  log "checking mods against Factorio ${factorio_line}"

  shopt -s nullglob
  local zip_path
  for zip_path in "${MODS_DIR}"/*.zip; do
    local base parsed name current_version
    base="$(basename "${zip_path}")"
    parsed="$(parse_mod_filename "${base}")"
    if [ -z "${parsed}" ]; then
      warn "${base}: filename doesn't match name_x.y.z.zip, skipping"
      continue
    fi
    name="${parsed% *}"
    current_version="${parsed#* }"

    if is_ignored "${name}" "${MODS_IGNORE:-}"; then
      log "${name}: in MODS_IGNORE, skipping"
      continue
    fi

    update_one_mod "${zip_path}" "${name}" "${current_version}" "${factorio_line}" "${username}" "${token}"
  done
  shopt -u nullglob
}

# Allow sourcing this file (e.g. from scripts/test-update-mods.sh) without
# running main() — only run it when executed directly.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
```

- [ ] **Step 4: Run the unit tests and confirm they pass**

Run: `bash scripts/test-update-mods.sh`
Expected: every line prefixed `PASS:`, exit code 0.

- [ ] **Step 5: Syntax-check and lint**

Run: `bash -n docker/update-mods.sh && bash -n scripts/test-update-mods.sh`
Expected: no output (both are syntactically valid).

Run (if `shellcheck` is installed): `shellcheck docker/update-mods.sh scripts/test-update-mods.sh`
Expected: no warnings. If `shellcheck` isn't installed locally, note that and move on — `scripts/lint.sh` already handles this the same way (skips with a warning rather than failing), and Task 3 wires these two files into that script.

- [ ] **Step 6: Commit**

```bash
git add docker/update-mods.sh scripts/test-update-mods.sh
git commit -m "$(cat <<'EOF'
Add mod auto-update script with unit tests for its pure-logic helpers

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Wire `UPDATE_MODS`/`MODS_IGNORE` into `docker/entrypoint.sh`

**Files:**
- Modify: `docker/entrypoint.sh:4-9` (top-of-file responsibilities comment)
- Modify: `docker/entrypoint.sh:188-215` (insert a new numbered section between the existing "3. server-settings.json" and "4. save file" sections, renumbering "4. save file" to "5." and "5. launch" to "6.")

**Interfaces:**
- Consumes: `docker/update-mods.sh`'s `main()` behavior from Task 1 (invoked as a subprocess, not sourced — this call site doesn't need any of Task 1's individual function names, just the script's exit-on-`die()` / warn-and-continue-per-mod contract). Also consumes the existing `jqbool()` helper already defined earlier in `entrypoint.sh` (`docker/entrypoint.sh:93-98`).
- Produces: nothing new consumed by later tasks — Task 3 only needs this call site to exist so the packaged image actually invokes the script.

- [ ] **Step 1: Update the top-of-file responsibilities comment**

In `docker/entrypoint.sh`, replace lines 4-9:

```bash
# Responsibilities, in order:
#   1. normalise ownership of the data volume and drop root (if started as root)
#   2. lay out the volume on first run
#   3. render server-settings.json (and friends) from environment variables
#   4. create a save if none exists
#   5. exec the server so it receives signals directly
```

with:

```bash
# Responsibilities, in order:
#   1. normalise ownership of the data volume and drop root (if started as root)
#   2. lay out the volume on first run
#   3. render server-settings.json (and friends) from environment variables
#   4. update mods against the portal, if UPDATE_MODS=true
#   5. create a save if none exists
#   6. exec the server so it receives signals directly
```

- [ ] **Step 2: Insert the mod-update call and renumber the sections after it**

In `docker/entrypoint.sh`, find this block (currently lines 188-198):

```bash
# --------------------------------------------------------------------------
# 4. save file
# --------------------------------------------------------------------------
SAVE_NAME="${SAVE_NAME:-default}"
SAVE_PATH="${FACTORIO_DIR}/saves/${SAVE_NAME}.zip"

shopt -s nullglob
existing_saves=("${FACTORIO_DIR}"/saves/*.zip)
shopt -u nullglob

if [ ${#existing_saves[@]} -eq 0 ]; then
```

Replace it with:

```bash
# --------------------------------------------------------------------------
# 4. mods
# --------------------------------------------------------------------------
if [ "$(jqbool "${UPDATE_MODS:-false}")" = "true" ]; then
  log "UPDATE_MODS=true, checking mods against the portal"
  /usr/local/bin/update-mods.sh
fi

# --------------------------------------------------------------------------
# 5. save file
# --------------------------------------------------------------------------
SAVE_NAME="${SAVE_NAME:-default}"
SAVE_PATH="${FACTORIO_DIR}/saves/${SAVE_NAME}.zip"

shopt -s nullglob
existing_saves=("${FACTORIO_DIR}"/saves/*.zip)
shopt -u nullglob

if [ ${#existing_saves[@]} -eq 0 ]; then
```

Then find the existing `# 5. launch` section comment further down (currently around line 213-215):

```bash
# --------------------------------------------------------------------------
# 5. launch
# --------------------------------------------------------------------------
```

Replace it with:

```bash
# --------------------------------------------------------------------------
# 6. launch
# --------------------------------------------------------------------------
```

- [ ] **Step 3: Syntax-check**

Run: `bash -n docker/entrypoint.sh`
Expected: no output.

Run: `grep -n '^# *[0-9]\. ' docker/entrypoint.sh`
Expected: six lines, numbered 1 through 6 in order, with "4. mods" and "5. save file" and "6. launch" all present exactly once each.

- [ ] **Step 4: Commit**

```bash
git add docker/entrypoint.sh
git commit -m "$(cat <<'EOF'
Call update-mods.sh from entrypoint.sh when UPDATE_MODS=true

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Package `update-mods.sh` into the image, add `curl`, document, and verify end-to-end

**Files:**
- Modify: `docker/Dockerfile:73-93` (add `curl` to the runtime package list, copy and chmod the new script)
- Modify: `README.md:156-166` (new `### Mods` subsection with its env var table, inserted between the existing `### Saves` and `### Container` subsections)
- Modify: `scripts/lint.sh` (include `scripts/test-update-mods.sh` in the checks it runs)

**Interfaces:**
- Consumes: `docker/update-mods.sh` from Task 1, the entrypoint call site from Task 2. This task's deliverable is the first point at which the whole feature is actually exercisable end-to-end in a real container.
- Produces: nothing consumed by later tasks — this is the last task.

- [ ] **Step 1: Add `curl` to the Dockerfile's runtime package list**

In `docker/Dockerfile`, replace lines 73-86:

```dockerfile
# jq     - safe JSON generation for server-settings.json et al
# gosu   - clean privilege drop when the container is started as root
# tini   - PID 1 that reaps zombies and forwards SIGTERM for clean save-on-exit
# procps - provides pgrep, used by healthcheck.sh to find the server process
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      gosu \
      jq \
      procps \
      tini \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd -g "${PGID}" factorio \
 && useradd -l -u "${PUID}" -g "${PGID}" -d /factorio -s /usr/sbin/nologin factorio
```

with:

```dockerfile
# curl   - fetches mod portal metadata and mod zips for update-mods.sh
# jq     - safe JSON generation for server-settings.json et al, and mod
#          portal response parsing in update-mods.sh
# gosu   - clean privilege drop when the container is started as root
# tini   - PID 1 that reaps zombies and forwards SIGTERM for clean save-on-exit
# procps - provides pgrep, used by healthcheck.sh to find the server process
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      gosu \
      jq \
      procps \
      tini \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd -g "${PGID}" factorio \
 && useradd -l -u "${PUID}" -g "${PGID}" -d /factorio -s /usr/sbin/nologin factorio
```

- [ ] **Step 2: Copy and install `update-mods.sh` alongside the other scripts**

In `docker/Dockerfile`, replace lines 88-93:

```dockerfile
COPY --from=downloader /opt/factorio /opt/factorio
COPY entrypoint.sh healthcheck.sh /usr/local/bin/

RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/healthcheck.sh \
 && mkdir -p /factorio \
 && chown -R "${PUID}:${PGID}" /factorio /opt/factorio
```

with:

```dockerfile
COPY --from=downloader /opt/factorio /opt/factorio
COPY entrypoint.sh healthcheck.sh update-mods.sh /usr/local/bin/

RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/healthcheck.sh /usr/local/bin/update-mods.sh \
 && mkdir -p /factorio \
 && chown -R "${PUID}:${PGID}" /factorio /opt/factorio
```

- [ ] **Step 3: Add the `### Mods` section to the README**

In `README.md`, insert this new subsection immediately after the existing `### Saves` subsection (after line 165, i.e. right before the `### Container` heading at line 167):

```markdown
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
```

- [ ] **Step 4: Wire the new unit tests into `scripts/lint.sh`, and cover `update-mods.sh` in the shellcheck line**

`scripts/lint.sh`'s `bash -n` loop (`docker/*.sh scripts/*.sh`) and shellcheck's `scripts/*.sh` glob will already pick up the two new files automatically for syntax/lint checking — but shellcheck's `docker/` half of that line hardcodes `docker/entrypoint.sh docker/healthcheck.sh` rather than globbing, so `docker/update-mods.sh` needs adding explicitly. Nothing in the file actually *runs* `scripts/test-update-mods.sh` as a test yet either, so that needs a new section.

In `scripts/lint.sh`, replace:

```bash
if command -v shellcheck >/dev/null; then
  echo "==> shellcheck"
  shellcheck docker/entrypoint.sh docker/healthcheck.sh scripts/*.sh || fail=1
else
  echo "==> shellcheck not installed, skipping" >&2
fi
```

with:

```bash
if command -v shellcheck >/dev/null; then
  echo "==> shellcheck"
  shellcheck docker/entrypoint.sh docker/healthcheck.sh docker/update-mods.sh scripts/*.sh || fail=1
else
  echo "==> shellcheck not installed, skipping" >&2
fi
```

Then replace:

```bash
echo "==> bash -n"
for f in docker/*.sh scripts/*.sh; do bash -n "$f" || fail=1; done

exit "$fail"
```

with:

```bash
echo "==> bash -n"
for f in docker/*.sh scripts/*.sh; do bash -n "$f" || fail=1; done

echo "==> update-mods unit tests"
bash scripts/test-update-mods.sh || fail=1

exit "$fail"
```

- [ ] **Step 5: Run the full local lint suite**

Run: `bash scripts/lint.sh`
Expected: exit code 0, with `==> update-mods unit tests` showing all `PASS:` lines among its output.

- [ ] **Step 6: Build the image locally, if Docker is available**

Run:
```bash
docker build ./docker \
  --build-arg FACTORIO_VERSION="$(./scripts/resolve-release.sh stable | jq -r .version)" \
  -t factorio-server:mod-update-test
```
Expected: build succeeds. If Docker isn't available in this environment, note that explicitly in the task report instead of skipping silently — this step is the only place `curl`'s presence in the runtime image and the `COPY`/`chmod` changes get verified before merge.

- [ ] **Step 7: Boot it with `UPDATE_MODS` unset and confirm the default path is unaffected**

Run:
```bash
docker run --rm -d --name mod-update-test \
  -e RCON_PASSWORD=test \
  factorio-server:mod-update-test
sleep 15
docker logs mod-update-test
docker stop mod-update-test
```
Expected: logs show the server starting normally, with no `[update-mods]`-prefixed lines (since `UPDATE_MODS` defaults to `false`). This mirrors CI's own smoke test and is this task's evidence that the feature is fully off by default. If Docker isn't available, note that explicitly instead of skipping silently, same as Step 6.

- [ ] **Step 8: Document the manual live-update verification recipe**

This isn't something to run as part of this task (it needs a real factorio.com account and a real mod), but note in the task report, for whoever verifies this feature against the live portal later: boot the image with `UPDATE_MODS=true`, valid `FACTORIO_USERNAME`/`FACTORIO_TOKEN`, and an intentionally-outdated real mod zip (e.g. rename a mod's file to an older version number than what's actually inside it) already in the mounted `mods/` volume, then confirm the logs show `[update-mods] <name>: <old> -> <new>` and the zip on disk was replaced.

- [ ] **Step 9: Commit**

```bash
git add docker/Dockerfile README.md scripts/lint.sh
git commit -m "$(cat <<'EOF'
Package update-mods.sh into the image, add curl, document UPDATE_MODS

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review Notes

- **Spec coverage:** env vars (Task 1 consumes them, Task 3 documents them), update algorithm including credential fail-fast and per-mod resilience (Task 1), entrypoint integration point and ordering (Task 2), Dockerfile `curl` addition (Task 3), README `## Mods` section (Task 3), testing approach — pure-logic unit tests automated, live path manually verified (Task 1 + Task 3 Step 8) — every section of the design spec maps to a task.
- **Placeholder scan:** no TBD/TODO; every step has literal file content or an exact command with a stated expected result.
- **Type/name consistency:** `mod_version_newer`, `parse_mod_filename`, `is_ignored`, `update_one_mod` are defined once in Task 1 and referenced by the same names in Task 1's own test script; Task 2's call site (`/usr/local/bin/update-mods.sh`) matches the install path Task 3's Dockerfile step creates; `UPDATE_MODS`/`MODS_IGNORE` are spelled identically across all three tasks.
- **Fixed during self-review:** `parse_mod_filename`'s explicit `return 0` (documented inline in Task 1's Step 3 code) — without it, a malformed mod filename would make `parsed="$(parse_mod_filename "${base}")"` in `main()`'s loop exit non-zero under `set -e`, aborting the whole update run (and thus the container boot) over one bad filename — a direct violation of the spec's per-mod-failure-doesn't-abort-boot requirement. Caught by reasoning through the `set -euo pipefail` interaction before writing the step, not left for the implementer to discover.
