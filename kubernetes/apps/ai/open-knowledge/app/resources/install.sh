#!/usr/bin/env bash
# Init container: put the `ok` CLI on the volume, wire up SSH for the remote,
# make sure the knowledge base is cloned and initialized, and pin full sync.
#
# Upstream ships no registry image (the docs tell you to build one from `node`
# + `npm i -g @inkeep/open-knowledge`), so the install happens here instead of
# in a Dockerfile and lands on the PVC, where the app container picks it up on
# $PATH.
set -euo pipefail

mkdir -p "${OK_PROJECT_DIR}" "${NPM_CONFIG_PREFIX}"

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# SSH — the deploy key for the remote
# ---------------------------------------------------------------------------
# This has to live under $HOME rather than in the environment. The server
# replaces (not merges) the environment of every git it spawns and preserves
# only a fixed allowlist; GIT_SSH_COMMAND is not on it, so a git-over-SSH
# setting passed that way would be silently dropped mid-sync. HOME *is* on the
# allowlist, which is exactly how ssh is expected to find its own config.
#
# Rewritten every boot so a rotated key propagates on restart.
ssh_dir="${HOME}/.ssh"
key_file="${ssh_dir}/id_ed25519"
known_hosts="${ssh_dir}/known_hosts"

install -d -m 0700 "${ssh_dir}"
printf '%s\n' "${SSH_DEPLOY_KEY}" > "${key_file}"
chmod 0600 "${key_file}"
printf '%s\n' "${SSH_DEPLOY_KEY_PUB}" > "${key_file}.pub"
chmod 0644 "${key_file}.pub"

# Host keys come from GitHub's published set over TLS, so the trust root is
# GitHub's certificate rather than whatever answered on port 22 the first time
# (plain TOFU). It also self-heals when GitHub rotates a key, as they did in
# 2023. If the fetch fails, keep the file from a previous boot instead of
# falling back to an unverified connection.
if meta=$(curl -fsS --max-time 20 https://api.github.com/meta 2>/dev/null); then
  # node, not python3 — this is the node image, so the parser is guaranteed.
  printf '%s' "${meta}" \
    | node -e 'const m=JSON.parse(require("node:fs").readFileSync(0,"utf8")); for (const k of m.ssh_keys) console.log(`github.com ${k}`);' \
    > "${known_hosts}.new"
  if [[ -s "${known_hosts}.new" ]]; then
    mv "${known_hosts}.new" "${known_hosts}"
    echo "[install] refreshed github.com host keys from api.github.com/meta"
  else
    rm -f "${known_hosts}.new"
  fi
fi
if [[ ! -s "${known_hosts}" ]]; then
  echo "[install] no github.com host keys available (fetch failed, none cached)" >&2
  exit 1
fi
chmod 0644 "${known_hosts}"

# IdentitiesOnly stops ssh from offering any other key it finds first and
# tripping GitHub's auth-attempt limit. StrictHostKeyChecking is left at its
# default `yes` against the file above — never disabled.
cat > "${ssh_dir}/config" <<EOF
Host github.com
  HostName github.com
  User git
  IdentityFile ${key_file}
  IdentitiesOnly yes
  UserKnownHostsFile ${known_hosts}
  StrictHostKeyChecking yes
EOF
chmod 0600 "${ssh_dir}/config"

# ---------------------------------------------------------------------------
# Git identity
# ---------------------------------------------------------------------------
# Timeline and recovery are plain git, and git refuses to operate without an
# identity or on a tree it considers foreign (the PVC is owned by fsGroup).
git config --global user.name "${GIT_AUTHOR_NAME}"
git config --global user.email "${GIT_AUTHOR_EMAIL}"
git config --global --replace-all safe.directory "${OK_PROJECT_DIR}"
git config --global init.defaultBranch "${OK_GIT_BRANCH}"

# ---------------------------------------------------------------------------
# The knowledge base
# ---------------------------------------------------------------------------
if [[ ! -d "${OK_PROJECT_DIR}/.git" ]]; then
  echo "[install] cloning ${OK_GIT_REMOTE} into ${OK_PROJECT_DIR}"
  # No --branch: the remote's default branch is the one we want, and asking for
  # a named branch fails outright on a repo with no commits yet. An empty repo
  # clones to an empty tree on an unborn branch (named by init.defaultBranch
  # above), which `ok init` then fills with the first commit.
  git clone "${OK_GIT_REMOTE}" "${OK_PROJECT_DIR}"
else
  echo "[install] ${OK_PROJECT_DIR} already cloned"
fi

cd "${OK_PROJECT_DIR}"
if [[ ! -d .ok ]]; then
  # `--no-mcp --no-skills` skips wiring up local agent harnesses and skill files
  # that do not exist in a container; the server still serves its own /mcp
  # endpoint. stdin is closed so init takes its non-TTY defaults instead of
  # hanging on a prompt.
  echo "[install] ${OK_PROJECT_DIR} is not initialized, running ok init"
  ok init --no-mcp --no-skills < /dev/null
else
  echo "[install] ${OK_PROJECT_DIR} already initialized"
fi

# The project-local config layer, rendered in git and authoritative on every
# start — the same contract as the agent .env next door in hermes. It holds the
# settings that belong to this instance rather than to the container, which is
# why they are not OK_* variables: the env layer sits above every config file,
# so a value set there could not be adjusted anywhere else. See README.md.
echo "[install] installing .ok/local/config.yml"
mkdir -p .ok/local
install -m 0644 /run/config/local-config.yml .ok/local/config.yml
