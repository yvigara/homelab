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
#   • ALWAYS restore a usable scripts dir. The first run moves the wrappers
#     aside; if the clone then fails, the cron scripts are simply GONE until
#     someone notices. Roll the quarantine back instead — a host with the old
#     wrappers is strictly better than a host with none.
# =============================================================================
set -uo pipefail

DATA_DIR="${DATA_DIR:-/opt/data}"
SCRIPTS_DIR="${SCRIPTS_DIR:-${DATA_DIR}/scripts}"
REPO_URL="${REPO_URL:-https://github.com/yvigara/hermes-scripts.git}"
QUARANTINE="${QUARANTINE:-${DATA_DIR}/backups/pre-scripts-checkout}"

log() { echo "[sync-cron-scripts] $*"; }

# The repo is PRIVATE, so the clone needs the GitHub App credential helper. In
# the init container that helper is NOT reliably on PATH: it is a mise shim, and
# a shim invoked without mise's environment fails ("'credential-github-app' is
# not a git command"). Resolve the real binary and pass it to git explicitly.
# Never rely on the global gitconfig here — this runs as the init container, not
# the app container.
credential_binary() {
  local b
  b="$(find "${DATA_DIR}/.local/share/mise/installs" -type f \
        -name git-credential-github-app 2>/dev/null | head -1)"
  [ -n "$b" ] && { printf '%s' "$b"; return 0; }
  b="$(find "${DATA_DIR}/.local" -type f -name git-credential-github-app 2>/dev/null | head -1)"
  [ -n "$b" ] && printf '%s' "$b"
}

# git wrapper: authenticates via the resolved helper when we have one.
# `credential.helper=` (empty) first RESETS the inherited helper list, so the
# broken mise shim and the credential cache in the app gitconfig are not
# consulted at all — otherwise every call logs "'credential-github-app' is not
# a git command" / "cache daemon did not start" and the outcome depends on
# whether a token happens to be cached from a previous session.
git_auth() {
  if [ -n "${HELPER_BIN}" ] && [ -n "${GH_APP_ID:-}" ] && [ -n "${GH_APP_INSTALLATION_ID:-}" ]; then
    git \
      -c "credential.helper=" \
      -c "credential.https://github.com/${REPO_OWNER}.useHttpPath=true" \
      -c "credential.https://github.com/${REPO_OWNER}.helper=${HELPER_BIN} -username x -appId ${GH_APP_ID} -privateKeyFile ${DATA_DIR}/.config/github-app/private-key.pem -installationId ${GH_APP_INSTALLATION_ID}" \
      "$@"
  else
    git "$@"
  fi
}

# Derive the owner from the URL so the credential scope matches the repo.
REPO_OWNER="$(printf '%s' "${REPO_URL}" | sed -n 's#.*github\.com[/:]\([^/]*\)/.*#\1#p')"
REPO_OWNER="${REPO_OWNER:-yvigara}"
HELPER_BIN="$(credential_binary)"
[ -n "${HELPER_BIN}" ] || log "WARNING: GitHub App credential helper not found; relying on ambient git credentials"

# ---- Leela's shim ------------------------------------------------------------
# A profile's scripts dir is its OWN confinement root: cron rejects a script
# whose resolved path leaves <profile_home>/scripts/. So leela's periodic job
# cannot point at the shared checkout — it needs a real file at
# /opt/data/profiles/leela/scripts/periodic-merge.sh that execs it. That shim is
# hand-placed on the volume today, which means a volume reset silently breaks
# her job ("Script not found"). Install it from the checkout, like everything
# else. Non-fatal.
install_leela_shim() {
  local src="${SCRIPTS_DIR}/bin/periodic-merge-leela-shim.sh"
  local dest_dir="${DATA_DIR}/profiles/leela/scripts"
  local dest="${dest_dir}/periodic-merge.sh"

  [ -f "${src}" ] || { log "NOTE: no leela shim in the checkout — leaving hers as-is"; return 0; }
  mkdir -p "${dest_dir}" || return 0

  # Never clobber an operator's local edit without evidence; warn instead.
  if [ -f "${dest}" ] && ! cmp -s "${src}" "${dest}"; then
    log "WARNING: ${dest} differs from the checkout — overwriting it from git"
  fi
  install -m 0644 -o hermes -g hermes "${src}" "${dest}" &&
    log "installed leela shim -> ${dest}"
}

# --- 1. First run: turn the scripts dir into the checkout --------------------
if [ ! -d "${SCRIPTS_DIR}/.git" ]; then
  MOVED_TO=""
  if [ -e "${SCRIPTS_DIR}" ] && [ -n "$(ls -A "${SCRIPTS_DIR}" 2>/dev/null)" ]; then
    # Preserve whatever was there (wrapper copies, operator files) before it is
    # replaced by the checkout.
    stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    mkdir -p "${QUARANTINE}"
    if mv "${SCRIPTS_DIR}" "${QUARANTINE}/scripts.${stamp}" 2>/dev/null; then
      MOVED_TO="${QUARANTINE}/scripts.${stamp}"
      log "moved existing ${SCRIPTS_DIR} -> ${MOVED_TO}"
    else
      log "WARNING: could not move ${SCRIPTS_DIR} aside — leaving it untouched"
      exit 0
    fi
  else
    rm -rf "${SCRIPTS_DIR}"
    mkdir -p "${QUARANTINE}"
    MOVED_TO=""   # nothing to roll back to
    log "NOTE: no existing scripts dir to preserve"
  fi

  install -d -m 0755 -o hermes -g hermes "${SCRIPTS_DIR}" || true

  # NOTE: stderr is NOT suppressed. A failed clone here is the difference
  # between a working host and one whose cron jobs are all broken; suppressing
  # the reason is how that goes unnoticed.
  if git_auth clone "${REPO_URL}" "${SCRIPTS_DIR}"; then
    log "cloned ${REPO_URL} -> ${SCRIPTS_DIR}"
  else
    log "ERROR: clone failed — rolling the previous scripts dir back"
    if [ -n "${MOVED_TO}" ] && [ -d "${MOVED_TO}" ]; then
      rm -rf "${SCRIPTS_DIR}"
      if mv "${MOVED_TO}" "${SCRIPTS_DIR}"; then
        log "restored the previous scripts dir from ${MOVED_TO}"
      else
        log "ERROR: could not restore from ${MOVED_TO} — cron scripts are MISSING"
      fi
    else
      log "ERROR: no previous scripts dir to restore — cron scripts are MISSING"
    fi
    exit 0
  fi

  chown -R hermes:hermes "${SCRIPTS_DIR}" 2>/dev/null || true
  install_leela_shim
  log "done (new checkout at $(git -C "${SCRIPTS_DIR}" rev-parse --short HEAD 2>/dev/null))"
  exit 0
fi

# --- 2. Existing checkout: fast-forward, or leave it alone -------------------
if [ -n "$(git -C "${SCRIPTS_DIR}" status --porcelain 2>/dev/null)" ]; then
  log "WARNING: ${SCRIPTS_DIR} has uncommitted changes — not touching it"
  install_leela_shim
  exit 0
fi

BRANCH="$(git -C "${SCRIPTS_DIR}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
if [ "${BRANCH}" != "main" ]; then
  log "WARNING: ${SCRIPTS_DIR} is on '${BRANCH}', not main — not touching it"
  install_leela_shim
  exit 0
fi

if git_auth -C "${SCRIPTS_DIR}" fetch origin main &&
   git -C "${SCRIPTS_DIR}" merge --ff-only origin/main; then
  log "fast-forwarded to $(git -C "${SCRIPTS_DIR}" rev-parse --short HEAD 2>/dev/null)"
else
  log "WARNING: could not fast-forward — using the checkout as-is"
fi

# Also heal a missing/stale leela shim on an existing checkout — it must not
# depend on a volume reset to get installed.
install_leela_shim

exit 0
