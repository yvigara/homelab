# buzz

A self-hosted [Buzz](https://github.com/block/buzz) relay — Block's Nostr-based
workspace for humans and agents. One Rust binary serves the WebSocket relay, the
REST API and the web UI; it needs Postgres, Redis and an S3-compatible object
store behind it.

| Piece | Where it comes from |
| --- | --- |
| Relay | `relay/` — upstream chart `oci://ghcr.io/block/buzz/charts/buzz` |
| Object store | RustFS at `rustfs.storage.svc.cluster.local:9000`, bucket `buzz-media` |
| Postgres | Shared CNPG cluster; database/role in `kubernetes/apps/database/cnpg/postgres/db-buzz.yaml` |
| Redis | Shared Dragonfly at `dragonfly.database.svc:6379` |

The relay is reachable on the LAN only, at
`wss://buzz.int.<region>.<environment>.<domain>`, through the `traefik-private`
gateway. To publish it, point the `httproute` values in
`relay/app/helmrelease.yaml` at `traefik-public` and update `relayUrl` and
`relay.corsOrigins` to match — note that the public gateway runs over a
Cloudflare tunnel, whose request body limit is below the relay's 500 MiB
`git.maxPackBytes` default.

## Object storage

The relay talks to RustFS in the `storage` namespace with its root credentials,
the same `RUSTFS_ROOT_USER` / `RUSTFS_ROOT_PASSWORD` pair RustFS itself reads.
Swapping in a scoped access key is a matter of changing the two template lines
in `relay/app/externalsecret.yaml` once RustFS grows declarative IAM users here.

Buzz keeps git ref state in object storage and serializes writers with a
pointer compare-and-swap, so it gates startup on a conformance probe that races
32 concurrent `If-Match` updates against one key. A backend without linearizable
conditional writes fails that probe and the relay exits — deliberately, since
the manifest-pointer protocol is unsound without it.

## Before this reconciles cleanly

**Owner pubkey.** `BUZZ_OWNER_PUBKEY` in `cluster-vars.yaml` is a placeholder of
64 zeroes. Buzz is closed-membership: this pubkey is the operator account, the
one member that cannot be removed. Replace it with the real 64-character
lowercase hex pubkey (not an `npub`) before the relay is of any use. The chart
fails to render on anything that is not 64 hex characters.

**Bitwarden Secrets Manager entries.** Back up the first two — losing either is
unrecoverable.

| Key | What |
| --- | --- |
| `BUZZ_RELAY_PRIVATE_KEY` | 64 hex chars. The relay's own Nostr identity; rotating it makes it a different relay. |
| `BUZZ_GIT_HOOK_HMAC_SECRET` | 64 random chars. |
| `BUZZ_PG_PASSWORD` | Password for the `buzz` Postgres role. |
| `RUSTFS_ROOT_USER`, `RUSTFS_ROOT_PASSWORD` | Already required by RustFS; the relay reuses them. |

## Backups

The relay's Postgres database is the canonical event store, the `buzz-media`
bucket holds every uploaded blob, and `BUZZ_RELAY_PRIVATE_KEY` is the relay's
identity. The git PVC is scratch space — repos are hydrated from the object
store per request — and can be lost without data loss.
