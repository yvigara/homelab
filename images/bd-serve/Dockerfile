# bd-serve sidecar image for kubernetes/apps/ai/beads-mcp.
#
# The upstream ghcr.io/nickytonline/beads-mcp image ships bd but not git, and
# `bd serve` needs a git repository root, so it exits immediately. This image is
# the same bd plus git, and is used for the bd-serve container only.
#
# BEADS_VERSION must equal the bd bundled in the upstream beads-mcp image
# (BEADS_VERSION in its Dockerfile at the tag pinned in the HelmRelease): bd
# refuses a database that a newer schema has migrated. Bump both together.
FROM debian:bookworm-slim@sha256:e67eeead736ff7bbe258ef088bff683635c561b1fcfefad0806c1df4ab49ce0e AS bd
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

FROM debian:bookworm-slim@sha256:e67eeead736ff7bbe258ef088bff683635c561b1fcfefad0806c1df4ab49ce0e
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
