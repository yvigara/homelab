#!/usr/bin/env bash
# Materialises every additional Hermes profile declared in git onto the data
# volume. Called from init.sh, after the default agent's own setup.
#
# A Hermes profile is nothing more than a directory: the default profile is
# $HERMES_HOME itself, every named profile is $HERMES_HOME/profiles/<name>, and
# each one holds its own config.yaml, .env and SOUL.md. The container's boot
# reconciler walks that directory on start, so a profile that exists on the
# volume is a profile Hermes knows about - no imperative `hermes profile create`
# needed to bring one into being.
#
# Two of those three files are managed here:
#
#   config.yaml  copied from the profile's ConfigMap.
#   .env         assembled from two halves - the non-secret half from the same
#                ConfigMap, and the secret half from the hermes-profile-env
#                Secret, which carries each agent's own Buzz identity.
#
# SOUL.md is deliberately NOT managed here. It is maintained outside this
# repository and lives only on the volume; nothing in this script reads, writes
# or removes it.
#
# Anything a profile does not set falls back to Hermes' built-in defaults, not
# to the default profile: profiles do not inherit each other's config.yaml. The
# container env is the one thing they do share, which is what keeps the model
# providers, MCP credentials and git identity defined once for all of them.
set -euo pipefail

: "${HERMES_HOME:=/opt/data}"

src_root=/run/config/profiles
secret_root=/run/secrets/hermes-profiles

if [[ ! -d ${src_root} ]]; then
  exit 0
fi

for src in "${src_root}"/*/; do
  [[ -d ${src} ]] || continue
  name=$(basename "${src}")
  dest="${HERMES_HOME}/profiles/${name}"

  # `terminal.cwd` has to exist before the first command runs in it; keeping it
  # inside the profile is what makes the profile a self-contained unit.
  install -d -m 0755 -o hermes -g hermes \
    "${HERMES_HOME}/profiles" "${dest}" "${dest}/workspace"

  if [[ -f "${src}config.yaml" ]]; then
    install -m 0644 -o hermes -g hermes "${src}config.yaml" "${dest}/config.yaml"
  fi

  # Built out of view and moved into place, so a half-written .env is never
  # readable and never what the agent starts from.
  staged="${dest}/.env.staged"
  install -m 0600 -o hermes -g hermes /dev/null "${staged}"

  # profile.env is named for the mount rather than `.env` so it is visible in
  # `ls` and in the ConfigMap; Hermes only ever reads the assembled file.
  if [[ -f "${src}profile.env" ]]; then
    cat "${src}profile.env" >>"${staged}"
  fi

  if [[ -f "${secret_root}/${name}.env" ]]; then
    printf '\n' >>"${staged}"
    cat "${secret_root}/${name}.env" >>"${staged}"
    secret="+secret"
  else
    # Expected until the profile's keys exist in Bitwarden - the agent simply
    # has no Buzz identity yet. Not a reason to fail the pod.
    secret="no-secret"
  fi

  mv -f "${staged}" "${dest}/.env"

  echo "profile ${name}: synced -> ${dest} (env: configmap ${secret})"
done
