# Docker Hub publishing

## Problem

Images currently publish only to `ghcr.io/aconti90/factorio-headless`. GHCR is
free and zero-config (the image name falls straight out of the GitHub repo
path), but Docker Hub is where most people default to searching — `docker
pull` with no registry prefix goes there, and it's what homelab/self-hosted
tooling and users expect to check first. Publishing there too makes the image
easier for people to find and adopt.

This repo is also set up as a template others fork (`scripts/init.sh`
rewrites `OWNER/REPO` placeholders). Docker Hub publishing is being added
for this repo's own use, not as a generic feature for forks — but it must
not break the zero-config promise for someone who forks the template and
never touches Docker Hub at all.

## Goal

Publish every image `build.yml` already pushes to GHCR to Docker Hub too, in
the same CI run, with the same tags. No separate setup flow, no placeholder
rewriting for it — configuration lives entirely in GitHub repo settings.

## Non-goals

- Making Docker Hub credentials/namespace configurable via `scripts/init.sh`
  or any other in-repo mechanism. A fork that wants this either sets the same
  two repo-config values or doesn't publish to Docker Hub.
- Attaching GitHub's build-provenance attestation to the Docker Hub image.
  That's a GitHub-specific attestation record; whether Docker Hub supports
  attaching it via the OCI referrers API the same way GHCR does is untested,
  and not worth the risk here. The SBOM/provenance embedded directly in the
  image manifest (`provenance: mode=max, sbom: true` on the build step)
  still replicates to Docker Hub automatically, since it's part of the same
  push.
- A backfill of historical tags already published to GHCR. Only future
  builds get mirrored.

## Configuration

Two values, both set once in the GitHub repo's **Settings → Secrets and
variables → Actions**, never written into a file:

| Name | Kind | Purpose |
|---|---|---|
| `DOCKERHUB_USERNAME` | Repository **variable** | Docker Hub namespace to publish under. Not sensitive — just an identifier. |
| `DOCKERHUB_TOKEN` | Repository **secret** | Docker Hub access token (Account Settings → Security → New Access Token, Read & Write scope) used to authenticate the push. |

If `DOCKERHUB_USERNAME` is unset, every Docker Hub-related step in the
workflow is skipped and behavior is byte-for-byte what it is today
(GHCR-only). This isn't a maintained "opt-in feature" for forks — it's the
natural consequence of reading from a variable that might be empty, and it
keeps a bare fork from failing CI the moment someone runs the workflow
without a Docker Hub token they were never asked to set up.

## Image naming

Docker Hub's repo name mirrors the GitHub repo name automatically, the same
way the GHCR name is already derived from `GITHUB_REPOSITORY` rather than
hardcoded — so a repo rename doesn't require a workflow edit.

- GHCR (unchanged): `ghcr.io/${GITHUB_REPOSITORY,,}`
- Docker Hub (new): `${{ vars.DOCKERHUB_USERNAME }}/<repo-name-lowercased>`,
  where `<repo-name-lowercased>` is `GITHUB_REPOSITORY` with the `owner/`
  prefix stripped.

## Workflow changes

**`build.yml`**

- Declare `secrets: { DOCKERHUB_TOKEN: { required: false } }` under
  `on.workflow_call`, so the reusable workflow can accept it from a caller.
- "Derive tags" step: the existing version/channel/floating-tag logic
  (`:VERSION`, `:channel`, and — for the stable channel — `:minor`, `:major`,
  `:latest`) is applied identically to both image prefixes by looping over
  an array of them: GHCR's is always present, Docker Hub's is appended only
  when `vars.DOCKERHUB_USERNAME` is non-empty. This means the two registries
  can never drift out of sync on tagging rules — there's exactly one place
  that decides what a version/channel maps to.
- New "Log in to Docker Hub" step (`docker/login-action`, default registry
  `docker.io`), gated on `vars.DOCKERHUB_USERNAME != ''`.
- "Build and push" step is otherwise unchanged — its `tags` input already
  contains both registries' full tag lists once "Derive tags" is updated, so
  buildx builds once and pushes the same multi-arch manifest to both.
- "Attest build provenance" step stays targeting the GHCR image only (see
  Non-goals).
- New "Sync Docker Hub description" step (`peter-evans/dockerhub-description@v4`,
  pinned to a major version tag like every other action in this workflow),
  gated on `vars.DOCKERHUB_USERNAME != ''`, pushes `README.md` as the Docker
  Hub repo's Overview on every publish so it can't go stale.
- "Summary" step: extend to also list the Docker Hub tags when present, for
  visibility in the Actions run summary.

**`release-watch.yml`**

- Add `secrets: inherit` to the `uses: ./.github/workflows/build.yml` call.
  Reusable workflows don't automatically receive custom secrets from their
  caller (unlike `GITHUB_TOKEN`, which is always available) — without this,
  `DOCKERHUB_TOKEN` would never reach `build.yml` when triggered by the
  release-watch schedule.
- `workflow_dispatch` (manual runs of `build.yml` directly) already has
  native access to repo secrets/vars — no plumbing needed there.

**`README.md`**

- Add the Docker Hub `docker pull` example alongside the existing GHCR one.
- Add a short note under "Setting it up as your own" naming the two config
  values and stating that Docker Hub publishing is skipped entirely if
  they're not set.

## Error handling

A Docker Hub login/push failure (bad token, Docker Hub outage, rate limit)
fails the whole `build` job, the same way a GHCR failure does today — there's
no separate job boundary to partially succeed across. Because both registries
are pushed within one `docker buildx build --push` invocation, it's possible
in principle for GHCR's push to complete before a subsequent Docker Hub push
fails, leaving that version live on GHCR but missing from Docker Hub for a
given run. This is visible immediately (the job goes red) and self-heals by
re-running `build.yml` via `workflow_dispatch` for that version once the
underlying issue (e.g. an expired token) is fixed. This is an acceptable,
low-probability edge case — it's the same single-point-of-failure shape the
job already has for GHCR alone.

## Rollout (not code — steps taken after merge)

1. Create a Docker Hub access token (Read & Write scope).
2. Add `DOCKERHUB_USERNAME` (repo variable) and `DOCKERHUB_TOKEN` (repo
   secret) in GitHub repo settings.
3. Trigger `build.yml` via `workflow_dispatch` for an already-released
   version and confirm:
   - `docker pull ghcr.io/aconti90/factorio-headless:stable` still works.
   - `docker pull aconti90/factorio-headless:stable` now works.
   - The Docker Hub repo's Overview page shows the synced README.

## Testing

No new automated test is warranted for this — it's CI/publishing
infrastructure, not application logic, and the existing `ci.yml` smoke test
already exercises the image build itself. Verification is the manual
`workflow_dispatch` rollout check above, done once after merge.
