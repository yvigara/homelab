#!/bin/sh
# shellcheck shell=sh
# Runs `ok init` once on an empty volume, then starts the server.
set -eu

OK_HOME="${OK_HOME:-/opt/data}"

# `ok init` writes into the cwd, so follow a run-time OK_HOME override.
if ! cd "${OK_HOME}" 2>/dev/null; then
  echo "[entrypoint] OK_HOME=${OK_HOME} does not exist. Mount a volume there, or unset OK_HOME to use the image default." >&2
  exit 1
fi

if [ ! -d "${OK_HOME}/.ok" ]; then
  echo "[entrypoint] ${OK_HOME} is not initialized. Running ok init --no-mcp --no-skills"
  # stdin closed so init never waits on a prompt.
  ok init --no-mcp --no-skills </dev/null
fi
exec ok start
