#!/usr/bin/env bash
# =============================================================================
# sync-cron-scripts.sh — make <HERMES_HOME>/scripts/ a checkout of the
# yvigara/hermes-scripts repo, and fast-forward it at pod start.
#
# Why: Hermes confines cron scripts to <HERMES_HOME>/scripts/ — an absolute path
# or a symlink resolving elsewhere is blocked ("resolves outside the scripts
# directory"). So that directory has to physically hold the scripts. Rather than
# copying them in from the repo (which leaves the executing file a copy that can
# silently drift), we make the directory BE the repo:
#
#     the executing file is the repo file
#
# which makes drift structurally impossible. Updating is `git pull`.
#
# Design (non-negotiable, see card t_0b6e5e7a):
#   • NEVER fail the pod. If GitHub is unreachable the checkout is used as-is;
#     a boot that cannot reach GitHub must still boot.
#   • Only ever fast-forward. If the checkout is dirty (an operator or agent is
#     mid-edit) or not on main, leave it completely alone and say so. Forcing
#     would destroy unreviewed work; installing from a stray branch would ship
#     unreviewed code. Both are the failure this replaces.
#   • Move an existing, non-empty, non-checkout scripts dir aside rather than
#     deleting it — first run on a live host should not be destructive.
# =============================================================================
set -uo pipefail

DATA_DIR="${DATA_DIR:-/opt/data}"
SCRIPTS_DIR="${SCRIPTS_DIR:-${DATA_DIR}/scripts}"
REPO_URL="${REPO_URL:-https://github.com/yvigara/hermes-scripts.git}"
QUARANTINE="${DATA_DIR}/backups/pre-scripts-checkout"

log() { echo "[sync-cron-scripts] $*"; }

# --- 1. First run: turn the scripts dir into the checkout --------------------
if [ ! -d "${SCRIPTS_DIR}/.git" ]; then
  if [ -e "${SCRIPTS_DIR}" ] && [ -n "$(ls -A "${SCRIPTS_DIR}" 2>/dev/null)" ]; then
    # Preserve whatever was there (wrapper copies, operator files) before it is
    # replaced by the checkout.
    stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    mkdir -p "${QUARANTINE}"
    mv "${SCRIPTS_DIR}" "${QUARANTINE}/scripts.${stamp}" 2>/dev/null ||
      { log "WARNING: could not move ${SCRIPTS_DIR} aside — leaving it untouched"; exit 0; }
    log "moved existing ${SCRIPTS_DIR} -> ${QUARANTINE}/scripts.${stamp}"
  else
    rm -rf "${SCRIPTS_DIR}"
  fi

  install -d -m 0755 -o hermes -g hermes "${SCRIPTS_DIR}" || true
  if git clone --quiet "${REPO_URL}" "${SCRIPTS_DIR}" 2>/dev/null; then
    log "cloned ${REPO_URL} -> ${SCRIPTS_DIR}"
  else
    log "WARNING: clone failed — cron scripts will be missing until a boot can reach GitHub"
    exit 0
  fi
  chown -R hermes:hermes "${SCRIPTS_DIR}" 2>/dev/null || true
  log "done (new checkout at $(git -C "${SCRIPTS_DIR}" rev-parse --short HEAD 2>/dev/null))"
  exit 0
fi

# --- 2. Existing checkout: fast-forward, or leave it alone -------------------
if [ -n "$(git -C "${SCRIPTS_DIR}" status --porcelain 2>/dev/null)" ]; then
  log "WARNING: ${SCRIPTS_DIR} has uncommitted changes — not touching it"
  exit 0
fi

BRANCH="$(git -C "${SCRIPTS_DIR}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
if [ "${BRANCH}" != "main" ]; then
  log "WARNING: ${SCRIPTS_DIR} is on '${BRANCH}', not main — not touching it"
  exit 0
fi

if git -C "${SCRIPTS_DIR}" fetch --quiet origin main 2>/dev/null &&
   git -C "${SCRIPTS_DIR}" merge --quiet --ff-only origin/main 2>/dev/null; then
  log "fast-forwarded to $(git -C "${SCRIPTS_DIR}" rev-parse --short HEAD 2>/dev/null)"
else
  log "WARNING: could not fast-forward — using the checkout as-is"
fi

exit 0
