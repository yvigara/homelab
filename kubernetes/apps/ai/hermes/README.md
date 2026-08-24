# hermes

[Hermes Agent](https://github.com/NousResearch/hermes-agent) — one pod in `ai`,
running the gateway, the web dashboard and a code-server sidecar off a single
25 GiB `openebs-hostpath` volume at `/opt/data`.

| Piece | Where it comes from |
| --- | --- |
| Agent + dashboard | `app/helmrelease.yaml`, image `nousresearch/hermes-agent` |
| Agent config | `app/resources/config.yaml` → `/opt/data/config.yaml` |
| Extra agents | `app/resources/profiles/<name>/` → `/opt/data/profiles/<name>/` |
| Volume bootstrap | `app/resources/init.sh`, run by the init container |
| Container credentials | `hermes-secret`, via `envFrom` |
| The default agent's own settings | `hermes-profile-default`, mounted as a file |
| Git identity | `hermes-github-app` + `hermes-signing-key`, rendered by `git-init.sh` |
| Toolchain | `app/resources/mise.toml`, installed into the volume by `init.sh` |

Nothing on the volume is a source of truth. `init.sh` rewrites the config, the
mise toolchain config, the gitconfig and the agent's `.env` from the ConfigMap
and Secrets on every pod start, so what is in git wins over whatever is on disk.

## The volume bootstrap

`app/resources/init.sh` is the init container's whole command — it used to be a
heredoc inside `helmrelease.yaml`, which meant no shellcheck, no syntax
highlighting and a shell script indented eighteen columns inside a Helm values
block. It now sits next to `git-init.sh` in `app/resources/` and reaches the
container through the same generated ConfigMap, mounted at `/run/config/`.

## Container environment vs. the agent's own settings

Hermes resolves settings in this order:

    CLI flags  >  process environment  >  config.yaml  >  .env  >  defaults

Process env sits *above* `config.yaml`, so a value set in the pod spec is not
merely a default — it cannot be overridden anywhere else. That is the right
shape for things that belong to the container as a whole, and the wrong shape
for things that belong to the agent running in it.

**In the container env** (`app/helmrelease.yaml`, `cluster-vars`,
`hermes-secret`): the model provider key, the memini/searxng/camofox endpoints,
the MCP credentials, the git identity, `HERMES_HOME`, `HERMES_UID`/`GID`, and
the dashboard, which is a machine-level surface rather than an agent-level one.
These are defined once and interpolate into `config.yaml` as `${...}`.

**In the agent's own `.env`** (`hermes-profile-default`, rendered whole as a
dotenv document and installed to `/opt/data/.env` by `init.sh`):

| Setting | Why it is not container-wide |
| --- | --- |
| `API_SERVER_*` | The port a gateway binds. Every Hermes gateway defaults to 8642, so this has to be settable per agent. |
| `SLACK_*`, `BUZZ_*` | Hermes locks a bot token to one agent and refuses any other gateway that claims it. |
| `MEMINI_NAMESPACE` | The memory namespace this agent reads and writes. |

One consequence worth knowing: `/opt/data/.env` is rewritten on every pod start,
so an API key set through `hermes config set` or the dashboard is lost on the
next restart unless it is also added to `app/externalsecret.yaml`.

## Profiles

A Hermes *profile* is a second agent living in the same install: its own
`config.yaml`, `.env`, `SOUL.md`, memory, sessions, skills, cron jobs and state
database. The default profile is `$HERMES_HOME` itself — here `/opt/data` — and
every named profile is a directory under `$HERMES_HOME/profiles/<name>`. That is
the whole mechanism; `hermes -p coder chat` is just
`HERMES_HOME=/opt/data/profiles/coder hermes chat`.

Profiles are not sandboxes. They separate Hermes' own state, nothing else — on
the `local` terminal backend every profile still has the same filesystem access
inside the pod.

### One pod, many profiles

The image runs s6-overlay as PID 1, and its boot reconciler walks
`$HERMES_HOME/profiles/` on every start, registering a supervised gateway slot
for each profile it finds. So profiles are added by putting a directory on the
volume — which is what `app/resources/profiles-init.sh` does from the init
container, out of the generated ConfigMap. Like the rest of `init.sh`, it is
authoritative: rewritten from git on every pod start.

The alternative — one Deployment per profile, each with its own PVC — buys
resource isolation and independent image pinning at the cost of a second copy of
the whole manifest, a second volume and a second dashboard. Upstream recommends
the single container, and so does the fact that the dashboard here is already
machine-level: it serves *every* co-located profile through the profile switcher
in its sidebar, so a new profile is reachable at `hermes.<domain>` the moment it
exists, with no new route, service or hostname.

### What profiles share

The container environment, and only that. It is where the reuse lives: the model
provider key, the memini/searxng/camofox endpoints, the MCP credentials, the git
identity and the `cluster-vars` values are defined once in `helmrelease.yaml` and
resolve in every profile's `config.yaml` through `${...}` interpolation. A
profile's `config.yaml` restates only what that agent actually needs; it does
**not** inherit the default profile's config.yaml.

The split described above is what makes this safe. Everything scoped to a single
agent — gateway port, bot tokens, memory namespace — is already out of the
container env and in a per-agent `.env`, so a second profile can hold its own
values rather than inheriting the default agent's and colliding with them.

### Adding a profile

1. Create `app/resources/profiles/<name>/` with `config.yaml`, `SOUL.md` and, if
   anything needs to differ per agent, `profile.env`.
2. Add the three files to the `configMapGenerator` in `app/kustomization.yaml`
   as flat `profiles-<name>-*` keys — ConfigMap keys cannot contain `/`.
3. Mount them back into `/run/config/profiles/<name>/` with `subPath` in
   `app/helmrelease.yaml`.

`profiles-init.sh` picks the directory up generically from there and creates
`workspace/` for the profile's `terminal.cwd`.

To give a profile its own chat platform or API server, it needs credentials of
its own — a second ExternalSecret rendering a dotenv document, exactly like
`hermes-profile-default`, plus a distinct `API_SERVER_PORT`, a container port
and a route. Do not hand it the default agent's tokens; the token lock will
reject it.

Never point two processes at one profile. Both write memory automatically and
each loads the other's writes into its system prompt, so two writers on one home
compound each other's state indefinitely. `strategy: Recreate` on the controller
is what keeps that from happening across a rollout.

### The `coder` example

`app/resources/profiles/coder/` is a worked example: a coding agent on the same
providers as the default agent, with `reasoning_effort: high`, a longer terminal
timeout, `terminal.cwd` in its own workspace, and the chat-oriented toolsets
dropped. It reuses `${HERMES_OMLX_KEY}` and the memini/searxng endpoints from
the container env and defines nothing of its own beyond
`MEMINI_NAMESPACE=hermes-coder`.

It runs **no gateway** — no bot token to lock, no port to collide — and is used
through the dashboard's profile switcher or from a shell:

```console
$ kubectl -n ai exec -it deploy/hermes -c app -- hermes profile list
$ kubectl -n ai exec -it deploy/hermes -c app -- hermes -p coder chat
```

Its memory, sessions and skills are its own; nothing it learns reaches the
default agent.
