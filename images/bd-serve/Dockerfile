# bd serve image for kubernetes/apps/ai/beads: bd plus git. `bd serve` needs a git
# repository root, and the upstream beads-mcp image (bd without git) is no longer used.
#
# bd refuses a database that a newer schema has migrated, so any other bd client
# (Mac CLI, etc.) must be on this version or newer. Bump them together.
FROM debian:bookworm-slim@sha256:734a72b3d6142a71993b4bc580ca01d8ca687f77a2c422d96a961d3376b179bc AS bd
# renovate: datasource=github-releases depName=gastownhall/beads extractVersion=^v(?<version>.+)$
ARG BEADS_VERSION=1.3.4
ARG TARGETARCH
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /tmp/bd
RUN set -eu; \
    name="beads_${BEADS_VERSION}_linux_${TARGETARCH}.tar.gz"; \
    base="https://github.com/gastownhall/beads/releases/download/v${BEADS_VERSION}"; \
    curl -fsSL -o "$name" "$base/$name"; \
    curl -fsSL -o checksums.txt "$base/checksums.txt"; \
    grep " ${name}\$" checksums.txt | sha256sum -c -; \
    tar -xzf "$name" bd

FROM debian:bookworm-slim@sha256:734a72b3d6142a71993b4bc580ca01d8ca687f77a2c422d96a961d3376b179bc
RUN apt-get update \
 && apt-get install -y --no-install-recommends git ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd --gid 1000 bd \
 && useradd --uid 1000 --gid 1000 --create-home --shell /bin/sh bd \
 && mkdir -p /data/project \
 && chown -R bd:bd /data
COPY --from=bd /tmp/bd/bd /usr/local/bin/bd
USER 1000:1000
WORKDIR /data/project
LABEL org.opencontainers.image.source="https://github.com/yvigara/homelab"
