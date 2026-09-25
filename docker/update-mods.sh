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
  [ -z "$list" ] && return 1
  local items=()
  IFS=',' read -ra items <<< "$list"
  for item in "${items[@]:-}"; do
    item="${item#"${item%%[![:space:]]*}"}"
    item="${item%"${item##*[![:space:]]}"}"
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

  local name_enc
  name_enc="$(jq -rn --arg n "${name}" '$n|@uri' 2>/dev/null)" || true
  if [ -z "${name_enc}" ]; then
    warn "${name}: could not URL-encode mod name, leaving ${current_version} in place"
    return 0
  fi

  local api_url="https://mods.factorio.com/api/mods/${name_enc}"
  local releases
  if ! releases="$(curl -fsSL --connect-timeout 10 --max-time 30 --retry 2 "${api_url}" 2>/dev/null | jq -c '.releases // []' 2>/dev/null)"; then
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
  if ! { best_version="$(printf '%s' "${best}" | jq -r '.version' 2>/dev/null)" && \
         best_url="$(printf '%s' "${best}" | jq -r '.download_url' 2>/dev/null)" && \
         best_sha1="$(printf '%s' "${best}" | jq -r '.sha1' 2>/dev/null)"; }; then
    warn "${name}: could not parse release metadata, leaving ${current_version} in place"
    return 0
  fi

  if ! mod_version_newer "${current_version}" "${best_version}"; then
    log "${name}: ${current_version} is already current"
    return 0
  fi

  if ! [[ "${best_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    warn "${name}: portal returned an invalid version '${best_version}', leaving ${current_version} in place"
    return 0
  fi
  if [[ "${best_url}" != /* ]]; then
    warn "${name}: portal returned an invalid download URL, leaving ${current_version} in place"
    return 0
  fi

  log "${name}: ${current_version} -> ${best_version}"

  local username_enc token_enc
  username_enc="$(jq -rn --arg u "${username}" '$u|@uri' 2>/dev/null)" || true
  token_enc="$(jq -rn --arg t "${token}" '$t|@uri' 2>/dev/null)" || true
  if [ -z "${username_enc}" ] || [ -z "${token_enc}" ]; then
    warn "${name}: could not URL-encode credentials, leaving ${current_version} in place"
    return 0
  fi

  local tmp_file="${zip_path}.new"
  if ! curl -fsSL --connect-timeout 10 --max-time 300 --retry 2 \
      "https://mods.factorio.com${best_url}?username=${username_enc}&token=${token_enc}" \
      -o "${tmp_file}" 2>/dev/null; then
    warn "${name}: download failed, leaving ${current_version} in place"
    rm -f "${tmp_file}"
    return 0
  fi

  local actual_sha1
  if ! actual_sha1="$(sha1sum "${tmp_file}" | cut -d' ' -f1)"; then
    warn "${name}: could not compute checksum, leaving ${current_version} in place"
    rm -f "${tmp_file}"
    return 0
  fi
  if [ "${actual_sha1}" != "${best_sha1}" ]; then
    warn "${name}: checksum mismatch after download, leaving ${current_version} in place"
    rm -f "${tmp_file}"
    return 0
  fi

  local new_zip_path="${MODS_DIR}/${name}_${best_version}.zip"
  if ! mv "${tmp_file}" "${new_zip_path}"; then
    warn "${name}: could not move new version into place, leaving ${current_version} in place"
    rm -f "${tmp_file}"
    return 0
  fi
  if ! rm -f "${zip_path}"; then
    warn "${name}: could not remove old version ${current_version}; both ${current_version} and ${best_version} are now present on disk"
  fi
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

  # Clean up any leftover temp files from a previous boot that was killed
  # mid-download; nullglob is already set above so a non-matching glob
  # expands to nothing rather than the literal pattern.
  rm -f "${MODS_DIR}"/*.zip.new

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
