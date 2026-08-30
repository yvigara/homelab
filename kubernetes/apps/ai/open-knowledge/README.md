# OpenKnowledge

[OpenKnowledge](https://openknowledge.ai) is an AI-native markdown IDE and LLM
wiki. One server process serves everything off a single port: the editor, the
API, the `/mcp` endpoint and the live-collaboration WebSocket.

This deploys the **web app** (`ok start`) as its own pod and wires its MCP
endpoint into the Hermes agent.

## The image

`ghcr.io/yvigara/open-knowledge`, built from
[yvigara/open-knowledge](https://github.com/yvigara/open-knowledge) — inkeep's
repo plus a `Dockerfile` and a release workflow. There is still no image from
inkeep themselves; their Docker guide hands you a Dockerfile to build yourself,
and this is that, built and published once rather than reassembled in an init
container on every pod start.

What the image settles, so this deployment does not have to:

- **`node:26-alpine` with `git`** — a hard boot requirement, since the server
  runs a git preflight and timeline/recovery shell out to the binary.
- **The CLI is baked** (`npm i -g @inkeep/open-knowledge@<version>`, pinned by CI
  from the release tag), so the image tag *is* the version knob.
- **`PORT=8080`, `OK_BIND=0.0.0.0`, `OK_HOME=/opt/data`** are baked and correct
  for us, so this deployment inherits rather than restates them.
- **An entrypoint** that runs `ok init --no-mcp --no-skills` on an uninitialized
  volume and then `ok start`.

`OK_ALLOW_EXTERNAL` is deliberately *not* baked — a run without it refuses to
boot and names the fix, which is the secure default — so this deployment sets it.

Two things about the tags, worth knowing before a bump:

- **They are all `test-`-prefixed** (`test-0.66.2`, `test-latest`), which is not
  a shape Renovate's semver versioning matches. Until a plain `0.66.2`/`v0.66.2`
  tag exists, expect to bump this by hand.
- **It is alpine**, so `kubectl exec` gets you BusyBox `sh`, not `bash`.

## Layout

One claim, mounted twice as siblings under its root. They cannot nest: `$HOME`
holds the GitHub credential, and anything inside the project is committed and
pushed by sync.

| Path | subPath | What it holds |
| --- | --- | --- |
| `/opt/data` | `project` | The knowledge base, and the image's `OK_HOME`/`WORKDIR`. |
| `/home/ok` | `home` | `$HOME` — `.ok/auth.yml` (the GitHub credential), `.ok/global.yml`, and any `git config --global` identity. |

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

## GitHub

Nothing about GitHub is configured here. The pod starts with an empty project —
the image's entrypoint runs `ok init` on a fresh volume — and everything else is
done from the editor once it is up:

1. **Connect GitHub** (Settings → Account) runs the device flow: the app shows a
   code, you enter it at `github.com/login/device`. No key to mint, register or
   rotate, and the grant is your own account's.
2. **Clone from GitHub**, or **Publish to GitHub** to push the project up as a
   new repo.
3. Pick a sync mode when the editor asks — `full` (pull and push) or `follow`
   (pull only).

The credential lands in `$HOME/.ok/auth.yml`, which is why `$HOME` is on the
volume rather than an emptyDir: on an emptyDir it would be gone on every
restart and the device flow would have to be repeated each time. `$HOME` is a
sibling of the project, not a corner of it, because sync commits everything the
knowledge base is not ignoring — a credential *inside* the project would be
pushed to the remote.

Two things worth knowing:

- **Commit identity.** With none set, OpenKnowledge commits under a default
  "OpenKnowledge" author and the sync indicator nags about it. `kubectl exec`
  into the pod and `git config --global user.name`/`user.email` once — `$HOME`
  is persistent, so it sticks.
- **Nothing in this repo rewrites `.ok/`.** The editor owns
  `.ok/local/config.yml` — the sync mode, the semantic-search, hidden-file and
  link-preview toggles — and no init container overwrites it on restart.

## Auth

**OpenKnowledge has no native auth**, re-checked against 0.66.2 (the version
this image ships) as well as 0.61.3 and main. There is no `auth.*` config
section — the env layer names it as "deferred entirely … until ratified" — no
`OK_AUTH_*` variable in any build, and no
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

**Baked into the image**: `PORT`, `OK_BIND` and `OK_HOME`. Correct as they are,
so this deployment inherits them rather than restating them in the pod spec.

**In the container env** (`app/helmrelease.yaml`), four values and no more:

| Variable | Why it belongs to the container |
| --- | --- |
| `OK_ALLOW_EXTERNAL` | The exposure consent interlock, which the image deliberately leaves unset so an unconsented run refuses to boot. |
| `OK_EXTERNAL_URL` | The public origin the ingress answers on. Changing it from inside the app would `403` every request. |
| `HOME` | `$HOME/.ok` is the user-global directory holding the GitHub credential; the image sets no `HOME` of its own. |
| `OK_IDLE_SHUTDOWN` | A server that exits on its own hands Kubernetes a pod that dies for no visible reason. Already the derived default for a non-loopback bind; pinned because it is load-bearing. |

**Nothing in the project-local config layer.** `.ok/local/config.yml` is left
entirely to the editor, which keeps the sync mode and the search/preview toggles
there. An earlier revision rendered that file from git and reinstalled it on
every start — the same contract as the agent `.env` next door in
[hermes](../hermes/README.md) — which was right while this deployment owned the
git setup, and is wrong now that the editor owns it: rewriting the file would
discard the sync mode chosen after signing in, on every restart.

## Hermes

Hermes reaches the knowledge base directly at
`http://open-knowledge.ai.svc.cluster.local:8080/mcp`, skipping the public
hostname — that one is behind a Cloudflare Access login it cannot complete. Its
`mcp_servers` entry therefore carries an explicit `Host: ok.${DOMAIN}` header —
that header is load-bearing, and without it every call is a `403`.

The tools land as `exec`, `search`, `write`, `edit`, `links` and friends.
Upstream's guidance for Hermes agents is worth repeating: inside an OK project,
markdown is MCP-owned — read and write `.md`/`.mdx` through these tools rather
than the shell, or attribution, frontmatter, backlinks and history are all
bypassed.

## Before this deploys

No secrets, no Bitwarden keys, no deploy key. One manual step:

**Create the Cloudflare Access application** for `ok.${DOMAIN}` with your login
policy. Do this first — until the login policy exists, the public hostname
serves the editor to anyone who finds it, with full read and write access.

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
- **With sync on, the remote is the durable copy** and the volume holds the
  working clone. With sync off — or before GitHub is connected at all — the
  volume is the *only* copy, so back it up.
- **Back up the volume before bumping the image tag.** An upgrade is a new image
  against the existing volume; the project, its history, its settings and the
  GitHub credential all stay on it.
