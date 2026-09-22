# Docker Hub Publishing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish every image `build.yml` already pushes to GHCR to Docker Hub too, in the same CI run, with identical tags — configured entirely via GitHub repo settings, not hardcoded anywhere.

**Architecture:** Extend the existing single `build` job in `.github/workflows/build.yml` — one buildx build, pushed to both registries in the same invocation. Docker Hub steps are gated on a repo variable (`vars.DOCKERHUB_USERNAME`) being set, so an unconfigured repo behaves byte-for-byte like it does today.

**Tech Stack:** GitHub Actions (YAML), bash (workflow `run:` steps), `docker/login-action`, `docker/build-push-action`, `peter-evans/dockerhub-description`.

## Global Constraints

- Docker Hub config lives only in repo Settings (`vars.DOCKERHUB_USERNAME`, `secrets.DOCKERHUB_TOKEN`) — never hardcoded in any file.
- If `DOCKERHUB_USERNAME` is unset, behavior must be byte-for-byte identical to today (GHCR-only, same tag list, same steps run).
- `actions/attest-build-provenance` stays targeting the GHCR image only — not extended to Docker Hub.
- Docker Hub image name is derived, not hardcoded: `${{ vars.DOCKERHUB_USERNAME }}/<repo-name-lowercased>`, where `<repo-name-lowercased>` comes from `GITHUB_REPOSITORY`.
- No changes to `scripts/init.sh` or any placeholder-rewrite mechanism for this feature.
- New actions are pinned to a major version tag, matching every existing action reference in this repo (e.g. `@v4`, `@v3`, `@v6`) — never `@main` or unpinned.

Full design context: `docs/superpowers/specs/2026-09-22-dockerhub-publishing-design.md`.

---

### Task 1: Add Docker Hub publishing to `build.yml`

**Files:**
- Modify: `.github/workflows/build.yml:5-24` (add `secrets:` under `on.workflow_call`)
- Modify: `.github/workflows/build.yml:71-106` (add Docker Hub login step; rewrite "Derive tags" step)
- Modify: `.github/workflows/build.yml:145-150` (add "Sync Docker Hub description" step after "Attest build provenance")

**Interfaces:**
- Consumes: `steps.image.outputs.name` (existing, unchanged — the GHCR image name), `vars.DOCKERHUB_USERNAME`, `secrets.DOCKERHUB_TOKEN` (both new).
- Produces: `steps.tags.outputs.tags` (existing output name/shape kept — a single comma-separated tag list, now spanning both registries when Docker Hub is configured), `steps.tags.outputs.dockerhub-image` (new — empty string when Docker Hub isn't configured, else `"<username>/<repo-name>"`, e.g. `aconti90/factorio-headless`). Later tasks and steps must gate on `vars.DOCKERHUB_USERNAME != ''`, not on the tags/dockerhub-image outputs, since those aren't available at `if:` evaluation time for steps that run before "Derive tags".

- [ ] **Step 1: Write the tag-derivation script to a standalone file and confirm today's behavior**

This step's script is the same bash that will be pasted into the "Derive tags" step in Step 3 — writing it once and testing it standalone avoids transcribing it twice and lets us prove the "unconfigured repo is unaffected" constraint before touching the YAML.

Create `/tmp/derive-tags.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
minor="${VERSION%.*}"          # 2.1.19 -> 2.1
major="${VERSION%%.*}"         # 2.1.19 -> 2

repo_name="${GITHUB_REPOSITORY#*/}"
dockerhub_image=""
images=("${GHCR_IMAGE}")
if [ -n "${DOCKERHUB_USERNAME}" ]; then
  dockerhub_image="${DOCKERHUB_USERNAME}/${repo_name,,}"
  images+=("${dockerhub_image}")
fi

IFS=',' read -ra channel_list <<< "${CHANNELS}"

tags=""
for image in "${images[@]}"; do
  img_tags="${image}:${VERSION}"

  is_stable=false
  for channel in "${channel_list[@]}"; do
    channel="$(echo "${channel}" | tr -d '[:space:]')"
    [ -n "${channel}" ] || continue
    img_tags="${img_tags},${image}:${channel}"
    if [ "${channel}" = "stable" ]; then is_stable=true; fi
  done

  # Floating minor/major/latest tags only ever track the stable channel,
  # so an experimental release can never quietly become someone's :2.1.
  if [ "${is_stable}" = "true" ]; then
    img_tags="${img_tags},${image}:${minor},${image}:${major},${image}:latest"
  fi

  tags="${tags:+${tags},}${img_tags}"
done

{
  echo "tags=${tags}"
  echo "dockerhub-image=${dockerhub_image}"
} >> "$GITHUB_OUTPUT"
echo "Tagging: ${tags}"
```

Run it with `DOCKERHUB_USERNAME` unset, mirroring today's GHCR-only inputs:

```bash
chmod +x /tmp/derive-tags.sh
export GITHUB_OUTPUT="$(mktemp)"
GITHUB_REPOSITORY="aconti90/factorio-headless" \
VERSION="2.1.19" \
CHANNELS="stable" \
GHCR_IMAGE="ghcr.io/aconti90/factorio-headless" \
DOCKERHUB_USERNAME="" \
  /tmp/derive-tags.sh
cat "${GITHUB_OUTPUT}"
```

Expected output (exact):
```
tags=ghcr.io/aconti90/factorio-headless:2.1.19,ghcr.io/aconti90/factorio-headless:stable,ghcr.io/aconti90/factorio-headless:2.1,ghcr.io/aconti90/factorio-headless:2,ghcr.io/aconti90/factorio-headless:latest
dockerhub-image=
```

This must match today's `Derive tags` output exactly (same tag list, same order) — confirming the unconfigured case is unaffected before we rely on it inside the workflow.

- [ ] **Step 2: Run the same script with Docker Hub configured, verify mirrored tags**

```bash
export GITHUB_OUTPUT="$(mktemp)"
GITHUB_REPOSITORY="aconti90/factorio-headless" \
VERSION="2.1.19" \
CHANNELS="stable" \
GHCR_IMAGE="ghcr.io/aconti90/factorio-headless" \
DOCKERHUB_USERNAME="testuser" \
  /tmp/derive-tags.sh
cat "${GITHUB_OUTPUT}"
```

Expected output (exact):
```
tags=ghcr.io/aconti90/factorio-headless:2.1.19,ghcr.io/aconti90/factorio-headless:stable,ghcr.io/aconti90/factorio-headless:2.1,ghcr.io/aconti90/factorio-headless:2,ghcr.io/aconti90/factorio-headless:latest,testuser/factorio-headless:2.1.19,testuser/factorio-headless:stable,testuser/factorio-headless:2.1,testuser/factorio-headless:2,testuser/factorio-headless:latest
dockerhub-image=testuser/factorio-headless
```

Now confirm the floating-tag rule (`:minor`/`:major`/`:latest`) applies per-registry, not just to GHCR, by re-running with `CHANNELS="experimental"` (not `stable`) — floating tags must be absent from *both* registries:

```bash
export GITHUB_OUTPUT="$(mktemp)"
GITHUB_REPOSITORY="aconti90/factorio-headless" \
VERSION="2.1.19" \
CHANNELS="experimental" \
GHCR_IMAGE="ghcr.io/aconti90/factorio-headless" \
DOCKERHUB_USERNAME="" \
  /tmp/derive-tags.sh
cat "${GITHUB_OUTPUT}"
```

Expected output (exact):
```
tags=ghcr.io/aconti90/factorio-headless:2.1.19,ghcr.io/aconti90/factorio-headless:experimental
dockerhub-image=
```

```bash
export GITHUB_OUTPUT="$(mktemp)"
GITHUB_REPOSITORY="aconti90/factorio-headless" \
VERSION="2.1.19" \
CHANNELS="experimental" \
GHCR_IMAGE="ghcr.io/aconti90/factorio-headless" \
DOCKERHUB_USERNAME="testuser" \
  /tmp/derive-tags.sh
cat "${GITHUB_OUTPUT}"
```

Expected output (exact):
```
tags=ghcr.io/aconti90/factorio-headless:2.1.19,ghcr.io/aconti90/factorio-headless:experimental,testuser/factorio-headless:2.1.19,testuser/factorio-headless:experimental
dockerhub-image=testuser/factorio-headless
```

If any of these four runs don't match, fix `/tmp/derive-tags.sh` before continuing — do not paste unverified logic into the workflow file.

- [ ] **Step 3: Apply the verified script to `build.yml`, and declare the new secret**

Replace the `on.workflow_call` block (`.github/workflows/build.yml:5-24`) — add a `secrets:` key alongside the existing `inputs:`:

```yaml
on:
  workflow_call:
    inputs:
      version:
        description: Factorio version to build, e.g. 2.1.19
        required: true
        type: string
      channels:
        description: Comma-separated channel tags to apply, e.g. "stable" or "experimental,stable"
        required: true
        type: string
      platforms:
        description: Comma-separated buildx platforms, e.g. "linux/amd64,linux/arm64"
        required: true
        type: string
      sha256:
        description: JSON object mapping platform -> sha256 of the upstream tarball
        required: false
        type: string
        default: '{}'
    secrets:
      DOCKERHUB_TOKEN:
        description: Docker Hub access token. Optional — leave unset to publish to GHCR only.
        required: false
```

(Leave the `workflow_dispatch:` block at lines 25-40 untouched — manual runs already have native access to repo secrets/vars.)

Replace the "Derive tags" step (`.github/workflows/build.yml:77-106`) with:

```yaml
      - name: Derive tags
        id: tags
        env:
          VERSION: ${{ inputs.version }}
          CHANNELS: ${{ inputs.channels }}
          GHCR_IMAGE: ${{ steps.image.outputs.name }}
          DOCKERHUB_USERNAME: ${{ vars.DOCKERHUB_USERNAME }}
        run: |
          set -euo pipefail
          minor="${VERSION%.*}"          # 2.1.19 -> 2.1
          major="${VERSION%%.*}"         # 2.1.19 -> 2

          repo_name="${GITHUB_REPOSITORY#*/}"
          dockerhub_image=""
          images=("${GHCR_IMAGE}")
          if [ -n "${DOCKERHUB_USERNAME}" ]; then
            dockerhub_image="${DOCKERHUB_USERNAME}/${repo_name,,}"
            images+=("${dockerhub_image}")
          fi

          IFS=',' read -ra channel_list <<< "${CHANNELS}"

          tags=""
          for image in "${images[@]}"; do
            img_tags="${image}:${VERSION}"

            is_stable=false
            for channel in "${channel_list[@]}"; do
              channel="$(echo "${channel}" | tr -d '[:space:]')"
              [ -n "${channel}" ] || continue
              img_tags="${img_tags},${image}:${channel}"
              if [ "${channel}" = "stable" ]; then is_stable=true; fi
            done

            # Floating minor/major/latest tags only ever track the stable channel,
            # so an experimental release can never quietly become someone's :2.1.
            if [ "${is_stable}" = "true" ]; then
              img_tags="${img_tags},${image}:${minor},${image}:${major},${image}:latest"
            fi

            tags="${tags:+${tags},}${img_tags}"
          done

          {
            echo "tags=${tags}"
            echo "dockerhub-image=${dockerhub_image}"
          } >> "$GITHUB_OUTPUT"
          echo "Tagging: ${tags}"
```

- [ ] **Step 4: Add the Docker Hub login step**

Insert immediately after the existing GHCR login step (`.github/workflows/build.yml:71-75`), before "Derive tags":

```yaml
      - name: Log in to Docker Hub
        if: vars.DOCKERHUB_USERNAME != ''
        uses: docker/login-action@v3
        with:
          username: ${{ vars.DOCKERHUB_USERNAME }}
          password: ${{ secrets.DOCKERHUB_TOKEN }}
```

(No `registry:` input — `docker/login-action` defaults to `docker.io` when omitted.)

- [ ] **Step 5: Add the Docker Hub README-sync step**

Insert after "Attest build provenance" (`.github/workflows/build.yml:145-150`), before "Summary":

```yaml
      - name: Sync Docker Hub description
        if: vars.DOCKERHUB_USERNAME != ''
        uses: peter-evans/dockerhub-description@v4
        with:
          username: ${{ vars.DOCKERHUB_USERNAME }}
          password: ${{ secrets.DOCKERHUB_TOKEN }}
          repository: ${{ steps.tags.outputs.dockerhub-image }}
          readme-filepath: ./README.md
```

Do **not** modify the "Build and push" step or the "Summary" step — "Build and push" already reads `tags: ${{ steps.tags.outputs.tags }}`, so it automatically builds once and pushes to both registries once Step 3 lands; "Summary" already prints that same combined `tags` output in its table row, so Docker Hub tags show up there for free.

- [ ] **Step 6: Validate the workflow file**

```bash
docker run --rm -v "$(pwd):/repo" --workdir /repo rhysd/actionlint:latest
```

Expected: no errors. `actionlint` understands the `vars`/`secrets` contexts and runs `shellcheck` on every `run:` block automatically, so this also lints the new bash — extending the same discipline `ci.yml` already applies to `docker/entrypoint.sh` and `docker/healthcheck.sh` to this inline script.

- [ ] **Step 7: Commit**

```bash
git add .github/workflows/build.yml
git commit -m "Add Docker Hub publishing to build.yml, gated on repo config"
```

---

### Task 2: Wire the secret through `release-watch.yml`

**Files:**
- Modify: `.github/workflows/release-watch.yml:102-111` (the `build:` job that calls `build.yml`)

**Interfaces:**
- Consumes: nothing from Task 1's code directly — this task only affects secret propagation from the calling workflow into the `workflow_call` invocation. Depends on Task 1 being merged first so `DOCKERHUB_TOKEN` is a recognized secret on the callee side.
- Produces: n/a (trigger wiring only; no outputs consumed by other tasks).

**Why this is needed:** `GITHUB_TOKEN` is automatically available in every workflow, including reusable ones — that's why the existing GHCR login already works without any special wiring. Custom secrets like `DOCKERHUB_TOKEN` are **not** passed to a called reusable workflow unless the caller explicitly says so. Without this change, `build.yml` would work fine when run manually via `workflow_dispatch` (which has native secret access) but silently skip Docker Hub every time it's triggered by the release-watch schedule (`secrets.DOCKERHUB_TOKEN` would just be empty there) — the difference would be confusing to debug later, since `vars.DOCKERHUB_USERNAME` context is available either way and the login step would still be *gated on* correctly, it just wouldn't have a token to use.

- [ ] **Step 1: Add `secrets: inherit` to the build job**

In `.github/workflows/release-watch.yml`, the `build:` job currently reads:

```yaml
  build:
    needs: resolve
    if: needs.resolve.outputs.any == 'true'
    strategy:
      fail-fast: false
      matrix:
        release: ${{ fromJson(needs.resolve.outputs.builds) }}
    uses: ./.github/workflows/build.yml
    with:
      version: ${{ matrix.release.version }}
      channels: ${{ matrix.release.channels }}
      platforms: ${{ matrix.release.platforms }}
      sha256: ${{ toJson(matrix.release.sha256) }}
    permissions:
      contents: read
      packages: write
      attestations: write
      id-token: write
```

Add `secrets: inherit` right after the `with:` block:

```yaml
  build:
    needs: resolve
    if: needs.resolve.outputs.any == 'true'
    strategy:
      fail-fast: false
      matrix:
        release: ${{ fromJson(needs.resolve.outputs.builds) }}
    uses: ./.github/workflows/build.yml
    with:
      version: ${{ matrix.release.version }}
      channels: ${{ matrix.release.channels }}
      platforms: ${{ matrix.release.platforms }}
      sha256: ${{ toJson(matrix.release.sha256) }}
    secrets: inherit
    permissions:
      contents: read
      packages: write
      attestations: write
      id-token: write
```

- [ ] **Step 2: Validate the workflow file**

```bash
docker run --rm -v "$(pwd):/repo" --workdir /repo rhysd/actionlint:latest
```

Expected: no errors, and no new warnings compared to Task 1's run (confirms this one-line addition didn't introduce a syntax issue elsewhere in the file).

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/release-watch.yml
git commit -m "Pass secrets through to build.yml so Docker Hub publishing works on the release-watch schedule"
```

---

### Task 3: Document Docker Hub publishing in `README.md`

**Files:**
- Modify: `README.md:9-11` (top registry callout)
- Modify: `README.md:23-40` ("Setting it up as your own" numbered list)
- Modify: `README.md:218-232` ("How the automation works" diagram)

**Interfaces:**
- Consumes: the exact config names introduced in Task 1 (`DOCKERHUB_USERNAME` repo variable, `DOCKERHUB_TOKEN` repo secret) — must be spelled identically to what the workflow actually reads, since this is the only place a human learns those names.
- Produces: n/a (documentation only).

- [ ] **Step 1: Add the Docker Hub registry line to the top callout**

`README.md:9-11` currently:

```
```
ghcr.io/aconti90/factorio-headless
```
```

Change to:

```
```
ghcr.io/aconti90/factorio-headless
docker.io/aconti90/factorio-headless
```
```

- [ ] **Step 2: Add an optional Docker Hub setup step to "Setting it up as your own"**

`README.md:23-40` currently ends with:

```
3. Make the package public from the repo's **Packages** sidebar → package
   settings → *Change visibility*, if you want others to pull it. Public images
   on ghcr.io have no storage or bandwidth cost, and public repos get unlimited
   Actions minutes — the whole pipeline runs on the free tier.
```

Add a new step 4 immediately after it:

```
4. *(Optional)* To also publish to Docker Hub, add a repository **variable**
   named `DOCKERHUB_USERNAME` (your Docker Hub username) and a repository
   **secret** named `DOCKERHUB_TOKEN` (an access token with Read & Write
   scope, from Docker Hub's Account Settings → Security → New Access Token)
   under **Settings → Secrets and variables → Actions**. Leave both unset to
   publish to GHCR only — nothing else changes.
```

- [ ] **Step 3: Update the automation diagram**

`README.md:218-232` currently includes:

```
  build.yml ──► buildx ──► ghcr.io  (+ SBOM, provenance attestation)
```

Change to:

```
  build.yml ──► buildx ──► ghcr.io + Docker Hub*  (+ SBOM; provenance attestation on ghcr.io only)
```

Immediately after the closing ` ``` ` of that diagram code block (before the "Three design decisions worth knowing about" paragraph), add:

```
\* Docker Hub publishing is optional — set via the `DOCKERHUB_USERNAME` repo
variable and `DOCKERHUB_TOKEN` repo secret. Unset, the pipeline publishes to
ghcr.io only.
```

- [ ] **Step 4: Proofread the rendered Markdown**

```bash
git diff README.md
```

Confirm: the new lines render as intended (no broken code-fence nesting — this repo's README nests fenced blocks inside numbered list items elsewhere, so double-check indentation matches the surrounding list style), and `DOCKERHUB_USERNAME`/`DOCKERHUB_TOKEN` are spelled identically to the workflow YAML from Task 1.

- [ ] **Step 5: Commit**

```bash
git add README.md
git commit -m "Document optional Docker Hub publishing"
```

---

## Self-Review Notes

- **Spec coverage:** Configuration (repo var/secret, gating) → Task 1 Step 3-4. Image naming (derived, not hardcoded) → Task 1 Step 1-3. Tag mirroring → Task 1 Steps 1-3. README sync → Task 1 Step 5. Attestation staying GHCR-only → Task 1 Step 5 explicitly does not touch the "Attest build provenance" step. `secrets: inherit` plumbing → Task 2. Documentation → Task 3. Rollout checklist (creating the token, setting repo config, manual dispatch verification) is post-merge and deliberately not a task here — it's operator action on the live repo, not a code change; it's covered by the spec's own Rollout section.
- **Placeholder scan:** none found — every step has literal file content, exact commands, and exact expected output.
- **Type/name consistency:** `steps.tags.outputs.tags` keeps its existing name and shape throughout; the one new output, `steps.tags.outputs.dockerhub-image`, is defined in Task 1 Step 3 and consumed only in Task 1 Step 5 (same task, same file) — no cross-task name drift to check.
