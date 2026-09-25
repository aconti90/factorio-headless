# syntax=docker/dockerfile:1.7
#
# Factorio headless server — multi-arch (linux/amd64 + linux/arm64).
#
# The download stage deliberately runs on the *build* platform ($BUILDPLATFORM)
# rather than the target platform. All it does is fetch and unpack a tarball, so
# running it natively avoids paying QEMU emulation cost on cross-builds; the
# target-arch binary is simply copied into the final stage, never executed here.

# trixie-slim (glibc 2.41), not bookworm-slim (glibc 2.36): Wube's arm64
# headless binary requires glibc >= 2.38 and fails to start on bookworm with
# "version `GLIBC_2.38' not found". Confirmed by booting the built image on
# both architectures — amd64 is unaffected by the newer base.
ARG DEBIAN_TAG=trixie-slim

# ---------------------------------------------------------------------------
# Stage 1: fetch + verify + unpack the official headless tarball
# ---------------------------------------------------------------------------
FROM --platform=${BUILDPLATFORM} debian:${DEBIAN_TAG} AS downloader

ARG TARGETARCH
ARG FACTORIO_VERSION
# Optional, per-architecture. Supplied separately rather than as a single value
# because one build-arg cannot be correct for every platform in a multi-arch
# manifest — and multi-arch is the normal case, so a single arg would mean the
# usual build never gets verified at all. Wube publishes sums at
# https://factorio.com/download/sha256sums/ (amd64 only at the time of writing),
# so a missing sum degrades to an unverified download rather than a hard failure.
ARG FACTORIO_SHA256_AMD64=""
ARG FACTORIO_SHA256_ARM64=""

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl xz-utils \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /build

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN set -eux; \
    test -n "${FACTORIO_VERSION}" || { echo "FACTORIO_VERSION build-arg is required" >&2; exit 1; }; \
    case "${TARGETARCH}" in \
      amd64) distro=linux64;      expected_sha="${FACTORIO_SHA256_AMD64}" ;; \
      arm64) distro=linux-arm64;  expected_sha="${FACTORIO_SHA256_ARM64}" ;; \
      *) echo "unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    url="https://factorio.com/get-download/${FACTORIO_VERSION}/headless/${distro}"; \
    echo "==> downloading ${url}"; \
    curl -fSL --retry 5 --retry-delay 5 --retry-connrefused -o factorio.tar.xz "${url}"; \
    if [ -n "${expected_sha}" ]; then \
      echo "==> verifying sha256 for ${TARGETARCH}"; \
      echo "${expected_sha}  factorio.tar.xz" | sha256sum -c -; \
    else \
      echo "==> WARNING: no checksum supplied for ${TARGETARCH}, download is unverified"; \
    fi; \
    tar -xJf factorio.tar.xz -C /opt; \
    rm -f factorio.tar.xz; \
    # The upstream layout differs between architectures (bin/x64 on amd64,
    # a different subdirectory on arm64), so resolve it once at build time and
    # expose a stable path the entrypoint can rely on.
    bin="$(find /opt/factorio/bin -maxdepth 2 -type f -name factorio | head -n1)"; \
    test -n "${bin}" || { echo "could not locate the factorio binary in the tarball" >&2; exit 1; }; \
    echo "==> binary found at ${bin}"; \
    ln -sf "${bin}" /opt/factorio/factorio; \
    # Keep the pristine example configs, drop the writable data dirs: those are
    # created (and owned) at runtime on the mounted volume instead.
    rm -rf /opt/factorio/saves /opt/factorio/mods /opt/factorio/config

# ---------------------------------------------------------------------------
# Stage 2: runtime
# ---------------------------------------------------------------------------
FROM debian:${DEBIAN_TAG} AS runtime

ARG PUID=845
ARG PGID=845

# curl   - fetches mod portal metadata and mod zips for update-mods.sh
# jq     - safe JSON generation for server-settings.json et al, and mod
#          portal response parsing in update-mods.sh
# gosu   - clean privilege drop when the container is started as root
# tini   - PID 1 that reaps zombies and forwards SIGTERM for clean save-on-exit
# procps - provides pgrep, used by healthcheck.sh to find the server process
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      gosu \
      jq \
      procps \
      tini \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd -g "${PGID}" factorio \
 && useradd -l -u "${PUID}" -g "${PGID}" -d /factorio -s /usr/sbin/nologin factorio

COPY --from=downloader /opt/factorio /opt/factorio
COPY entrypoint.sh healthcheck.sh update-mods.sh /usr/local/bin/

RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/healthcheck.sh /usr/local/bin/update-mods.sh \
 && mkdir -p /factorio \
 && chown -R "${PUID}:${PGID}" /factorio /opt/factorio

VOLUME /factorio
WORKDIR /factorio

# 34197/udp — game traffic.  27015/tcp — RCON (only bound when a password is set)
EXPOSE 34197/udp 27015/tcp

ENV FACTORIO_DIR=/factorio \
    FACTORIO_HOME=/opt/factorio \
    PORT=34197 \
    RCON_PORT=27015 \
    SAVE_NAME=default \
    GENERATE_NEW_SAVE=true \
    UPDATE_CONFIG=true

HEALTHCHECK --interval=30s --timeout=5s --start-period=90s --retries=3 \
  CMD /usr/local/bin/healthcheck.sh

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]

# ---------------------------------------------------------------------------
# OCI labels (the build workflow overrides these via docker/metadata-action)
# ---------------------------------------------------------------------------
ARG FACTORIO_VERSION
LABEL org.opencontainers.image.title="factorio-server" \
      org.opencontainers.image.description="Multi-arch Factorio headless server (amd64 + arm64)" \
      org.opencontainers.image.version="${FACTORIO_VERSION}" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.vendor="Community" \
      io.factorio.version="${FACTORIO_VERSION}"
