#!/usr/bin/env bash
# Run the same checks CI runs, locally.
set -euo pipefail
cd "$(dirname "$0")/.."

fail=0

if command -v shellcheck >/dev/null; then
  echo "==> shellcheck"
  shellcheck docker/entrypoint.sh docker/healthcheck.sh scripts/*.sh || fail=1
else
  echo "==> shellcheck not installed, skipping" >&2
fi

if command -v hadolint >/dev/null; then
  echo "==> hadolint"
  hadolint docker/Dockerfile || fail=1
else
  echo "==> hadolint not installed, skipping" >&2
fi

echo "==> compose config"
for f in examples/docker-compose*.yml; do
  docker compose -f "$f" --env-file examples/.env.example config >/dev/null || fail=1
done

echo "==> bash -n"
for f in docker/*.sh scripts/*.sh; do bash -n "$f" || fail=1; done

exit "$fail"
