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
  install -m 0644 -o hermes -g hermes "${src}/config.yaml" "${dest}/config.yaml"
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
