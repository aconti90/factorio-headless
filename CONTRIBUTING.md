# Contributing

Bug reports, feature requests, and PRs are welcome.

## Local development

- `scripts/resolve-release.sh [stable|experimental]` prints the current
  Factorio version, which architectures exist for it, and any published
  checksums — the same script CI uses.
- `scripts/lint.sh` runs the same checks CI runs: shellcheck, hadolint,
  compose config validation, and a bash syntax check. Install `shellcheck`
  and `hadolint` to get full coverage; the script skips whichever isn't
  installed and still runs the rest.
- The README's "Building locally" section has the commands for building the
  image itself.

## What CI checks on a PR

`ci.yml` runs shellcheck, hadolint, compose validation, and a smoke test
that boots the server, waits for the healthcheck to go green, and verifies
a clean SIGTERM shutdown. Everything except the smoke test is also
available locally via `scripts/lint.sh`.

## Making a change

- Keep changes minimal and scoped to one logical thing per PR.
- Follow the patterns already in the codebase — e.g. the
  registry-is-the-state design described in the README's "How the
  automation works" section. If you're changing how something works, a
  quick look at why it works that way today will save a round of review
  comments.
- For anything that changes behavior or adds configuration, open an issue
  first so the approach can be agreed on before you put time into it.
  Straightforward fixes don't need this.

## Code of conduct

Be respectful, assume good faith. That's it.
