# Community Readiness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the repo the minimum community infrastructure it's missing — a contributor landing page, structured issue/PR templates, and the GitHub discoverability config (topics, homepage, Discussions, badges) that makes it findable at all.

**Architecture:** Entirely new documentation/template files plus GitHub repo settings changes — no code, CI, or Dockerfile changes. `CONTRIBUTING.md` becomes the single source of truth for contribution instructions; the README's existing `## Contributing` section is trimmed to a pointer at it. Issue templates use GitHub's YAML Issue Forms format rather than classic Markdown templates.

**Tech Stack:** Markdown, GitHub Issue Forms (YAML), `gh` CLI for repo settings.

## Global Constraints

- No changes to CI, the Dockerfile, or entrypoint/healthcheck scripts (spec Non-goals).
- No `SECURITY.md`, no standalone `CODE_OF_CONDUCT.md` (spec Non-goals) — conduct is a one-line note inside `CONTRIBUTING.md`.
- No issue template for upstream Factorio release problems (spec Non-goals) — only bug-report and feature-request.
- Repo name for all `gh` commands and URLs: `aconti90/factorio-headless`.
- Tasks 5 and 6 change live, public-facing GitHub repo settings (topics, homepage URL, Discussions). Per this project's operating rules, these are the kind of action that gets confirmed with the user before running, not applied silently — present the exact `gh` commands and wait for a go-ahead before executing them.

---

### Task 1: `CONTRIBUTING.md` + trim README's Contributing section

**Files:**
- Create: `CONTRIBUTING.md`
- Modify: `README.md:291-295` (the existing `## Contributing` section)

**Interfaces:**
- Consumes: none.
- Produces: `CONTRIBUTING.md` — referenced by README.md's trimmed Contributing section (this task), and by the issue/PR templates added in Tasks 2–3 (contributors land here from those templates too).

- [ ] **Step 1: Write `CONTRIBUTING.md`**

Create `CONTRIBUTING.md` at the repo root with this exact content:

```markdown
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
```

- [ ] **Step 2: Trim the README's Contributing section**

In `README.md`, replace lines 291-295:

```markdown
## Contributing

`ci.yml` runs shellcheck, hadolint, compose validation, and a real smoke test
that boots the server, waits for the healthcheck to go green, and verifies a
clean SIGTERM shutdown. Run the linters locally with `scripts/lint.sh`.
```

with:

```markdown
## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).
```

- [ ] **Step 3: Verify**

Run: `grep -c "^## Contributing" README.md` — expect `1` (heading still
present, just once). Read both files back and confirm `CONTRIBUTING.md`'s
"What CI checks" paragraph and the README's old content aren't duplicated
anywhere else in the README.

- [ ] **Step 4: Commit**

```bash
git add CONTRIBUTING.md README.md
git commit -m "$(cat <<'EOF'
Add CONTRIBUTING.md, trim README's Contributing section to point at it

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Issue templates

**Files:**
- Create: `.github/ISSUE_TEMPLATE/bug-report.yml`
- Create: `.github/ISSUE_TEMPLATE/feature-request.yml`
- Create: `.github/ISSUE_TEMPLATE/config.yml`

**Interfaces:**
- Consumes: none.
- Produces: `config.yml`'s contact link points at
  `https://github.com/aconti90/factorio-headless/discussions`, which Task 6
  enables. The link is valid either way (GitHub shows a normal 404-safe
  page if Discussions isn't enabled yet), so there's no ordering dependency
  — this task can run before or after Task 6.

- [ ] **Step 1: Write `bug-report.yml`**

Create `.github/ISSUE_TEMPLATE/bug-report.yml`:

```yaml
name: Bug report
description: Something isn't working as expected
labels: ["bug"]
body:
  - type: dropdown
    id: channel
    attributes:
      label: Channel
      options:
        - stable
        - experimental
    validations:
      required: true
  - type: dropdown
    id: architecture
    attributes:
      label: Architecture
      options:
        - amd64
        - arm64
    validations:
      required: true
  - type: input
    id: image-tag
    attributes:
      label: Image tag
      description: The exact tag you're running, e.g. `2.0.77` or `stable`
      placeholder: "2.0.77"
    validations:
      required: true
  - type: textarea
    id: expected
    attributes:
      label: Expected behavior
    validations:
      required: true
  - type: textarea
    id: actual
    attributes:
      label: Actual behavior
    validations:
      required: true
  - type: textarea
    id: logs
    attributes:
      label: Logs
      description: Output of `docker logs <container>`, if relevant
      render: shell
    validations:
      required: false
```

- [ ] **Step 2: Write `feature-request.yml`**

Create `.github/ISSUE_TEMPLATE/feature-request.yml`:

```yaml
name: Feature or config request
description: Request a new environment variable, config option, or behavior change
labels: ["enhancement"]
body:
  - type: textarea
    id: what
    attributes:
      label: What's missing
      description: What config/behavior would you like to see?
    validations:
      required: true
  - type: textarea
    id: why
    attributes:
      label: Why
      description: What are you trying to do that this would help with?
    validations:
      required: true
  - type: textarea
    id: workaround
    attributes:
      label: Current workaround
      description: How are you working around this today, if at all?
    validations:
      required: false
```

- [ ] **Step 3: Write `config.yml`**

Create `.github/ISSUE_TEMPLATE/config.yml`:

```yaml
blank_issues_enabled: false
contact_links:
  - name: Questions and discussion
    url: https://github.com/aconti90/factorio-headless/discussions
    about: >-
      Ask "how do I configure X" or "has anyone run this on Y" questions
      here instead of opening an issue.
```

- [ ] **Step 4: Verify the YAML is well-formed**

Run: `python3 -c "import yaml,sys; [yaml.safe_load(open(f)) for f in sys.argv[1:]]" .github/ISSUE_TEMPLATE/bug-report.yml .github/ISSUE_TEMPLATE/feature-request.yml .github/ISSUE_TEMPLATE/config.yml`
Expected: no output, exit code 0. If `python3`/`yaml` isn't available,
`ruby -ryaml -e "ARGV.each { |f| YAML.load_file(f) }" .github/ISSUE_TEMPLATE/*.yml` works the same way.

- [ ] **Step 5: Commit**

```bash
git add .github/ISSUE_TEMPLATE
git commit -m "$(cat <<'EOF'
Add structured issue templates for bug reports and feature requests

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: PR template

**Files:**
- Create: `.github/PULL_REQUEST_TEMPLATE.md`

**Interfaces:**
- Consumes: none.
- Produces: nothing consumed elsewhere.

- [ ] **Step 1: Write the PR template**

Create `.github/PULL_REQUEST_TEMPLATE.md`:

```markdown
## What changed and why

## Checklist

- [ ] `scripts/lint.sh` passes locally
- [ ] Linked issue (if any):
```

- [ ] **Step 2: Verify**

Open a draft PR (or use `gh pr create --draft` against a throwaway branch)
and confirm the template body pre-fills the PR description. Close/delete
the throwaway PR and branch afterward if you created one — this is a
manual visual check, not something worth scripting.

- [ ] **Step 3: Commit**

```bash
git add .github/PULL_REQUEST_TEMPLATE.md
git commit -m "$(cat <<'EOF'
Add pull request template

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: README badges

**Files:**
- Modify: `README.md:6-7`

**Interfaces:**
- Consumes: none (badges are self-contained shields.io URLs; they render
  even before the Docker Hub repo has pull data, just starting at 0).
- Produces: nothing consumed elsewhere.

- [ ] **Step 1: Add the three new badges**

In `README.md`, after line 7 (the existing `[![Release watch](...)]`
badge line) and before the blank line that follows it, insert:

```markdown
[![Docker pulls](https://img.shields.io/docker/pulls/aconti90/factorio-headless)](https://hub.docker.com/r/aconti90/factorio-headless)
[![Image size](https://img.shields.io/docker/image-size/aconti90/factorio-headless/stable)](https://hub.docker.com/r/aconti90/factorio-headless)
[![License](https://img.shields.io/github/license/aconti90/factorio-headless)](LICENSE)
```

So lines 6-7 of `README.md` become five consecutive badge lines (CI,
Release watch, Docker pulls, Image size, License), still followed by the
existing blank line before the `ghcr.io/...` code block.

- [ ] **Step 2: Verify the badge URLs resolve**

Run:
```bash
for url in \
  "https://img.shields.io/docker/pulls/aconti90/factorio-headless" \
  "https://img.shields.io/docker/image-size/aconti90/factorio-headless/stable" \
  "https://img.shields.io/github/license/aconti90/factorio-headless"; do
  echo "$url -> $(curl -s -o /dev/null -w '%{http_code}' "$url")"
done
```
Expected: `200` for each. If the image-size badge 404s, it means the
`stable` tag doesn't exist on Docker Hub yet (e.g. release-watch hasn't run
since Docker Hub publishing was merged) — check
`https://hub.docker.com/r/aconti90/factorio-headless/tags` and use
whatever tag does exist, or proceed anyway since it will resolve once a
build publishes.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "$(cat <<'EOF'
Add Docker pulls, image size, and license badges to README

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: GitHub repo topics + homepage URL

**Files:** none — this is a live GitHub repo settings change via `gh`, not
a committed file.

**Interfaces:**
- Consumes: none.
- Produces: nothing consumed elsewhere in this plan.

**Before running the step below: show the user the exact command and wait
for confirmation, per the Global Constraints note on live/public repo
settings changes.**

- [ ] **Step 1: Set topics and homepage**

```bash
gh repo edit aconti90/factorio-headless \
  --add-topic "docker,factorio,factorio-server,game-server,headless-server,arm64,raspberry-pi,self-hosted,docker-image,multi-arch" \
  --homepage "https://hub.docker.com/r/aconti90/factorio-headless"
```

- [ ] **Step 2: Verify**

```bash
gh repo view aconti90/factorio-headless --json repositoryTopics,homepageUrl
```

Expected: `repositoryTopics` lists all ten topics from Step 1;
`homepageUrl` is `https://hub.docker.com/r/aconti90/factorio-headless`.

No commit — nothing changed in the working tree.

---

### Task 6: Enable Discussions + trim categories

**Files:** none — live GitHub repo settings change.

**Interfaces:**
- Consumes: none.
- Produces: satisfies the Discussions link added in Task 2's `config.yml`.

**Before running the step below: show the user the exact command and wait
for confirmation, per the Global Constraints note on live/public repo
settings changes.**

- [ ] **Step 1: Enable Discussions**

```bash
gh repo edit aconti90/factorio-headless --enable-discussions
```

- [ ] **Step 2: Verify Discussions is enabled**

```bash
gh repo view aconti90/factorio-headless --json hasDiscussionsEnabled
```

Expected: `hasDiscussionsEnabled` is `true`.

- [ ] **Step 3: Trim the default discussion categories (manual, web UI)**

The GitHub CLI and REST API don't expose discussion-category management —
this step is a manual one. Go to
`https://github.com/aconti90/factorio-headless/discussions`, open the
"Categories" gear/edit control, and delete the default `Polls`,
`Announcements`, and `General` categories, leaving `Q&A`, `Ideas`, and
`Show and tell`. Tell the user this step is manual before starting it —
don't attempt to script around it.

No commit — nothing changed in the working tree.

---

## Self-Review Notes

- **Spec coverage:** `CONTRIBUTING.md` (Task 1), issue templates (Task 2),
  PR template (Task 3), README badges (Task 4), topics/homepage (Task 5),
  Discussions (Task 6) — every item in the spec's "Community health files"
  and "GitHub discoverability" sections maps to a task. `SECURITY.md`,
  `CODE_OF_CONDUCT.md`, and the release-problem issue template are
  deliberately absent per the spec's Non-goals.
- **Placeholder scan:** no TBD/TODO; every step has literal file content,
  not a description of content.
- **Type/name consistency:** `CONTRIBUTING.md` is referenced identically
  (filename and path) across Tasks 1 and 2; the Discussions URL in Task 2's
  `config.yml` matches the repo used in Task 6's `gh` commands.
