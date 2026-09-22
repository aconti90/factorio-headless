#!/usr/bin/env bash
# Liveness probe for the headless server.
#
# Deliberately dependency-free: rather than pulling in an RCON client or netcat,
# this reads /proc. It checks two things:
#   1. a factorio process is alive
#   2. that process is bound to the game port — i.e. it finished loading the map,
#      rather than dying mid-start or hanging on a corrupt save
set -euo pipefail

PORT="${PORT:-34197}"
FACTORIO_HOME="${FACTORIO_HOME:-/opt/factorio}"

# The entrypoint always execs the stable symlink at ${FACTORIO_HOME}/factorio
# (whose target differs by architecture), so the server's command line begins
# with exactly that; the real per-architecture path under bin/ is also accepted
# so overriding the container command still health-checks correctly. Anchoring
# the match keeps an unrelated process that merely mentions the path — a wrapper
# shell, a docker exec — from looking like a healthy server.
if ! pgrep -f "^${FACTORIO_HOME}/(bin/[^/]+/)?factorio( |$)" >/dev/null 2>&1; then
  echo "unhealthy: no factorio process found"
  exit 1
fi

# /proc/net/udp lists local addresses as HEX_IP:HEX_PORT. udp6 is absent on
# IPv6-disabled hosts, and awk treats a missing file as a fatal error, so only
# pass the ones that are actually readable.
proc_files=()
for f in /proc/net/udp /proc/net/udp6; do
  if [ -r "$f" ]; then
    proc_files+=("$f")
  fi
done

if [ ${#proc_files[@]} -eq 0 ]; then
  echo "unhealthy: cannot read /proc/net/udp*"
  exit 1
fi

# FNR (not NR) so the header of *each* file is skipped, not just the first.
if awk -v want="$(printf '%04X' "${PORT}")" \
     'FNR > 1 { split($2, addr, ":"); if (addr[2] == want) found = 1 }
      END { exit !found }' "${proc_files[@]}"; then
  exit 0
fi

echo "unhealthy: factorio is running but not bound to UDP ${PORT}"
exit 1
