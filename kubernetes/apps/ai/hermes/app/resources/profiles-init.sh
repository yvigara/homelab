#!/usr/bin/env bash
# Materialises the additional Hermes profiles declared in git. A profile is a
# directory under $HERMES_HOME/profiles; the container's boot reconciler walks
# them on start, so creating the directory is all it takes to register one.
#
# SOUL.md is managed outside this repository and is never touched here.
set -euo pipefail

: "${HERMES_HOME:=/opt/data}"

readonly CONFIG_DIR=/run/config/profiles
readonly SECRET_DIR=/run/secrets/hermes-profiles
readonly BACKUP_DIR="${HERMES_HOME}/backups/config"

# Snapshot the profile's live config before this boot overwrites it — the same record
# init.sh keeps for the root config. Whole-file install means a hand-added key is
# otherwise destroyed with no trace.
backup_config() {
  local src=$1 label=$2
  [[ -f ${src} ]] || return 0
  install -d -m 0750 -o hermes -g hermes "${BACKUP_DIR}"
  local stamp
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  install -m 0640 -o hermes -g hermes "${src}" "${BACKUP_DIR}/${label}.pre-init.${stamp}"
}

# Bound the snapshot count per profile so restarts cannot fill the volume.
prune_config_backups() {
  local keep=${1:-20} label=$2
  local -a snaps
  mapfile -t snaps < <(ls -1t "${BACKUP_DIR}/${label}.pre-init."* 2>/dev/null || true)
  local i
  for ((i = keep; i < ${#snaps[@]}; i++)); do
    rm -f -- "${snaps[i]}"
  done
}

# The ConfigMap half is public and reviewable; the Secret half carries the
# agent's Buzz identity. Staged out of view so a half-written .env is never
# readable and never what the agent starts from.
write_env() {
  local name=$1 src=$2 dest=$3
  local staged="${dest}/.env.staged"

  install -m 0600 -o hermes -g hermes /dev/null "${staged}"
  if [[ -f "${src}/profile.env" ]]; then
    cat "${src}/profile.env" >>"${staged}"
  fi
  if [[ -f "${SECRET_DIR}/${name}.env" ]]; then
    printf '\n' >>"${staged}"
    cat "${SECRET_DIR}/${name}.env" >>"${staged}"
  fi
  mv -f "${staged}" "${dest}/.env"
}

sync_profile() {
  local name=$1 src=$2
  local dest="${HERMES_HOME}/profiles/${name}"

  install -d -m 0755 -o hermes -g hermes \
    "${HERMES_HOME}/profiles" "${dest}" "${dest}/workspace"
  backup_config "${dest}/config.yaml" "${name}"
  install -m 0644 -o hermes -g hermes "${src}/config.yaml" "${dest}/config.yaml"
  prune_config_backups 20 "${name}"
  write_env "${name}" "${src}" "${dest}"

  echo "profile ${name}: synced -> ${dest}"
}

main() {
  [[ -d ${CONFIG_DIR} ]] || return 0
  local src name
  for src in "${CONFIG_DIR}"/*/; do
    [[ -d ${src} ]] || continue
    name=$(basename "${src}")
    sync_profile "${name}" "${src%/}"
  done
}

main "$@"
