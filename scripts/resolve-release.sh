#!/usr/bin/env bash
# Resolve the current Factorio headless release for a channel, and discover
# which architectures Wube has actually published for it.
#
# This probing is not paranoia: at the time of writing the arm64 headless build
# exists on the experimental channel but 404s on stable. Architecture
# availability is therefore a per-release fact that has to be discovered, not
# an assumption that can be baked into the build matrix.
#
# Usage:   scripts/resolve-release.sh [stable|experimental]
# Output:  a single line of JSON, e.g.
#   {"channel":"stable","version":"2.0.77","platforms":"linux/amd64","sha256":{"linux/amd64":"ab12..."}}
set -euo pipefail

API_URL="https://factorio.com/api/latest-releases"
SUMS_URL="https://factorio.com/download/sha256sums/"
DL_BASE="https://factorio.com/get-download"

channel="${1:-stable}"
case "${channel}" in
  stable|experimental) ;;
  *) echo "usage: $0 [stable|experimental]" >&2; exit 2 ;;
esac

version="$(curl -fsS --retry 3 "${API_URL}" | jq -r --arg c "${channel}" '.[$c].headless // empty')"
[ -n "${version}" ] || { echo "could not resolve ${channel} headless version" >&2; exit 1; }

# Wube explicitly asks integrators to poll the releases API rather than hammer
# the download endpoint, so probe with a one-byte range request: enough to learn
# whether the artefact exists without pulling ~400MB per architecture per run.
probe() {
  local distro="$1" code
  code="$(curl -fsS -o /dev/null -w '%{http_code}' -r 0-0 -L \
            "${DL_BASE}/${version}/headless/${distro}" 2>/dev/null || true)"
  [ "${code}" = "200" ] || [ "${code}" = "206" ]
}

platforms=()
declare -A distro_of=( [linux/amd64]=linux64 [linux/arm64]=linux-arm64 )
for platform in linux/amd64 linux/arm64; do
  if probe "${distro_of[$platform]}"; then
    platforms+=("${platform}")
    echo "  ✓ ${platform} (${distro_of[$platform]})" >&2
  else
    echo "  ✗ ${platform} (${distro_of[$platform]}) — not published for ${version}" >&2
  fi
done

[ ${#platforms[@]} -gt 0 ] || { echo "no architectures available for ${version}" >&2; exit 1; }

# Checksums are best-effort: upstream publishes sums for the x64 tarball, and
# has not (yet) listed the arm64 one. A missing sum downgrades to an unverified
# download rather than failing the build, and the Dockerfile logs when it does.
sums_page="$(curl -fsS --retry 3 "${SUMS_URL}" 2>/dev/null || true)"
lookup_sum() {
  printf '%s' "${sums_page}" \
    | grep -E "[[:space:]]factorio-headless_${1}_${version}\.tar\.xz$" \
    | awk '{print $1}' | head -n1
}

sha_json='{}'
for platform in "${platforms[@]}"; do
  case "${platform}" in
    linux/amd64) sum="$(lookup_sum linux || true)"   ;;
    linux/arm64) sum="$(lookup_sum linux-arm64 || true)" ;;
  esac
  if [ -n "${sum:-}" ]; then
    sha_json="$(jq -c --arg p "${platform}" --arg s "${sum}" '. + {($p): $s}' <<<"${sha_json}")"
  fi
done

jq -cn \
  --arg channel   "${channel}" \
  --arg version   "${version}" \
  --arg platforms "$(IFS=,; echo "${platforms[*]}")" \
  --argjson sha256 "${sha_json}" \
  '{channel: $channel, version: $version, platforms: $platforms, sha256: $sha256}'
