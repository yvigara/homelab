#!/usr/bin/env bash
# config-drift cron entrypoint.
#
# --no-agent job: this script IS the job. Its stdout is delivered verbatim to the
# target, and an EMPTY stdout is silent (so a clean check never pings anyone).
# config-drift.py --quiet prints nothing when there is no drift — that is what makes
# the clean case silent.
#
# The exit code is deliberately swallowed: a non-zero exit would make the cron deliver
# a failure notice every 15 minutes on drift, duplicating the alert we just printed.
set -uo pipefail

DRIFT_DIR=/opt/data/scripts/drift
PYTHON=/opt/hermes/.venv/bin/python3
[[ -x ${PYTHON} ]] || PYTHON=python3

report=$("${PYTHON}" "${DRIFT_DIR}/config-drift.py" --quiet 2>&1)

if [[ -n ${report} ]]; then
  printf '%s\n' "${report}"
  printf '\n_source: cron config-drift (15m) | host: %s | %s_\n' "$(hostname)" "$(date -Is)"
fi
exit 0
