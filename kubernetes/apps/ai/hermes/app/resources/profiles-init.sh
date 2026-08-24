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
# Anything a profile does not set falls back to Hermes' built-in defaults, not
# to the default profile: profiles do not inherit each other's config.yaml. The
# container env is the one thing they do share, which is what keeps the model
# providers, MCP credentials and git identity defined once for all of them.
set -euo pipefail

: "${HERMES_HOME:=/opt/data}"

src_root=/run/config/profiles

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

  for file in config.yaml SOUL.md; do
    if [[ -f "${src}${file}" ]]; then
      install -m 0644 -o hermes -g hermes "${src}${file}" "${dest}/${file}"
    fi
  done

  # Named after the mount rather than `.env` so it is visible in `ls` and in the
  # ConfigMap; Hermes only ever reads it as <profile>/.env.
  if [[ -f "${src}profile.env" ]]; then
    install -m 0600 -o hermes -g hermes "${src}profile.env" "${dest}/.env"
  fi

  echo "profile ${name}: synced -> ${dest}"
done
