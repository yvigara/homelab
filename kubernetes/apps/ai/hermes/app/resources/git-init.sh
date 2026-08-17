#!/usr/bin/env bash
# Renders the agent's git configuration from the GitHub App credentials exposed
# by the hermes-github-app ExternalSecret (GH_APP_* environment variables).
#
# Authentication is delegated to git-credential-github-app, installed via mise
# (see mise.toml). It mints short-lived GitHub App installation tokens on demand;
# git-credential-cache holds each token for its lifetime so the GitHub API is not
# called on every git operation.
set -euo pipefail

: "${HOME:=/opt/data}"

gh_app_dir="${HOME}/.config/github-app"
private_key_file="${gh_app_dir}/private-key.pem"

# The helper only accepts the private key as a file, so project it out of the env.
install -d -m 0700 "${gh_app_dir}"
printf '%s\n' "${GH_APP_PRIVATE_KEY}" >"${private_key_file}"
chmod 0600 "${private_key_file}"

# Helpers are consulted in order: the cache answers first, the GitHub App helper
# is the fallback that actually mints the token. Git runs a helper with arguments
# through a shell, hence the quoting around the username's "[bot]" suffix.
cat >"${HOME}/.gitconfig" <<EOF
[user]
	name = ${GH_APP_USERNAME}
	email = ${GH_APP_USERNAME}@users.noreply.github.com

[credential "https://github.com"]
	helper = cache --timeout=43200
	helper = github-app -username '${GH_APP_USERNAME}' -appId ${GH_APP_ID} -installationId ${GH_APP_INSTALLATION_ID} -privateKeyFile ${private_key_file}

[url "https://github.com"]
	insteadOf = ssh://git@github.com

[init]
	defaultBranch = main
EOF
chmod 0600 "${HOME}/.gitconfig"

chown -R hermes:hermes "${gh_app_dir}" "${HOME}/.gitconfig"
