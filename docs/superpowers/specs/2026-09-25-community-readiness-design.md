# Community readiness: health files + discoverability

## Problem

The image itself is solid — native multi-arch builds, automatic release
tracking, a real smoke test in CI, and (as of PR #7) publishing to both GHCR
and Docker Hub. But the repo has almost no community-facing infrastructure:
no `CONTRIBUTING.md`, no issue/PR templates, no GitHub topics, Discussions
disabled, and no social-proof badges. A stranger finding this repo has no
easy path to contribute, report a bug in a structured way, or even find it
via GitHub/Docker Hub search.

## Goal

Give the repo the minimum community infrastructure a well-run open source
project has: a place to land as a contributor (`CONTRIBUTING.md`, PR
template), a structured way to report bugs/request features (issue forms),
and the discoverability config that makes the repo findable in the first
place (topics, homepage, Discussions, badges).

## Non-goals

- `SECURITY.md` or any formal vulnerability disclosure process — this repo
  packages upstream binaries and wraps them in a Dockerfile; it doesn't run
  a service or handle user data, so the risk surface doesn't justify a
  separate policy right now.
- `CODE_OF_CONDUCT.md` as a standalone file — a one-line conduct note inside
  `CONTRIBUTING.md` is enough for a project this size; a full Contributor
  Covenant is unnecessary formality for a solo-maintainer repo.
- An issue template for "upstream Factorio release problem" — the
  release-watch automation already handles new releases without human
  involvement in the normal case, so a dedicated template would mostly sit
  unused. The generic bug-report template covers the rare case where it's
  actually needed.
- Any change to CI, the Dockerfile, or entrypoint/healthcheck scripts. This
  workstream is entirely new documentation/template files plus GitHub repo
  settings.
- Outreach/promotion (posting to r/factorio, r/selfhosted, awesome-docker
  lists, etc.) — worth doing once this infrastructure exists, but it's an
  action, not something to spec.

## Community health files

### `CONTRIBUTING.md` (new, repo root)

Short, practical, matches the README's terse voice. Contents:

- How to build and test locally — points at the README's existing
  "Building locally" section and `scripts/lint.sh` rather than duplicating
  the commands in two places.
- What CI checks on every PR: shellcheck, hadolint, compose validation, and
  the smoke test that boots the server and verifies a clean shutdown
  (`ci.yml`, already true today — this just documents it).
- Expectations: keep changes minimal and scoped, follow existing patterns
  (e.g. the "registry is the state" design philosophy called out in the
  README's automation section), one logical change per PR.
- A one-line informal conduct note ("be respectful, assume good faith") in
  place of a separate `CODE_OF_CONDUCT.md`.

The README's existing `## Contributing` section (currently just "run
`scripts/lint.sh`") is trimmed to a one-line pointer at `CONTRIBUTING.md`.
GitHub also surfaces `CONTRIBUTING.md` automatically in the new-issue and
new-PR flow and the repo's "Community" sidebar, so keeping the content in
one place avoids the two drifting apart.

### Issue templates (`.github/ISSUE_TEMPLATE/`)

GitHub Issue Forms (YAML), not classic Markdown templates — structured
fields instead of freeform text, and it's the current GitHub standard.

- **`bug-report.yml`**: dropdown for channel (`stable` / `experimental`),
  dropdown for architecture (`amd64` / `arm64`), text input for image tag,
  textarea for `docker logs` output, textarea for expected vs. actual
  behavior.
- **`feature-request.yml`**: what config/behavior is missing, why it's
  needed, what workaround (if any) is being used today.
- **`config.yml`**: `blank_issues_enabled: false`, with a contact link
  pointing questions ("how do I configure X", "has anyone run this on Y")
  at Discussions instead of Issues, so the tracker stays focused on actual
  bugs and feature requests.

### PR template (`.github/PULL_REQUEST_TEMPLATE.md`)

Minimal checklist: what changed and why, confirmation `scripts/lint.sh` was
run locally, linked issue if applicable.

## GitHub discoverability

### Repo metadata (via `gh repo edit`)

- **Topics**: `docker`, `factorio`, `factorio-server`, `game-server`,
  `headless-server`, `arm64`, `raspberry-pi`, `self-hosted`,
  `docker-image`, `multi-arch`.
- **Homepage URL**: `https://hub.docker.com/r/aconti90/factorio-headless`.
- **Discussions**: enabled, categories trimmed to Q&A, Ideas, and Show and
  tell (Polls/Announcements/General dropped as noise for a project this
  size).

These are live repo settings changes, applied directly via `gh repo edit`
and the Discussions API/UI — not committed files. They'll be called out
explicitly and confirmed before being applied.

### README badges

Added to the existing badge row (README.md, alongside the CI and
release-watch badges):

- Docker pulls — `https://img.shields.io/docker/pulls/aconti90/factorio-headless`
- Image size — `https://img.shields.io/docker/image-size/aconti90/factorio-headless/stable`
- License — `https://img.shields.io/github/license/aconti90/factorio-headless`

## Testing

These are documentation, template, and config changes — no runtime
behavior to test. Verification is:

- Issue forms render correctly when previewed on GitHub (fields show up,
  dropdowns populate).
- `CONTRIBUTING.md` and the trimmed README section don't contradict each
  other or duplicate content.
- Badge URLs resolve (shields.io returns a valid badge, not an error image)
  once the Docker Hub image exists.
- `gh repo edit` topics/homepage and Discussions enablement are confirmed
  via `gh repo view` after applying.
