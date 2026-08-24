#!/usr/bin/env bash
# Prepares the data volume before the agent starts: the agent's config, the mise
# toolchain it shells out to, the git identity it commits with, and its own .env.
#
# Runs as root in the init container, out of the same ConfigMap as the files it
# installs. Everything here is authoritative on every pod start - what is in git
# wins over what is on the volume.
set -euo pipefail

cp /run/config/config.yaml /opt/data/config.yaml
chown hermes:hermes /opt/data/config.yaml

echo 'export PATH="/opt/data/.local/bin:/opt/data/.local/share/mise/shims:$PATH"' > /opt/data/.profile

mkdir -p /opt/data/.config/mise /opt/data/.local/bin \
  /opt/data/.local/share/mise /opt/data/.local/state/mise /opt/data/.cache/mise
cp /run/config/mise.toml /opt/data/.config/mise/config.toml

# no-ops when $MISE_INSTALL_PATH is already at $MISE_VERSION
curl -fsSL https://mise.run | sh

# real activation for interactive `kubectl exec` shells
touch /opt/data/.bashrc
grep -qF '/opt/data/.local/bin/mise activate bash' /opt/data/.bashrc \
  || echo 'eval "$(/opt/data/.local/bin/mise activate bash)"' >> /opt/data/.bashrc

mkdir -p /opt/data/.cache/mise
chown -R hermes:hermes /opt/data/.bashrc /opt/data/.config \
  /opt/data/.local/bin/mise /opt/data/.local/share/mise \
  /opt/data/.local/state/mise /opt/data/.cache \
  /opt/data/.profile
su - hermes -c "$MISE_INSTALL_PATH install"

# git config + GitHub App credential helper, from hermes-github-app
bash /run/config/git-init.sh

# The agent's own .env, rendered whole by the hermes-profile-default
# ExternalSecret. It holds the settings that belong to this one agent rather
# than to the container - see README.md.
default_env=/run/secrets/hermes-profile-default/default.env
if [[ -f ${default_env} ]]; then
  install -m 0600 -o hermes -g hermes "${default_env}" /opt/data/.env
fi

# Any additional agents declared in resources/profiles/
bash /run/config/profiles-init.sh
