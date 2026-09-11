# hermes

[Hermes Agent](https://github.com/NousResearch/hermes-agent) — one pod in `ai`,
running the gateway, the web dashboard and a code-server sidecar off a single
25 GiB `openebs-hostpath` volume at `/opt/data`.

| Piece | Where it comes from |
| --- | --- |
| Agent + dashboard | `app/helmrelease.yaml`, image `nousresearch/hermes-agent` |
| Agent config | `app/resources/config.yaml` → `/opt/data/config.yaml` |
| Agent profiles | `app/resources/profiles/<name>/` → `/opt/data/profiles/<name>/` (config + env only) |
| Volume bootstrap | `app/resources/init.sh`, run by the init container |
| Container credentials | `hermes-secret`, via `envFrom` |
| Per-agent secrets | `hermes-profile-env`, one dotenv fragment per profile, mounted as files |
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

**In the agent's own `.env`** (`hermes-profile-env`, key `default.env`, rendered
whole as a dotenv document and installed to `/opt/data/.env` by `init.sh`):

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
the whole mechanism; `hermes -p fry chat` is just
`HERMES_HOME=/opt/data/profiles/fry hermes chat`.

Profiles are not sandboxes. They separate Hermes' own state, nothing else — on
the `local` terminal backend every profile still has the same filesystem access
inside the pod.

### One pod, many profiles

The image runs s6-overlay as PID 1, and its boot reconciler walks
`$HERMES_HOME/profiles/` on every start, registering a supervised gateway slot
for each profile it finds. So profiles are added by putting a directory on the
volume — which is what `app/resources/profiles-init.sh` does from the init
container. Like the rest of `init.sh` it is authoritative: rewritten from git on
every pod start.

Each profile is one ConfigMap, mounted as a whole directory at
`/run/config/profiles/<name>/`. Adding a profile is one `configMapGenerator`
entry and one `persistence` block — no per-file mounts.

### What this repo manages, and what it does not

Of the three files that make a profile, this repo owns two:

| File | Managed by |
| --- | --- |
| `config.yaml` | this repo — rewritten from the ConfigMap on every pod start |
| `.env` | this repo — assembled on every pod start from the ConfigMap's `profile.env` plus the profile's fragment in `hermes-profile-env` |
| `SOUL.md` | **outside this repo** — lives only on the volume |

`profiles-init.sh` never reads, writes or removes `SOUL.md`. A persona edited on
the volume survives every restart and every Flux reconcile; nothing here will
overwrite it, and nothing here will recreate it if it is deleted.

The alternative — one Deployment per profile — buys resource isolation at the
cost of eleven copies of the manifest, eleven volumes and eleven dashboards.
Upstream recommends the single container, and the dashboard here is already
machine-level: it serves *every* co-located profile through the switcher in its
sidebar, so a new profile is reachable at `hermes.<domain>` the moment it exists.

### What profiles share

The container environment, and only that. It is where the reuse lives: the model
provider key, the memini/searxng/camofox endpoints, the MCP credentials, the git
identity and the `cluster-vars` values are defined once in `helmrelease.yaml` and
resolve in every profile's `config.yaml` through `${...}` interpolation. A
profile's `config.yaml` restates only what that agent needs; it does **not**
inherit the default profile's.

The provider block is the exception: every profile carries the same one as the
default agent's `config.yaml` — `k8s-omlx`, `k8s-ollama-local`,
`k8s-lfm2.5-2.6b`, plus `k8s-ollamacloud` for the two public-content profiles —
kept in step with it rather than trimmed per profile, so a model added to the
cluster reaches every agent that could use it.

`k8s-ollama-local` reaches the Ollama server behind `agentgateway`'s
`/ollama-local` route. It carries no `default_model`, so nothing routes to it
until a model tag is named; reach it explicitly with a `model_aliases` entry.

Everything scoped to a single agent — gateway port, bot tokens, memory namespace
— is out of the container env and in that profile's own `.env`, so profiles hold
their own values rather than inheriting one another's.

Each `.env` is assembled from two halves, because half of it is not secret and
belongs in git:

- **the ConfigMap half**, `app/resources/profiles/<name>/profile.env` — memory
  namespace, gateway flags, anything reviewable in a diff;
- **the Secret half**, key `<name>.env` in `hermes-profile-env` — the agent's own
  Buzz identity, and anywhere else a profile eventually needs credentials of its
  own.

`profiles-init.sh` concatenates them into `<profile>/.env`. The secret half is
optional: a profile whose key is not in Bitwarden yet is synced without it and
logged as `no-secret` rather than failing the pod.

## The agent system

Eleven profiles. The architecture is deliberately thin, and the constraints
below are load-bearing rather than stylistic — most of them are enforced by
configuration, and the ones that cannot be are stated as rules in the profile's
`SOUL.md`.

| Profile | Role | Model | Memory |
| --- | --- | --- | --- |
| **Farnsworth** | Orchestrator — routes and runs cron | local Qwen3.5-9B | none |
| **Fry** | Writer, voice-bound | remote deepseek-v4-flash | voice corpus, transcripts, past work |
| **Morbo** | Editorial critic | local Qwen3.5-9B | none |
| **Mom** | Marketing, brand, distribution | remote deepseek-v4-flash | channels, audience, assets |
| **Amy** | Community — meetup, Tech Drinks | local Qwen3.5-9B | people, venues, sponsors, dates |
| **Conrad** | Ledger — finance, invoicing, tax | local Qwen3.5-9B | transactions, entities, obligations |
| **Leela** | Life — health, household, personal | local Qwen3.5-9B | personal admin |
| **Bender** | Forge — dispatches into Claude Code | local Qwen3.5-9B | none |
| **Nixon** | Operata tenant, broker | local Qwen3.5-9B (**no cloud provider**) | Operata work |
| **Nibbler** | Celestio tenant — consulting pipeline | local Qwen3.5-9B (**no cloud provider**) | pipeline (empty until first contract) |
| **Wernstrom** | Business strategy, advisory | local Qwen3.5-9B | frameworks, prior advice |

### The orchestrator is stateless

Farnsworth routes a request to exactly one profile and runs the scheduled jobs.
It is not a task queue, it does not synthesise other profiles' output, and it
runs no approval workflow. Its `memory_enabled` is `false`, so it cannot hold
state between invocations even by accident.

### The vault is the handoff mechanism

Profiles pass work through files at agreed paths in the Obsidian vault, reached
through the `obsidian` MCP server that every profile has. No orchestrator-held
state sits between two profiles.

```
Agents/<Profile>/Inbox/       work handed to this profile
Agents/<Profile>/Outbox/      artefacts this profile produced
Agents/Nibbler/Pipeline/      one note per opportunity (schema in nibbler/SOUL.md)
Agents/Broker/allowlist.yaml  default-deny allowlist for cross-tenant requests
Agents/Broker/Requests/       that a request was made and answered or refused —
                              never the content of the answer
Agents/Runs/lock.md           the serialisation lock
Agents/Runs/<UTC date>.md     cron run log
```

### One profile active at a time

Farnsworth is the only profile with the `cronjob` and `delegation` toolsets;
every other profile lists both in `agent.disabled_toolsets`. There is one
dispatcher, it dispatches one profile at a time, and it takes `Agents/Runs/lock.md`
before doing so. Cron runs go through the same lock as interactive work.

### Profile boundary is memory boundary

Every profile sets `MEMINI_NAMESPACE=hermes/<name>` in its own `.env`. Nothing
is shared. The namespace is set even on the profiles whose memory is disabled,
so that turning memory on later cannot land writes in someone else's namespace.

### Tenancy and the broker

Three tenants — Operata, Celestio, Life. Calendars are already separate at
source, and Operata exposes free/busy only.

Nixon is the sole holder of Operata credentials and the broker for all employer
data. Cross-tenant access starts **default-deny**: a request is refused unless
`Agents/Broker/allowlist.yaml` explicitly permits that profile to receive that
kind of data. The initial allowlist is one entry:

```yaml
# Agents/Broker/allowlist.yaml — default-deny. Absence is refusal.
- requester: leela
  data: operata-calendar-freebusy
  grain: interval and busy/free only; never subject, attendee, location or notes
```

Brokered content is in-context only for the request that asked for it. The
requesting profile must never write it to memory — stated in both Nixon's and
the requester's `SOUL.md`, since no configuration can enforce it.

Wernstrom receives only anonymised pipeline shape from Nibbler — stages and deal
sizes, never client names. Nibbler produces the anonymised view itself rather
than granting Wernstrom access and trusting it to look away.

### Remote inference

Nixon and Nibbler are local-only, enforced by construction: their `config.yaml`
defines no cloud provider at all, and their fallback and auxiliary models are
the same local one. There is no remote endpoint in those profiles for a request
to reach.

Fry and Mom are the public-content profiles and may use remote models. Everything
else defaults to local — the spec only mandates local for the two tenants, but
local is the conservative default for profiles holding personal or financial
data. Auxiliary work (compression, titling, session search) stays local in
*every* profile, including Fry and Mom: those models see the whole conversation,
so they are the widest exposure a profile has.

### Editorial independence

Morbo gates social, blog and marketing output. Development artefacts —
documentation, ADRs, commit messages — are exempt.

Independence is structural, not requested:

- **Different model.** Morbo runs local Qwen3.5-9B; Fry runs remote
  deepseek-v4-flash. Different model and different provider, so the reviewer
  cannot share the writer's blind spots.
- **Fresh context.** Morbo's `memory_enabled` is `false`, so no drafts history
  or prior review accumulates.
- **Artefact and criteria only.** Fry hands over the piece and what to judge it
  against. Not the interview notes, not the discarded drafts, not the reasoning.
  Morbo has no `delegation` toolset, so it cannot ask.

Morbo returns **findings, never a verdict** — no pass, fail, score or "ready to
ship". Human approval is the only gate in the system, and a verdict from Morbo
would quietly become that gate.

### Ingest is per-profile

Each profile reads its own sources. There is no central triage agent, and
Farnsworth is not one — it routes what it is given, it does not go looking.

### Fry wraps the writing skill

Fry's `SOUL.md` does not restate the article-writing procedure; that is the
`yann-article-writer` skill, and Fry defers to it entirely. The skill is not
vendored into this repository — it carries a 47 KB personal voice corpus that
does not belong in a GitOps repo. Install it into Fry's profile:

```console
$ kubectl -n ai cp ./yann-article-writer \
    ai/$(kubectl -n ai get pod -l app.kubernetes.io/name=hermes -o name | cut -d/ -f2):/opt/data/profiles/fry/skills/yann-article-writer -c app
```

Fry is told to stop rather than write without it.

### One Buzz identity per agent

Every profile gets its own Nostr keypair on the Buzz relay, so agents are
individually addressable rather than sharing the default agent's identity. The
private key is a secret, so it comes from Bitwarden through `hermes-profile-env`
and is appended to that profile's `.env`:

```
BUZZ_RELAY_URL="wss://buzz.<domain>"
BUZZ_PRIVATE_KEY="<the profile's own nsec or 64 hex>"
BUZZ_ALLOWED_USERS="<owner pubkey>"
```

The Bitwarden keys are one per profile, named after it:

```
HERMES_BUZZ_HOME_CHANNEL           # the default channel, shared by every agent
HERMES_BUZZ_PRIVATE_KEY            # the default agent
HERMES_BUZZ_PRIVATE_KEY_AMY
HERMES_BUZZ_PRIVATE_KEY_BENDER
HERMES_BUZZ_PRIVATE_KEY_CONRAD
HERMES_BUZZ_PRIVATE_KEY_FARNSWORTH
HERMES_BUZZ_PRIVATE_KEY_FRY
HERMES_BUZZ_PRIVATE_KEY_LEELA
HERMES_BUZZ_PRIVATE_KEY_MOM
HERMES_BUZZ_PRIVATE_KEY_MORBO
HERMES_BUZZ_PRIVATE_KEY_NIBBLER
HERMES_BUZZ_PRIVATE_KEY_NIXON
HERMES_BUZZ_PRIVATE_KEY_WERNSTROM
```

They are fetched as one ExternalSecret alongside `default.env`, deliberately
rather than as a separate Secret with its own volume: app-template 5.1.0 has no
way to mark a volume optional, so a Secret that does not exist yet would fail
the mount and take the pod down. Sharing the Secret that is already mounted
means a missing key degrades — ESO leaves the last good Secret in place, the
profile syncs without a Buzz identity and logs `no-secret` — instead of
breaking.

Every agent's fragment sets `BUZZ_HOME_CHANNEL` to the same default channel —
where cron output and notifications land — and takes its own
`HERMES_BUZZ_PRIVATE_KEY_<NAME>`. All twelve entries have to exist in Bitwarden
before this reconciles; ESO fails the whole fetch on a key that is missing.

Buzz is enabled in all eleven profiles: `require_mention: true` and
`allow_all_users: false`, with the permitted pubkey coming from
`BUZZ_ALLOWED_USERS` in the profile's own `.env` rather than `allowed_users` in
`config.yaml`, since process env outranks config and listing it in both would
leave a value in git that never takes effect.

Each profile also declares `platform_toolsets.buzz` identical to its
`platform_toolsets.cli`. Without it a Buzz session falls back to Hermes'
default toolset rather than the one the profile was given.

### Slack, on Farnsworth, Bender and Leela

Buzz reaches every profile; Slack reaches three. Farnsworth is the front door —
Slack is where a request arrives to be routed. Bender is the one whose output
you want to watch arrive, since a dispatch into Claude Code runs long. Leela is
the one you reach from a phone at the times you actually reach it: personal
admin does not wait for a terminal. The other eight stay Buzz-only.

Slack is not another Buzz. One bot token belongs to exactly one agent: Hermes
locks it on first claim and refuses the second gateway that presents it, the
same constraint that keeps the default agent's tokens off every profile. So
this is **three Slack apps**, each with its own `xoxb-` bot token and `xapp-`
app-level token, not one app shared by three agents.

The transport is Socket Mode — an outbound WebSocket from the pod. Nothing is
exposed inbound, so no profile gains a route, a container port or an
`API_SERVER_PORT`; all three keep `API_SERVER_ENABLED="false"`.

Each profile's config carries four Slack-shaped pieces, and all four are
load-bearing:

| Where | What it does |
| --- | --- |
| `platform_toolsets.slack` | The toolset a Slack session gets. Without it the session silently falls back to Hermes' default toolset rather than the profile's — the same trap as `buzz`. |
| `gateway.platforms.slack` | Enables the gateway and sets threading, unfurling and `allow_bots: none`. |
| `slack:` (top level) | Mention gating. Bender and Leela add `strict_mention` and `thread_require_mention`; Farnsworth does not, since routing a request is what it is for. |
| `display.platforms.slack` | Bender alone sets `interim_assistant_messages: true` — its terminal timeout is 1800s, and half an hour of silence reads as a dead bot. |

Bender and Leela are strict for different reasons. Bender holds the `terminal`
toolset, so the gate is about what a stray message can *start*. Leela is the
only Slack profile with `memory_enabled: true`, so the gate is about what a
channel can *deposit* — every exchange it takes part in is a write to
`hermes/leela`, and mention gating is what keeps the rest of the channel out of
that namespace. The tenancy rule in `SOUL.md` still applies underneath:
brokered Operata data is in-context only and never written to memory, and no
configuration here can enforce that.

`SLACK_ALLOWED_USERS` is deliberately **not** in any of the three
`config.yaml`s. Process env outranks config, so listing the allowlist in both
would leave a value in git that never takes effect; it comes from the profile's
own `.env` instead, exactly as `BUZZ_ALLOWED_USERS` does. It is the real gate —
channel membership is not, since the bot has to be invited to a channel before
it hears anything there.

Six new Bitwarden keys, alongside the Buzz ones:

```
HERMES_SLACK_BOT_TOKEN_FARNSWORTH   # xoxb-...
HERMES_SLACK_APP_TOKEN_FARNSWORTH   # xapp-..., Socket Mode
HERMES_SLACK_BOT_TOKEN_BENDER
HERMES_SLACK_APP_TOKEN_BENDER
HERMES_SLACK_BOT_TOKEN_LEELA
HERMES_SLACK_APP_TOKEN_LEELA
```

`SLACK_ALLOWED_USERS` is not among them — the existing key already holds the
owner's member ID, and it is the same person in every app, so all three
fragments reuse it rather than duplicating it per profile. As with the Buzz
keys, ESO fails the whole fetch on a missing key: all six have to exist in
Bitwarden before `hermes-profile-env` will reconcile again.

One thing to settle before installing: **which workspace**. The tenancy split
here is Operata, Celestio and Life, and Leela is the Life profile holding
health and household detail. Installing its app into the employer workspace
would put that data through Operata's Slack — where Operata, not you, holds the
export and retention controls. Leela belongs in a personal or Celestio
workspace. Farnsworth and Bender are less loaded but follow the same logic.

#### Creating the two Slack apps

Hermes generates the manifest itself — every slash command it implements, every
OAuth scope, every event subscription, and Socket Mode already on. Generate one
per agent, named for that agent, and keep the JSON locally to paste into Slack:

```console
$ kubectl -n ai exec deploy/hermes -c app -- \
    hermes -p farnsworth slack manifest --agent-view \
      --name Farnsworth \
      --description "Hermes orchestrator - routes work and runs scheduled jobs" \
    > farnsworth-slack-manifest.json

$ kubectl -n ai exec deploy/hermes -c app -- \
    hermes -p bender slack manifest --agent-view \
      --name Bender \
      --description "Hermes forge - dispatches into Claude Code" \
    > bender-slack-manifest.json

$ kubectl -n ai exec deploy/hermes -c app -- \
    hermes -p leela slack manifest --agent-view \
      --name Leela \
      --description "Hermes life - health, household and personal admin" \
    > leela-slack-manifest.json
```

Then, for each of the three, at <https://api.slack.com/apps>:

1. **Create New App → From an app manifest**, pick the workspace, paste the JSON.
2. **Settings → Socket Mode**: generate an app-level token with
   `connections:write`. The `xapp-` value is the `HERMES_SLACK_APP_TOKEN_*` key.
3. **Settings → Install App**: install, and copy the Bot User OAuth Token. The
   `xoxb-` value is the `HERMES_SLACK_BOT_TOKEN_*` key.
4. **Features → App Home → Show Tabs**: confirm the **Messages Tab** is on.
   Without it Slack refuses DMs to the bot whatever the scopes say.
5. Invite the bot to the channels it should hear — `/invite @Farnsworth`. It
   never joins a channel on its own.

Put the six values in Bitwarden, let Flux reconcile, and restart the three
gateways so they pick up the rewritten `.env`:

```console
$ kubectl -n ai exec deploy/hermes -c app -- sh -c \
    'for p in farnsworth bender leela; do hermes -p "$p" gateway restart; done'
```

Rerun `slack manifest` and re-paste after a Hermes upgrade adds slash commands;
Slack will prompt for a reinstall when the command set or the scopes change.

### Bringing the gateways up

Each profile's gateway is a supervised s6 service, and the boot reconciler
auto-starts only the profiles whose last recorded state was `running`. A
brand-new profile has no such state, so the first start is manual — once, ever:

```console
$ kubectl -n ai exec deploy/hermes -c app -- sh -c \
    'for p in amy bender conrad farnsworth fry leela mom morbo nibbler nixon wernstrom; do
       hermes -p "$p" gateway start
     done'
```

From then on the reconciler brings them back after every restart, and
`docker restart` semantics apply: the previously-running set is preserved.

`hermes -p <name> gateway status` reports `Manager: s6 (container supervisor)`
inside the container; `/command/s6-svstat /run/service/gateway-<name>` gives the
raw supervisor state.

This is deliberately a documented command rather than a `postStart` lifecycle
hook. app-template's values schema does not describe container-level
`lifecycle`, and an unsupported key there is silently dropped — a hook that
never runs and never says so is worse than a command you ran once and can see
the result of.

### This is twelve gateways in one pod

Enabling Buzz everywhere means twelve supervised gateway processes: the default
agent plus one per profile. Two consequences:

- **Memory.** Requests are 2 Gi and the limit 8 Gi, up from 1 Gi / 2 Gi. Usage
  tracks how many gateways are *handling a conversation*, not how many are
  running, so the limit is headroom for several active at once. Worth checking
  against node capacity.
- **Serialisation.** Farnsworth's lock serialises what Farnsworth dispatches. It
  does not serialise a direct Buzz message to an agent — with eleven addressable
  agents, two can be working at the same time if you message both.
  `allow_all_users: false` keeps that to the owner rather than opening it to the
  relay, but the "one profile active at a time" rule now holds for dispatched
  work rather than for the system as a whole. If it should hold absolutely,
  enable Buzz on Farnsworth only and reach the rest through delegation.


## Adding a profile

1. Create `app/resources/profiles/<name>/` with `config.yaml` and
   `profile.env`. `SOUL.md` is written straight onto the volume — see above.
2. Add one `configMapGenerator` entry for `hermes-profile-<name>` in
   `app/kustomization.yaml`.
3. Add one `persistence` block mounting it at `/run/config/profiles/<name>` in
   `app/helmrelease.yaml`.
4. If it needs a Buzz identity or any other credential of its own, add a
   `<name>.env` fragment to `hermes-profile-env` in `app/externalsecret.yaml`.

`profiles-init.sh` picks the directory up generically and creates `workspace/`
for the profile's `terminal.cwd`.

To give a profile its own API server it also needs a distinct `API_SERVER_PORT`,
a container port and a route. Do not hand a profile the default agent's tokens;
Hermes locks a bot token to one agent and refuses the second gateway claiming
it.

Never point two processes at one profile. Both write memory automatically and
each loads the other's writes into its system prompt, so two writers on one home
compound each other's state indefinitely. `strategy: Recreate` on the controller
is what keeps that from happening across a rollout.

## Not wired yet

The profiles are in place; four things they depend on are not, and are called
out here rather than stubbed with manifests that would fail to reconcile.

- **Operata credentials.** Nixon is declared as the sole holder of Slack, work
  mail and work calendar access, but only the `jira` MCP server (OAuth, no
  stored secret) is configured. The rest needs Bitwarden entries and an
  ExternalSecret rendering Nixon's `.env` — deliberately not created here,
  because an ExternalSecret pointing at keys that do not exist blocks the volume
  mount and the pod with it.
- **Calendars.** Leela is specified to read the personal and Celestio calendars
  directly and see Operata as free/busy only. No calendar MCP server exists in
  this repo yet, so today that constraint lives in `SOUL.md` alone.
- **Farnsworth's cron.** Hermes' scheduler runs inside a gateway process. A
  profile with no chat platform still needs its gateway started once —
  `hermes -p farnsworth gateway start` — after which the boot reconciler
  auto-starts it on subsequent restarts. Until then Farnsworth routes
  interactively but runs nothing on a schedule.
- **The `yann-article-writer` skill**, per the section above.
- **The three Slack apps.** Farnsworth's, Bender's and Leela's `config.yaml`
  enable the Slack gateway and `externalsecret.yaml` expects six token keys, but
  the apps themselves are created by hand at api.slack.com and the tokens put in
  Bitwarden — see the Slack section above. Until all six keys exist ESO fails
  the whole `hermes-profile-env` fetch and leaves the last good Secret in place,
  so the pod keeps running on the previous `.env` rather than breaking.
- **Relay membership.** `requireRelayMembership` is on, so each agent's pubkey
  has to be admitted before that agent can use the relay — see
  `kubernetes/apps/buzz/README.md`. The keys, the channel and the platform
  config are done.
- **The first `gateway start`**, per the section above. One command, once.
- **SOUL.md for each profile**, placed on the volume at
  `/opt/data/profiles/<name>/SOUL.md`. A profile with no `SOUL.md` runs on
  Hermes' default persona, which for these eleven is not the intent.
