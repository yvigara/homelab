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
# Plugins installed into every Hermes home: "<name>" -> "<owner/repo>". Unpinned:
# installed once at the repo's default branch, then updated by hand with
# `hermes plugins update <name>`. Enabling is config.yaml's job
# (plugins.enabled), so installs never touch the config.
declare -rA PLUGINS=(
  # Claude Pro/Max subscription through the claude CLI (mise.toml).
  [claude-subscription-directsdk-experimental]="NousResearch/hermes-plugin-claude-subscription-directsdk"
  # memory.provider: memini.
  [memini]="eleboucher/memini-hermes"
)
# The init container does not get the app container's PATH.
readonly HERMES_PATH=/opt/hermes/bin:/opt/hermes/.venv/bin:/usr/local/bin:/usr/bin:/bin

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

# Plugins are discovered per $HERMES_HOME and each profile is its own home, so
# every plugin goes into the default home and each profile. Skipped when already
# installed; a failed install warns rather than blocking boot.
install_plugins() {
  local home profile_arg name
  for home in "${DATA_DIR}" "${DATA_DIR}"/profiles/*/; do
    home=${home%/}
    profile_arg=""
    [[ ${home} == "${DATA_DIR}" ]] || profile_arg="-p $(basename "${home}")"
    for name in "${!PLUGINS[@]}"; do
      [[ -d ${home}/plugins/${name} ]] && continue
      su - hermes -c "HOME=${DATA_DIR} HERMES_HOME=${DATA_DIR} PATH=${HERMES_PATH} \
        hermes ${profile_arg} plugins install ${PLUGINS[${name}]} --no-enable" ||
        echo "warning: plugin ${name} not installed in ${home}" >&2
    done
  done
}

main() {
  install_config
  install_mise
  bash "${CONFIG_DIR}/git-init.sh"
  install_default_env
  # Cron scripts: <HERMES_HOME>/scripts/ IS the hermes-scripts checkout, so this
  # only fast-forwards it. Never fatal — a boot that cannot reach GitHub must
  # still boot (see t_0b6e5e7a).
  bash "${CONFIG_DIR}/sync-cron-scripts.sh" ||
    echo "[init] WARNING: sync-cron-scripts.sh failed — using the checkout as-is" >&2
  bash "${CONFIG_DIR}/profiles-init.sh"
  install_plugins
}

main "$@"
