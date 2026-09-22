#!/usr/bin/env bash
# One-time setup: point this repo at your own GitHub repository, so the README
# badges and the example compose files reference your published image.
#
#   scripts/init.sh your-github-user/your-repo-name
#
# With no argument it reads the origin remote, so the usual flow is just:
#   git remote add origin git@github.com:you/your-repo.git && scripts/init.sh
set -euo pipefail
cd "$(dirname "$0")/.."

placeholder='OWNER'/'REPO'   # split so this script never rewrites itself

target="${1:-}"
if [ -z "${target}" ]; then
  target="$(git remote get-url origin 2>/dev/null \
            | sed -E 's|^.*github\.com[:/]||; s|\.git$||' || true)"
fi

if [[ "${target}" != */* ]]; then
  echo "usage: $0 <owner>/<repo>   (or add an origin remote first)" >&2
  exit 2
fi

mapfile -t files < <(grep -rl "${placeholder}" . --exclude-dir=.git --exclude='init.sh' || true)

if [ ${#files[@]} -eq 0 ]; then
  echo "already initialised — nothing to do"
  exit 0
fi

echo "==> pointing this repo at ${target}"
for f in "${files[@]}"; do
  sed -i "s|${placeholder}|${target}|g" "$f"
  echo "    ${f}"
done

cat <<EOF

Done. Next steps:
  1. git add -A && git commit -m "Initial commit" && git push
  2. On GitHub: Settings > Actions > General > Workflow permissions
     -> enable "Read and write permissions" so the workflow can push packages
  3. Actions > "Watch for Factorio releases" > Run workflow
     -> publishes the first images; after that it runs on its own schedule
  4. Once published, make the package public:
     the repo's Packages sidebar > package settings > Change visibility
EOF
