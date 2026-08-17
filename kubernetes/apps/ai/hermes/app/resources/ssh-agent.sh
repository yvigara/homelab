#!/usr/bin/env bash
# Holds the commit-signing key for the agent container, as a native sidecar.
#
# The key arrives unencrypted from the SSHKey generator, is encrypted here with
# the passphrase from the same secret, loaded into ssh-agent, and then removed
# from the filesystem. Only the agent socket is shared with the app container, so
# the private key never lands on the PVC and never enters the app container's
# mount namespace or environment.
set -euo pipefail

: "${SSH_AUTH_SOCK:=/run/ssh-agent/agent.sock}"
export SSH_AUTH_SOCK

keydir=/run/ssh-key
key="${keydir}/signing_key"
askpass="${keydir}/askpass"

for binary in ssh-agent ssh-add ssh-keygen; do
  command -v "${binary}" >/dev/null ||
    { echo "FATAL: ${binary} not found; the image needs an openssh client" >&2; exit 1; }
done

# mkdir, not install -d: these are mounted volume roots owned by the kubelet,
# and chmod'ing them from an unprivileged container fails. umask keeps the
# files written below at 0600 regardless.
umask 077
mkdir -p "${keydir}" "$(dirname "${SSH_AUTH_SOCK}")"

# Left behind by a previous run: ssh-agent refuses to bind over it.
rm -f "${SSH_AUTH_SOCK}"

printf '%s\n' "${SSH_SIGNING_KEY}" >"${key}"
ssh-keygen -q -p -P "" -N "${SSH_SIGNING_KEY_PASSPHRASE}" -f "${key}"

# ssh-add only takes a passphrase from an askpass helper, never from a pipe.
cat >"${askpass}" <<'EOF'
#!/bin/sh
printf '%s\n' "${SSH_SIGNING_KEY_PASSPHRASE}"
EOF
chmod 0700 "${askpass}"

ssh-agent -D -a "${SSH_AUTH_SOCK}" &
agent=$!

for _ in $(seq 100); do
  [ -S "${SSH_AUTH_SOCK}" ] && break
  sleep 0.1
done

SSH_ASKPASS="${askpass}" SSH_ASKPASS_REQUIRE=force ssh-add "${key}"
rm -f "${key}" "${askpass}"

ssh-add -l

wait "${agent}"
