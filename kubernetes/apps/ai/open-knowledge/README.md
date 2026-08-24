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
| `/data/project/.ok/local/config.yml` | The project-local config layer, rendered from `app/resources/local-config.yml` on every start. |

## The single-Host constraint

This shapes every routing decision here, so it is worth stating plainly:
**OpenKnowledge admits exactly one non-loopback `Host`** — the one in
`OK_EXTERNAL_URL` — plus loopback names. Anything else gets a `403`, the
cluster-internal service name included. A wildcard bind (`OK_BIND=0.0.0.0`)
contributes no admitted name of its own.

So every caller has to present `Host: ok.${DOMAIN}`, and each path below is
arranged to do that:

```
   browser ──► Cloudflare edge ──► Access policy (login)
                                            │
                                            │  Host: ok.${DOMAIN}
                                   cloudflared tunnel
                                            │
                                     traefik-public
                                            │
                                            ▼
                                 open-knowledge :8080
                                            ▲
                                            │  Host: ok.${DOMAIN}
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
that repo's history. It is set in the project-local config layer rather than the
environment; see below.

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
owner, and the public hostname is gated in one place:

**Cloudflare Access on `ok.${DOMAIN}`**, configured by hand in the Zero Trust
dashboard — Access is not managed in this repo. Nothing in the pod
authenticates anything, so *the editor is unprotected until that policy exists*.
One application, one login policy, no path carve-outs:

| Application | Path | Policy |
| --- | --- | --- |
| OpenKnowledge | `ok.${DOMAIN}` | Allow — your login rule (email, domain, or GitHub IdP) |

### There is no public MCP endpoint

The server serves `/mcp` on the same listener, but it is not published. The only
consumer is Hermes, which reaches the pod directly in-cluster, so the hostname
carries browser traffic only and a single blanket login policy covers it.

That is a deliberate trade. Publishing it would mean putting OpenKnowledge on
the cluster's shared `mcp` backend, and two things make that worse than it
looks: agentgateway forwards the *caller's* authority upstream, so the target
would receive `Host: mcp.${DOMAIN}` and hit the single-Host `403` above — and
that backend is **fail-closed**, so one failing target takes the whole aggregate
down with it, breaking `searxng`, `linkedin` and `memini` too. Giving
OpenKnowledge its own agentgateway route avoids both, at the cost of a dedicated
backend, route and policy.

To publish it later, pick one: its own agentgateway route (reusing the existing
`https://mcp.${DOMAIN}` audience, so no Auth0 change), or a shared target plus
`failureMode: FailOpen` and agents dialling `https://ok.${DOMAIN}/mcp` — that
host is what makes the gate pass. Either way `/mcp` also needs a Cloudflare
Access **Bypass** scoped to that path, or Access hands agents an HTML login page
instead of a tool list.

> **Access protects the public path only.** It enforces at the Cloudflare edge,
> while `traefik-public` also answers on the internal LoadBalancer IP — so
> anything on the LAN can still reach the editor by sending `Host: ok.${DOMAIN}`
> straight at it. That matches the posture of the other apps on this gateway
> (`hermes-code` runs code-server with `--auth none`), but it is worth stating
> plainly: an in-pod proxy would have authenticated the LAN path too, and
> putting the login at the edge gives that up.

## Container environment vs. the project's own settings

OpenKnowledge resolves settings in this order:

    CLI flags  >  environment  >  project-local config  >  project config  >  user config  >  defaults

The environment sits *above* every config file, so an `OK_*` set in the pod spec
is not merely a default — it cannot be adjusted anywhere else. That is the right
shape for what belongs to the container and the wrong shape for what belongs to
the instance running in it. Same split as the agent `.env` next door in
[hermes](../hermes/README.md).

**In the container env** (`app/helmrelease.yaml`): `PORT`, `OK_BIND`,
`OK_ALLOW_EXTERNAL` and `OK_EXTERNAL_URL` — the port the Service targets, the
address it binds, the exposure consent interlock, and the public origin the
ingress answers on. Editing any of these from inside the app would either break
ingress or stop the server booting, so they are deliberately out of reach. The
same block carries the bootstrap inputs `install.sh` reads (`OK_VERSION`,
`OK_GIT_REMOTE`, `OK_GIT_BRANCH`, `OK_PROJECT_DIR`, the git identity), which are
not OpenKnowledge settings at all.

**In the project-local config layer** (`app/resources/local-config.yml` →
`<project>/.ok/local/config.yml`, installed by `install.sh`):

| Setting | Why it is not container-wide |
| --- | --- |
| `server.idleShutdown` | Belongs to this server instance, not to the pod; in the env it could not be changed without a redeploy. |
| `autoSync.mode` | The sync posture of this checkout — the editor's own Sync settings write to the same key. |

That file is rewritten from git on every pod start, so what is in the repo wins
over what is on the volume. The consequence worth knowing: the editor keeps its
semantic-search, hidden-file and link-preview toggles in the same file, so a
change made in the Settings pane is lost on the next restart unless it is added
to `local-config.yml` as well.

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

No Bitwarden secrets are needed — this app has none of its own. Two things are
configured by hand instead.

**1. The Cloudflare Access applications** described above. Do this first: until
the login policy exists, the public hostname serves the editor to anyone who
finds it.

**2. The deploy key**, generated in-cluster. Once the Secret exists, read the
public half out and register it on `yvigara/lifeos` under **Settings → Deploy
keys**, with **Allow write access** ticked (full sync pushes):

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
- **`server.idleShutdown: "off"`** is required, not tuning. The idle timer only
  counts editor WebSocket clients, so a server busy serving MCP calls looks idle
  and tears itself down mid-session, handing Kubernetes a pod that exits for no
  visible reason.
- **Nothing in front may buffer `/mcp`** (server-sent events) and everything
  must preserve `Host` and forward `X-Forwarded-Proto: https` — without the
  latter the server hands the editor a `ws://` socket that browsers block as
  mixed content on an `https` page.
- **The repo is the durable copy.** With full sync on, content is pushed to `yvigara/lifeos`; the PVC holds the working clone, the CLI and per-machine config. Losing the volume costs the local state, not the knowledge base.
- **Back up `/data` before bumping `OK_VERSION`.** Upgrades run against the
  existing volume; the project, history and settings stay on it.
