#!/usr/bin/env bash
# Prepares the data volume before the agent starts. Authoritative on every pod
# start: what is in git wins over what is on the volume.
set -euo pipefail

readonly CONFIG_DIR=/run/config
readonly SECRET_DIR=/run/secrets/hermes-profiles
readonly DATA_DIR=/opt/data

install_config() {
  install -m 0644 -o hermes -g hermes "${CONFIG_DIR}/config.yaml" "${DATA_DIR}/config.yaml"
}

install_mise() {
  mkdir -p "${DATA_DIR}"/.config/mise "${DATA_DIR}"/.local/{bin,share/mise,state/mise} \
    "${DATA_DIR}"/.cache/mise
  cp "${CONFIG_DIR}/mise.toml" "${DATA_DIR}/.config/mise/config.toml"

  # no-ops when $MISE_INSTALL_PATH is already at $MISE_VERSION
  curl -fsSL https://mise.run | sh

  printf 'export PATH="%s/.local/bin:%s/.local/share/mise/shims:$PATH"\n' \
    "${DATA_DIR}" "${DATA_DIR}" >"${DATA_DIR}/.profile"

  # real activation for interactive `kubectl exec` shells
  touch "${DATA_DIR}/.bashrc"
  grep -qF "${DATA_DIR}/.local/bin/mise activate bash" "${DATA_DIR}/.bashrc" \
    || echo "eval \"\$(${DATA_DIR}/.local/bin/mise activate bash)\"" >>"${DATA_DIR}/.bashrc"

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
