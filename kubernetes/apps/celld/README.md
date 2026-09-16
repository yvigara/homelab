# celld

A self-hosted [celld](https://celld.dev) fleet — Cloudflare Workers and Durable
Objects on this cluster's own hardware. Each object is a *cell*: a named server
with its own SQLite database. One Rust binary is the whole runtime; there is no
control plane and no consensus service, because the bucket *is* the coordinator.
Ownership of a cell is a record in the bucket, claimed with one atomic
conditional write.

| Piece | Where it comes from |
| --- | --- |
| Fleet | `fleet/` — upstream image `ghcr.io/denoland/celld` |
| Object store | RustFS in the `storage` namespace, bucket `celld` |
| Local node state | One `openebs-hostpath` PVC per node, at `/var/lib/celld` |

The Worker listener is private, at `https://celld.int.<region>.<env>.<domain>`
through the `traefik-private` gateway. It is not on the Cloudflare tunnel: an
empty fleet serves whatever the current deployment serves, and until that is
something you chose deliberately, it should not be reachable from the internet.
Moving it out is the same change the buzz relay already carries — a
`traefik-public` parentRef plus the `cloudflare-proxied` external-dns
annotation, which needs its own `httproute.yaml` because the chart's `route`
values render no annotations.

## Object storage

celld keeps everything durable in the bucket: the deployments, the SQLite
replicas as LTX segments, the ownership records, the node leases, and the
fleet's peer-authentication secret. It reaches RustFS at
`https://s3.int.<region>.<env>.<domain>` with the RustFS root credentials —
the same `RUSTFS_ROOT_USER` / `RUSTFS_ROOT_PASSWORD` pair RustFS and the buzz
relay read. A scoped access key is two template lines in
`fleet/app/externalsecret.yaml` once RustFS grows declarative IAM users here.
Treat the bucket credentials as fleet administrator access; they are enough to
own every cell.

RustFS does not create buckets on demand, so an init container creates `celld`
before the node starts, the same way the buzz relay creates `buzz-media`.

**The store has to offer linearizable conditional writes**, because the
ownership records are what keeps two nodes from serving one cell. Upstream
qualifies Amazon S3, R2, GCS, Tigris and Azure Blob Storage, and explicitly
does *not* list RustFS — MinIO passes the same test but is unqualified, and
B2, Hetzner and DigitalOcean Spaces fail it outright. So this is the one real
risk in this deployment, and it is deliberately not papered over:

- celld races a conditional-write test at every startup and refuses to serve if
  the store loses it, naming the reason. A RustFS that cannot do this shows up
  as a pod that will not start, not as two nodes quietly owning one cell.
- The evidence is good but indirect: the buzz relay already gates its own
  startup on a probe that races 32 concurrent `If-Match` updates against one
  key on this same RustFS, and passes.
- `CELLD_STORAGE_PROBE=0` skips the startup test. Do not set it. The protocol
  is unsound without the guarantee the probe is checking, and skipping the
  check does not supply it.

## One node, and what that costs

This cluster is a single machine, so the fleet is a single node, and two things
follow that are worth knowing before you rely on it.

**Writes are slower.** With two or more nodes, a write is durable as soon as a
peer holds it on disk — roughly 25 ms in upstream's lab. A single node has
nobody to send to, so every write waits for the bucket instead: about 90 ms to
a region-local store. celld reports this at startup (`fleet durability
requested and no peer is available`). The `CELLD_DURABILITY` default handles
the fallback on its own; there is nothing to configure.

**A second replica would not buy durability here.** Two pods on one machine
would ack each other's writes from the same physical disk, which reads as
fleet durability while being nothing of the sort. Scale `replicas` past 1 when
there is a second machine to schedule onto — the StatefulSet is already shaped
for it, with a per-pod PVC and a per-pod advertised address — and not before.

Restarts are not free either: a node with no peer to hand its cells to drains
for the full `CELLD_SHUTDOWN_DRAIN_MS` no-progress interval, about 25 seconds,
before it stops. `terminationGracePeriodSeconds` is 120 to cover that plus the
drain-token wait and the process stop bound. Shortening it means SIGKILL in the
middle of a handoff.

## The two listeners

celld binds two listeners, and the split is a security boundary, not a
convenience:

- **Public (8080)** — the Worker listener, the only one behind the Gateway. It
  reserves exactly one path, `/.well-known/celld/health`; the deployment owns
  everything else.
- **Internal (8081)** — peer traffic *and* an unauthenticated operator API that
  accepts state inspection, cell eviction and node shutdown. It is bound to the
  pod IP and published only through the headless `celld-peer` Service. It must
  never reach a Gateway, and celld terminates no TLS of its own, so the pod
  network is the boundary that protects it.

Peers find each other through bucket leases, but they still have to *reach* the
address a lease names, which is why `CELLD_ADVERTISE` is the pod's own stable
DNS name (`celld-0.celld-peer.celld.svc.cluster.local`) rather than the
Service's. That name only exists because `celld-peer` is the StatefulSet's
governing headless Service.

The liveness probe is a TCP check rather than the health path on purpose: the
health path answers 503 for the whole drain, and a liveness probe reading that
would SIGKILL a node in the middle of handing its cells off.

## The bootstrap application

A fleet runs one application, and **celld loads `deploy/current.json` at boot
and exits when it is missing** — an empty bucket is a crash loop, not an idle
fleet.

That last part is observed, not documented. Upstream says only that "every node
loads its latest successfully committed deployment from `deploy/current.json`",
and implies the ordering by putting *Deploy an application* before *Start a
node*; it never says what a node does when the pointer is absent. Pointing
celld 0.4.0 at an empty bucket answers it:

```console
$ celld --bucket s3://emptyfleet --endpoint ... --listen 0.0.0.0:8080 ...
Error: read s3://emptyfleet/deploy/current.json: no such key
$ echo $?
1
```

So this directory ships a minimal application in `fleet/app/resources/`,
published by an init container the first time the fleet comes up:

- `GET /` reports that the fleet is serving.
- `GET /count?name=<cell>` increments a per-cell counter, which exercises a
  Durable Object, its SQLite database and the replication path into RustFS in
  one request.

It is deployed **once**. The init container checks the bucket for a deployment
pointer and stands down if one is there, so a pod restart never overwrites what
you deployed later. If the bucket cannot be read at all, the pod stops rather
than guessing — an unreadable store is not the same answer as an empty one.

`celld deploy` normally shells out to esbuild, which the release image does not
carry, so the bootstrap sets `no_bundle: true` and stays a single file with no
imports. Anything more than a smoke test should be deployed properly:

```sh
export CELLD_BUCKET=s3://celld
export S3_ENDPOINT=https://s3.int.<region>.<env>.<domain>
export AWS_REGION=us-east-1
export AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=...   # RustFS root creds

celld deploy .
```

Nodes adopt a new deployment in place at their next pointer poll — 30 seconds
by default — without restarting, so replacing the bootstrap does not need a
Flux change or a pod roll. Once you do, this repo is no longer the source of
truth for what the fleet serves; the bucket is.

## Configuration and secrets

Nothing here carries a value to be edited by hand. `${REGION}`,
`${ENVIRONMENT}`, `${DOMAIN}` and `${TIMEZONE}` arrive through Flux post-build
substitution. The credentials come from Bitwarden through External Secrets, and
both keys already exist for RustFS:

| Key | What |
| --- | --- |
| `RUSTFS_ROOT_USER`, `RUSTFS_ROOT_PASSWORD` | RustFS root credentials, presented to celld as `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` |

## Operating it

The CLI talks to the fleet through the bucket, so it works from anywhere the
bucket does — no cluster access needed, with `CELLD_BUCKET`, `S3_ENDPOINT`,
`AWS_REGION` and the credentials set as above:

```sh
celld diagnose             # every node lease, then a signed probe of each peer
celld cell list            # the Durable Object instances in the fleet
celld d1 migrations apply <db>
celld kv bulk put <namespace> <wrangler-export.json>
celld queue info <queue>
```

`GET /state` on the internal listener reports the node's live counters — the
deployment it serves, resident cells, handoff and restore progress, and the
four memory measurements behind its shedding decisions.

## Backups

The bucket is the fleet. It holds every cell's durable state, the deployments,
and `fleet/peer-auth.json`; back up the `celld` bucket in RustFS and the fleet
survives losing this cluster. The per-node PVC is a local working copy of state
that already lives there, and can be lost without losing data — a replacement
node recovers from the bucket.

## Upgrades

Check the release notes before bumping the image: celld has already shipped
three upgrades that forbid a rolling update (0.1→0.2, 0.3→0.4) or that change
the durability default (0.2.1→0.3.0). A single-node fleet stops and starts
anyway, which satisfies the stop-all-then-start-all requirement, but a
multi-node fleet would not.
