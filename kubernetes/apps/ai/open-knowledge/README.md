# OpenKnowledge

[OpenKnowledge](https://openknowledge.ai) is an AI-native markdown IDE and LLM
wiki. One server process serves everything off a single port: the editor, the
API, the `/mcp` endpoint and the live-collaboration WebSocket.

This deploys the **web app** (`ok start`) as its own pod and wires its MCP
endpoint into the Hermes agent.

## Why there is no upstream image

There is no OpenKnowledge image on any registry — upstream's own Docker guide
says so and hands you a Dockerfile to build yourself. Rather than take on an
image-build pipeline this repo does not otherwise have, the pod runs the
official `node:24-bookworm` image and installs the CLI onto the PVC from an init
container, the same shape the Hermes pod already uses to put `mise` on its
volume.

Two consequences worth knowing:

- **`node:24-bookworm`, not `-slim`.** `git` is a hard boot requirement — the
  server runs a git preflight, and timeline/recovery shell out to the binary —
  and only the full Debian variant already carries it.
- **`OK_VERSION` is the version knob**, tracked by Renovate against the npm
  package. The init container reinstalls only when it changes; an unchanged
  restart skips the download.

## Layout

| Path | What it holds |
| --- | --- |
| `/data` | The PVC. `HOME`, the npm global prefix, and the project all live here. |
| `/data/.npm-global` | The `ok` CLI, on `PATH` for the app container. Kept outside the project so `node_modules` never lands in the knowledge base. |
| `/data/project` | The knowledge base itself — a clone of `yvigara/lifeos`, which the server watches, writes and syncs. |
| `/data/.ssh` | The deploy key, `known_hosts` and the `github.com` ssh config. |

## The single-Host constraint

This shapes every routing decision here, so it is worth stating plainly:
**OpenKnowledge admits exactly one non-loopback `Host`** — the one in
`OK_EXTERNAL_URL` — plus loopback names. Anything else gets a `403`, the
cluster-internal service name included. A wildcard bind (`OK_BIND=0.0.0.0`)
contributes no admitted name of its own.

So every caller has to present `Host: ok.${DOMAIN}`, and each path below is
arranged to do that:

```
                          ok.${DOMAIN}  (Cloudflare-proxied, traefik-public)
                                 │
              ┌──────────────────┴───────────────────┐
        /mcp, /.well-known/…                   everything else
              │                                      │
       agentgateway-proxy                      oauth2-proxy  ──►  Dex ──► GitHub
   (Auth0 JWT + MCP OAuth)                   (sidecar, :4180)      (celest-io org)
              │                                      │
              └──────────────► open-knowledge :8080 ◄┘
                                       ▲
                                       │ Host: ok.${DOMAIN}
                                  Hermes (in-cluster, direct)
```

`/healthz` and `/readyz` are mounted above every admission gate, which is why
kubelet probes — arriving with an IP `Host` — are not refused.

## The knowledge base repo

The content lives in its own repository, `yvigara/lifeos`, cloned over SSH on
first boot and kept in sync from then on. Later boots find the clone and skip
straight to starting the server.

**Sync is `full`**: the server fetches from the remote, commits edits made in
the editor or by agents, and pushes them back — so automated commits land in
that repo's history. There is no environment variable for this (the recognized
`OK_*` surface covers server settings only), so the init script writes
`autoSync.mode: full` into the gitignored `.ok/local/config.yml`, and leaves it
alone once present so a change made in the editor's Sync settings survives a
restart.

### The deploy key

Generated in-cluster by the external-secrets `SSHKey` generator, the same way
`hermes-signing-key` is: the private half never leaves the cluster, and
`refreshInterval: "0"` keeps it from being regenerated out from under the
registered public half. Deleting the ExternalSecret or its Secret mints a brand
new key, which then has to be re-registered on the repo.

**The key must be configured under `$HOME`, not in the environment.** The server
replaces — not merges — the environment of every git it spawns, preserving only
a fixed allowlist. `GIT_SSH_COMMAND` is not on that allowlist, so a git-over-SSH
setting passed that way is silently dropped mid-sync. `HOME` *is* on it, which
is exactly how ssh is meant to find its own config, so the init script writes
`~/.ssh/{id_ed25519,config,known_hosts}` instead.

`known_hosts` is fetched from `api.github.com/meta` over TLS rather than
discovered by connecting on port 22. The trust root is then GitHub's
certificate instead of whatever answered first, and it self-heals when GitHub
rotates a host key (as they did in 2023). `StrictHostKeyChecking` stays at
`yes`; if the fetch fails and no cached file exists, the init container fails
rather than connecting unverified.

## Auth

**OpenKnowledge has no native auth**, as of 0.61.3 (latest), 0.62.0-beta.19 and
main. There is no `auth.*` config section — the env layer names it as "deferred
entirely … until ratified" — no `OK_AUTH_*` variable in either build, and no
inbound auth anywhere in the server: every `Authorization`, `Bearer` and
`WWW-Authenticate` in the codebase is outbound (the GitHub API, the embeddings
provider, and MCP *client* OAuth discovery, which reads `WWW-Authenticate` off a
response). The "Sign in" strings in the UI are all about signing in *to GitHub*
for sync. Re-check before assuming otherwise, and do not drop the edges below on
the strength of a release note alone.

The external proxy is the upstream-intended deployment, not a workaround:
`boot.ts` reasons explicitly about running "behind an authenticating reverse
proxy with a public `server.externalUrl`", and deliberately routes the server's
own self-calls at its bound listener so they do not hairpin out through the edge
and come back as an HTML login page.

So everyone who reaches the server has full read and write access as the same
owner, and both public paths are gated at the edge, reusing what the cluster
already runs:

- **Editor → Dex.** An `oauth2-proxy` sidecar fronts the app on `:4180` using
  the `open-knowledge` Dex staticClient, alongside the existing
  `hermes-dashboard` and `rustfs` clients. Dex gates on membership of the
  `celest-io` GitHub org, so `OAUTH2_PROXY_EMAIL_DOMAINS` is deliberately `*` —
  the org check is the authorization boundary, and a second email-domain rule
  would only add a way to lock yourself out.
- **`/mcp` → Auth0, via agentgateway.** A headless agent cannot complete a
  cookie login, so `/mcp` is routed around oauth2-proxy to the agentgateway
  proxy, which enforces the same Auth0 JWT policy as the rest of the cluster's
  MCP surface and advertises Protected Resource Metadata so MCP clients can
  register dynamically and sign in through GitHub.

`/mcp` gets its own hostname-scoped route rather than becoming another target on
the shared `mcp` backend: agentgateway forwards the caller's *original*
authority upstream, so a request that arrived as `ok.${DOMAIN}` still reads as
`ok.${DOMAIN}` at the server. Aggregating it under `mcp.${DOMAIN}` would present
that host instead and earn a `403` on every call. It reuses the existing
`https://mcp.${DOMAIN}` audience — this is another route behind the same
gateway, not a new API — so no Auth0/terraform change is needed.

## Hermes

Hermes reaches the knowledge base directly at
`http://open-knowledge.ai.svc.cluster.local:8080/mcp`, skipping both edges: it
cannot complete the browser login, and it holds no Auth0 token. Its
`mcp_servers` entry therefore carries an explicit `Host: ok.${DOMAIN}` header —
that header is load-bearing, and without it every call is a `403`.

The tools land as `exec`, `search`, `write`, `edit`, `links` and friends.
Upstream's guidance for Hermes agents is worth repeating: inside an OK project,
markdown is MCP-owned — read and write `.md`/`.mdx` through these tools rather
than the shell, or attribution, frontmatter, backlinks and history are all
bypassed.

## Before this deploys

Two secrets have to exist in Bitwarden Secrets Manager:

| Key | How to generate |
| --- | --- |
| `OPEN_KNOWLEDGE_OIDC_CLIENT_SECRET` | `openssl rand -hex 32` — must match the Dex staticClient. |
| `OPEN_KNOWLEDGE_COOKIE_SECRET` | `openssl rand -hex 16`. Must decode to 16, 24 or 32 bytes; `openssl rand -base64 32` produces 44 characters and oauth2-proxy refuses to start. |

The deploy key is *not* one of them — it is generated in-cluster. Once the
Secret exists, read the public half out and register it on `yvigara/lifeos`
under **Settings → Deploy keys**, with **Allow write access** ticked (full sync
pushes):

```sh
kubectl -n ai get secret open-knowledge-deploy-key -o jsonpath='{.data.SSH_DEPLOY_KEY_PUB}' | base64 -d
```

Until that key is registered the init container's clone fails and the pod stays
in init — which is the intended failure mode, not a silent read-only start.

## Operational notes

- **One replica, always.** The collaboration server is single-writer: one
  process per project volume. Two replicas silently run two writers against the
  same data and nothing inside the container enforces the exclusion. The
  controller is `Recreate` for the same reason.
- **`OK_IDLE_SHUTDOWN=off`** is required, not tuning. The idle timer only counts
  editor WebSocket clients, so a server busy serving remote agents looks idle
  and tears itself down mid-session.
- **Nothing in front may buffer `/mcp`** (server-sent events) and everything
  must preserve `Host` and forward `X-Forwarded-Proto: https` — without the
  latter the server hands the editor a `ws://` socket that browsers block as
  mixed content on an `https` page.
- **The repo is the durable copy.** With full sync on, content is pushed to `yvigara/lifeos`; the PVC holds the working clone, the CLI and per-machine config. Losing the volume costs the local state, not the knowledge base.
- **Back up `/data` before bumping `OK_VERSION`.** Upgrades run against the
  existing volume; the project, history and settings stay on it.
