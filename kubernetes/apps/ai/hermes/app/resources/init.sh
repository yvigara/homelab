#!/usr/bin/env bash
# Prepares the data volume before the agent starts. Authoritative on every pod
# start: what is in git wins over what is on the volume.
set -euo pipefail

readonly CONFIG_DIR=/run/config
readonly SECRET_DIR=/run/secrets/hermes-profiles
readonly DATA_DIR=/opt/data
# Where the pre-overwrite copies go. On the persistent volume, so a snapshot survives
# the restart that produced it and the previous state stays recoverable afterwards.
readonly BACKUP_DIR="${DATA_DIR}/backups/config"

# Snapshot whatever is currently on the volume before this boot overwrites it.
# Rationale: install_config/profiles-init.sh are whole-file installs, so any key an
# agent added by hand (or any hand-edit at all) is destroyed with no record. Keeping
# the pre-boot copy is what makes "this reverted, here is what it was" answerable.
backup_config() {
  local src=$1 label=$2
  [[ -f ${src} ]] || return 0
  install -d -m 0750 -o hermes -g hermes "${BACKUP_DIR}"
  local stamp
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  install -m 0640 -o hermes -g hermes "${src}" "${BACKUP_DIR}/${label}.pre-init.${stamp}"
}

# Prune so an unbounded number of restarts cannot fill the volume.
# Keeps the newest N pre-init snapshots per label, newest first.
prune_config_backups() {
  local keep=${1:-20} label=$2
  local -a snaps
  mapfile -t snaps < <(ls -1t "${BACKUP_DIR}/${label}.pre-init."* 2>/dev/null || true)
  local i
  for ((i = keep; i < ${#snaps[@]}; i++)); do
    rm -f -- "${snaps[i]}"
  done
}

install_config() {
  backup_config "${DATA_DIR}/config.yaml" default
  install -m 0644 -o hermes -g hermes "${CONFIG_DIR}/config.yaml" "${DATA_DIR}/config.yaml"
  prune_config_backups 20 default
}

install_mise() {
  mkdir -p "${DATA_DIR}"/.config/mise "${DATA_DIR}"/.local/{bin,share/mise,state/mise} \
    "${DATA_DIR}"/.cache/mise
  cp "${CONFIG_DIR}/mise.toml" "${DATA_DIR}/.config/mise/config.toml"

  # no-ops when $MISE_INSTALL_PATH is already at $MISE_VERSION
  curl -fsSL https://mise.run | sh

  printf 'export PATH="%s/.local/bin:$PATH"\n' \
    "${DATA_DIR}" "${DATA_DIR}" >"${DATA_DIR}/.profile"

  # real activation for interactive `kubectl exec` shells
  touch "${DATA_DIR}/.bashrc"
  grep -qF "${DATA_DIR}/.local/bin/mise activate bash" "${DATA_DIR}/.bashrc" ||
    echo "eval \"\$(${DATA_DIR}/.local/bin/mise activate bash)\"" >>"${DATA_DIR}/.bashrc"

  chown -R hermes:hermes "${DATA_DIR}"/.bashrc "${DATA_DIR}"/.config \
    "${DATA_DIR}"/.local/bin/mise "${DATA_DIR}"/.local/share/mise \
    "${DATA_DIR}"/.local/state/mise "${DATA_DIR}"/.cache "${DATA_DIR}"/.profile
  su - hermes -c "$MISE_INSTALL_PATH install"
}

install_default_env() {
  local src="${SECRET_DIR}/default.env"
  [[ -f ${src} ]] || return 0
  install -m 0600 -o hermes -g hermes "${src}" "${DATA_DIR}/.env"
}

main() {
  install_config
  install_mise
  bash "${CONFIG_DIR}/git-init.sh"
  install_default_env
  bash "${CONFIG_DIR}/profiles-init.sh"
}

main "$@"
