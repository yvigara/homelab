#!/bin/sh
# Installs $HOME/.ok/global.yml on the volume before the server starts.
#
# Runs out of the same ConfigMap as the file it installs, and is authoritative
# on every pod start - what is in git wins over what is on the volume, so a
# copy edited in the pod is replaced on the next restart.
#
# Only global.yml. The rest of .ok/ belongs to the editor: auth.yml holds the
# GitHub credential the device flow wrote, and the project's own config.yml and
# local/config.yml hold the sync mode and the plugin toggles.
#
# Runs as uid 1000 like the app container (defaultPodOptions), which reaches the
# volume through fsGroup, so nothing here needs root or a chown.
set -eu

mkdir -p "${HOME}/.ok"
cp /run/config/global.yml "${HOME}/.ok/global.yml"
