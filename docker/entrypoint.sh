#!/usr/bin/env bash
# Factorio headless server entrypoint.
#
# Responsibilities, in order:
#   1. normalise ownership of the data volume and drop root (if started as root)
#   2. lay out the volume on first run
#   3. render server-settings.json (and friends) from environment variables
#   4. create a save if none exists
#   5. exec the server so it receives signals directly
set -euo pipefail

FACTORIO_DIR="${FACTORIO_DIR:-/factorio}"
FACTORIO_HOME="${FACTORIO_HOME:-/opt/factorio}"
BIN="${FACTORIO_HOME}/factorio"

log()  { printf '[entrypoint] %s\n' "$*"; }
warn() { printf '[entrypoint] WARNING: %s\n' "$*" >&2; }
die()  { printf '[entrypoint] ERROR: %s\n' "$*" >&2; exit 1; }

# --------------------------------------------------------------------------
# 1. privilege handling
# --------------------------------------------------------------------------
# Running as root is supported for convenience (it lets us fix up ownership of
# a freshly created bind mount) but we never *stay* root. If the image is
# started with --user, we skip all of this and run as whoever we were given.
if [ "$(id -u)" = "0" ]; then
  PUID="${PUID:-845}"
  PGID="${PGID:-845}"

  # The image creates this user, but the entrypoint is also usable against a
  # hand-rolled base, so create it rather than failing confusingly if missing.
  if ! getent group factorio >/dev/null 2>&1; then
    groupadd -o -g "${PGID}" factorio
  fi
  if ! id -u factorio >/dev/null 2>&1; then
    useradd -o -u "${PUID}" -g "${PGID}" -d "${FACTORIO_DIR}" -s /usr/sbin/nologin factorio
  fi

  if [ "$(id -u factorio)" != "${PUID}" ] || [ "$(id -g factorio)" != "${PGID}" ]; then
    log "remapping factorio user to ${PUID}:${PGID}"
    groupmod -o -g "${PGID}" factorio
    usermod  -o -u "${PUID}" -g "${PGID}" factorio
  fi

  # Only chown when it is actually wrong — recursively chowning a large saves
  # directory on every boot is slow, especially on an SD card.
  if [ "$(stat -c '%u:%g' "${FACTORIO_DIR}")" != "${PUID}:${PGID}" ]; then
    log "fixing ownership of ${FACTORIO_DIR} (this may take a moment on first run)"
    chown -R "${PUID}:${PGID}" "${FACTORIO_DIR}"
  fi

  log "dropping privileges to ${PUID}:${PGID}"
  exec gosu "${PUID}:${PGID}" "$0" "$@"
fi

# --------------------------------------------------------------------------
# 2. volume layout
# --------------------------------------------------------------------------
mkdir -p \
  "${FACTORIO_DIR}/saves" \
  "${FACTORIO_DIR}/mods" \
  "${FACTORIO_DIR}/config" \
  "${FACTORIO_DIR}/scenarios" \
  "${FACTORIO_DIR}/script-output"

SETTINGS_FILE="${FACTORIO_DIR}/config/server-settings.json"
MAP_GEN_FILE="${FACTORIO_DIR}/config/map-gen-settings.json"
MAP_SETTINGS_FILE="${FACTORIO_DIR}/config/map-settings.json"
ADMINLIST_FILE="${FACTORIO_DIR}/config/server-adminlist.json"
WHITELIST_FILE="${FACTORIO_DIR}/config/server-whitelist.json"
BANLIST_FILE="${FACTORIO_DIR}/config/server-banlist.json"
CONFIG_INI="${FACTORIO_DIR}/config/config.ini"

# Seed the map-generation files from upstream examples so they are easy to edit,
# but never overwrite what the operator has already put there.
[ -f "${MAP_GEN_FILE}" ]      || cp "${FACTORIO_HOME}/data/map-gen-settings.example.json" "${MAP_GEN_FILE}"
[ -f "${MAP_SETTINGS_FILE}" ] || cp "${FACTORIO_HOME}/data/map-settings.example.json"     "${MAP_SETTINGS_FILE}"

# Without this, Factorio's write-data path defaults to alongside its own binary
# (${FACTORIO_HOME}), not the volume — so mods/saves/script-output would resolve
# outside ${FACTORIO_DIR}, and --start-server-load-latest (which takes no path
# argument) would find nothing there since the Dockerfile deletes that directory.
[ -f "${CONFIG_INI}" ] || cat > "${CONFIG_INI}" <<EOF
[path]
read-data=${FACTORIO_HOME}/data
write-data=${FACTORIO_DIR}
EOF

# --------------------------------------------------------------------------
# 3. server-settings.json
# --------------------------------------------------------------------------
# Booleans arrive as strings from the environment; jq needs real JSON booleans.
jqbool() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|y|on)  echo true ;;
    *)                echo false ;;
  esac
}

# Split "a,b,c" into a JSON array, trimming whitespace and dropping empties.
# Built with `jq -n --arg` rather than piping on stdin: an empty string yields
# zero input lines, which makes `jq -R` emit nothing at all, and the empty
# result then fails --argjson in the caller.
jqlist() {
  jq -cn --arg s "${1:-}" \
    '$s | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))'
}

if [ "$(jqbool "${UPDATE_CONFIG:-true}")" = "true" ] || [ ! -f "${SETTINGS_FILE}" ]; then
  log "rendering ${SETTINGS_FILE} from environment"

  # RCON without a password would expose an unauthenticated admin console, so
  # generate a strong one rather than silently starting without protection.
  if [ -z "${RCON_PASSWORD:-}" ]; then
    RCON_PASSWORD="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 32 || true)"
    warn "RCON_PASSWORD was not set; generated a random one for this container."
    warn "Set RCON_PASSWORD explicitly if you intend to use RCON."
  fi
  export RCON_PASSWORD

  jq -n \
    --arg     name          "${NAME:-Factorio}" \
    --arg     description   "${DESCRIPTION:-A Factorio server running in Docker}" \
    --argjson tags          "$(jqlist "${TAGS:-}")" \
    --argjson max_players   "${MAX_PLAYERS:-0}" \
    --argjson public        "$(jqbool "${VISIBILITY_PUBLIC:-false}")" \
    --argjson lan           "$(jqbool "${VISIBILITY_LAN:-true}")" \
    --arg     username      "${FACTORIO_USERNAME:-${USERNAME:-}}" \
    --arg     token         "${FACTORIO_TOKEN:-${TOKEN:-}}" \
    --arg     game_password "${GAME_PASSWORD:-}" \
    --argjson verify        "$(jqbool "${REQUIRE_USER_VERIFICATION:-true}")" \
    --argjson upload_max    "${MAX_UPLOAD_IN_KILOBYTES_PER_SECOND:-0}" \
    --argjson upload_slots  "${MAX_UPLOAD_SLOTS:-5}" \
    --argjson min_latency   "${MINIMUM_LATENCY_IN_TICKS:-0}" \
    --argjson pause_empty   "$(jqbool "${AUTO_PAUSE:-true}")" \
    --argjson pause_connect "$(jqbool "${AUTO_PAUSE_WHEN_PLAYERS_CONNECT:-false}")" \
    --argjson admins_pause  "$(jqbool "${ONLY_ADMINS_CAN_PAUSE_THE_GAME:-true}")" \
    --argjson autosave_only "$(jqbool "${AUTOSAVE_ONLY_ON_SERVER:-true}")" \
    --argjson nonblocking   "$(jqbool "${NON_BLOCKING_SAVING:-false}")" \
    --argjson autosave_int  "${AUTOSAVE_INTERVAL:-10}" \
    --argjson autosave_slot "${AUTOSAVE_SLOTS:-5}" \
    --argjson afk_kick      "${AFK_AUTOKICK_INTERVAL:-0}" \
    --argjson admins        "$(jqlist "${ADMINS:-}")" \
    '{
      name: $name,
      description: $description,
      tags: $tags,
      max_players: $max_players,
      visibility: { public: $public, lan: $lan },
      username: $username,
      token: $token,
      game_password: $game_password,
      require_user_verification: $verify,
      max_upload_in_kilobytes_per_second: $upload_max,
      max_upload_slots: $upload_slots,
      minimum_latency_in_ticks: $min_latency,
      ignore_player_limit_for_returning_players: false,
      allow_commands: "admins-only",
      autosave_interval: $autosave_int,
      autosave_slots: $autosave_slot,
      afk_autokick_interval: $afk_kick,
      auto_pause: $pause_empty,
      auto_pause_when_players_connect: $pause_connect,
      only_admins_can_pause_the_game: $admins_pause,
      autosave_only_on_server: $autosave_only,
      non_blocking_saving: $nonblocking,
      admins: $admins
    }' > "${SETTINGS_FILE}.tmp"

  mv "${SETTINGS_FILE}.tmp" "${SETTINGS_FILE}"
  chmod 600 "${SETTINGS_FILE}"   # it can hold a game password and an auth token
else
  log "keeping existing ${SETTINGS_FILE} (UPDATE_CONFIG=false)"
fi

# Optional player lists, rendered only when the corresponding variable is set so
# a hand-maintained file on the volume is never clobbered.
if [ -n "${ADMINS:-}" ]; then
  jqlist "${ADMINS}" > "${ADMINLIST_FILE}"
fi
if [ -n "${WHITELIST:-}" ]; then
  jqlist "${WHITELIST}" > "${WHITELIST_FILE}"
fi
if [ ! -f "${BANLIST_FILE}" ]; then
  echo '[]' > "${BANLIST_FILE}"
fi

# --------------------------------------------------------------------------
# 4. save file
# --------------------------------------------------------------------------
SAVE_NAME="${SAVE_NAME:-default}"
SAVE_PATH="${FACTORIO_DIR}/saves/${SAVE_NAME}.zip"

shopt -s nullglob
existing_saves=("${FACTORIO_DIR}"/saves/*.zip)
shopt -u nullglob

if [ ${#existing_saves[@]} -eq 0 ]; then
  if [ "$(jqbool "${GENERATE_NEW_SAVE:-true}")" = "true" ]; then
    log "no save found — generating a new map at ${SAVE_PATH}"
    "${BIN}" \
      --create "${SAVE_PATH}" \
      --map-gen-settings "${MAP_GEN_FILE}" \
      --map-settings "${MAP_SETTINGS_FILE}" \
      --config "${CONFIG_INI}"
  else
    die "no save found in ${FACTORIO_DIR}/saves and GENERATE_NEW_SAVE=false"
  fi
else
  log "found ${#existing_saves[@]} save(s) in ${FACTORIO_DIR}/saves"
fi

# --------------------------------------------------------------------------
# 5. launch
# --------------------------------------------------------------------------
args=(
  --port "${PORT:-34197}"
  --server-settings "${SETTINGS_FILE}"
  --server-banlist "${BANLIST_FILE}"
  --server-id "${FACTORIO_DIR}/config/server-id.json"
  --config "${CONFIG_INI}"
)

# Prefer the newest save unless the operator pinned one by name.
if [ "$(jqbool "${LOAD_LATEST_SAVE:-true}")" = "true" ]; then
  args+=(--start-server-load-latest)
else
  args+=(--start-server "${SAVE_PATH}")
fi

if [ -f "${ADMINLIST_FILE}" ]; then
  args+=(--server-adminlist "${ADMINLIST_FILE}")
fi
if [ -f "${WHITELIST_FILE}" ]; then
  args+=(--server-whitelist "${WHITELIST_FILE}" --use-server-whitelist)
fi
if [ -n "${BIND:-}" ]; then
  args+=(--bind "${BIND}")
fi
if [ -n "${CONSOLE_LOG:-}" ]; then
  args+=(--console-log "${CONSOLE_LOG}")
fi

if [ -n "${RCON_PASSWORD:-}" ]; then
  args+=(--rcon-port "${RCON_PORT:-27015}" --rcon-password "${RCON_PASSWORD}")
fi

# Anything the operator wants to pass straight through.
if [ -n "${EXTRA_ARGS:-}" ]; then
  # shellcheck disable=SC2206  # deliberate word-splitting of an argument string
  args+=(${EXTRA_ARGS})
fi

log "starting: factorio ${args[*]//${RCON_PASSWORD:-__none__}/******}"
exec "${BIN}" "${args[@]}"
