#!/bin/sh
# shellcheck shell=sh
# Prepares the volume before the image's own entrypoint starts the server: the
# deploy key it clones and syncs with, the git identity it commits under, the
# knowledge base itself, and the project-local config layer.
#
# POSIX sh, not bash: the image is alpine and carries only BusyBox.
#
# Everything here is authoritative on every pod start - what is in git wins over
# what is on the volume.
set -eu

: "${OK_HOME:=/opt/data}"
: "${HOME:=/home/ok}"

# ---------------------------------------------------------------------------
# SSH - the deploy key for the remote
# ---------------------------------------------------------------------------
# This has to live under $HOME rather than in the environment. The server
# replaces (not merges) the environment of every git it spawns and preserves
# only a fixed allowlist; GIT_SSH_COMMAND is not on it, so a git-over-SSH
# setting passed that way would be silently dropped mid-sync. HOME *is* on the
# allowlist, which is exactly how ssh is expected to find its own config.
#
# $HOME is an emptyDir, deliberately outside $OK_HOME: full sync commits
# everything the knowledge base is not ignoring, and a private key under the
# project would be pushed to the remote.
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
# 2023. node rather than curl: the alpine image ships neither curl nor a
# TLS-capable wget, but node is the one thing it is guaranteed to have.
if node -e '
fetch("https://api.github.com/meta")
  .then((r) => { if (!r.ok) throw new Error(`HTTP ${r.status}`); return r.json(); })
  .then((m) => { for (const k of m.ssh_keys) console.log(`github.com ${k}`); })
  .catch((e) => { console.error(String(e)); process.exit(1); });
' > "${known_hosts}.new" 2>/dev/null && [ -s "${known_hosts}.new" ]; then
  mv "${known_hosts}.new" "${known_hosts}"
  echo "[install] refreshed github.com host keys from api.github.com/meta"
else
  # Keep a file from a previous boot rather than fall back to an unverified
  # connection. $HOME is an emptyDir, so in practice there never is one - the
  # branch is here so a transient GitHub outage fails loudly, not silently.
  rm -f "${known_hosts}.new"
fi
if [ ! -s "${known_hosts}" ]; then
  echo "[install] no github.com host keys available (fetch failed, none cached)" >&2
  exit 1
fi
chmod 0644 "${known_hosts}"

# IdentitiesOnly stops ssh from offering any other key it finds first and
# tripping GitHub's auth-attempt limit. StrictHostKeyChecking is left at its
# default `yes` against the file above - never disabled.
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
# identity or on a tree it considers foreign (the volume is owned by fsGroup).
git config --global user.name "${GIT_AUTHOR_NAME}"
git config --global user.email "${GIT_AUTHOR_EMAIL}"
git config --global --replace-all safe.directory "${OK_HOME}"
git config --global init.defaultBranch "${OK_GIT_BRANCH}"

# ---------------------------------------------------------------------------
# The knowledge base
# ---------------------------------------------------------------------------
cd "${OK_HOME}"
if [ ! -d "${OK_HOME}/.git" ]; then
  echo "[install] cloning ${OK_GIT_REMOTE} into ${OK_HOME}"
  # No --branch: the remote's default branch is the one we want, and asking for
  # a named branch fails outright on a repo with no commits yet. An empty repo
  # clones to an empty tree on an unborn branch (named by init.defaultBranch
  # above), which `ok init` then fills with the first commit.
  #
  # Cloning into the mounted directory rather than a fresh one, since the
  # volume is already there: git accepts a target that exists and is empty.
  git clone "${OK_GIT_REMOTE}" "${OK_HOME}"
else
  echo "[install] ${OK_HOME} already cloned"
fi

# The image's entrypoint runs this same command when it finds no .ok, but the
# project-local config below lives *inside* .ok - creating it first would make
# that guard skip the init it is guarding. So initialize here and let the
# entrypoint no-op.
if [ ! -d .ok ]; then
  echo "[install] ${OK_HOME} is not initialized, running ok init"
  ok init --no-mcp --no-skills < /dev/null
else
  echo "[install] ${OK_HOME} already initialized"
fi

# The project-local config layer, rendered in git and authoritative on every
# start - the same contract as the agent .env next door in hermes. It holds the
# settings that belong to this instance rather than to the container, which is
# why they are not OK_* variables: the env layer sits above every config file,
# so a value set there could not be adjusted anywhere else. See README.md.
echo "[install] installing .ok/local/config.yml"
mkdir -p .ok/local
install -m 0644 /run/config/local-config.yml .ok/local/config.yml
