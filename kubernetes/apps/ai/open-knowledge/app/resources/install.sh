#!/usr/bin/env bash
# Init container: put the `ok` CLI on the volume and make sure the project on it
# is initialized. Upstream ships no registry image (the docs tell you to build
# one from `node` + `npm i -g @inkeep/open-knowledge`), so the install happens
# here instead of in a Dockerfile and lands on the PVC, where the app container
# picks it up on $PATH.
set -euo pipefail

mkdir -p "${OK_PROJECT_DIR}" "${NPM_CONFIG_PREFIX}"

# npm reinstalls unconditionally, so gate on a version stamp: a restart with an
# unchanged OK_VERSION skips the download entirely and boots straight through.
stamp="${HOME}/.ok-installed-version"
if [[ "$(cat "${stamp}" 2>/dev/null || true)" != "${OK_VERSION}" ]]; then
  echo "[install] installing @inkeep/open-knowledge@${OK_VERSION}"
  npm install -g --no-fund --no-audit "@inkeep/open-knowledge@${OK_VERSION}"
  echo "${OK_VERSION}" > "${stamp}"
else
  echo "[install] @inkeep/open-knowledge@${OK_VERSION} already present"
fi

# Timeline and recovery are plain git, and git refuses to operate without an
# identity or on a tree it considers foreign (the PVC is owned by fsGroup).
git config --global user.name "${GIT_AUTHOR_NAME}"
git config --global user.email "${GIT_AUTHOR_EMAIL}"
git config --global --replace-all safe.directory "${OK_PROJECT_DIR}"
git config --global init.defaultBranch main

cd "${OK_PROJECT_DIR}"
if [[ ! -d .ok ]]; then
  # First boot on an empty volume. `--no-mcp --no-skills` skips wiring up local
  # agent harnesses and skill files that do not exist in a container; the server
  # still serves its own /mcp endpoint. stdin is closed so init takes its
  # non-TTY defaults instead of hanging on a prompt.
  echo "[install] ${OK_PROJECT_DIR} is not initialized, running ok init"
  ok init --no-mcp --no-skills < /dev/null
else
  echo "[install] ${OK_PROJECT_DIR} already initialized"
fi
