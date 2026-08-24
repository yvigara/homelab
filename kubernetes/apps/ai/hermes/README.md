# hermes

[Hermes Agent](https://github.com/NousResearch/hermes-agent) — one pod in `ai`,
running the gateway, the web dashboard and a code-server sidecar off a single
25 GiB `openebs-hostpath` volume at `/opt/data`.

| Piece | Where it comes from |
| --- | --- |
| Agent + dashboard | `app/helmrelease.yaml`, image `nousresearch/hermes-agent` |
| Agent config | `app/resources/config.yaml` → `/opt/data/config.yaml` |
| Volume bootstrap | `app/resources/init.sh`, run by the init container |
| Container credentials | `hermes-secret`, via `envFrom` |
| The agent's own settings | `hermes-profile-default`, mounted as a file |
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
