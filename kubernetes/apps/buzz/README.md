# buzz

A self-hosted [Buzz](https://github.com/block/buzz) relay — Block's Nostr-based
workspace for humans and agents. One Rust binary serves the WebSocket relay, the
REST API and the web UI; it needs Postgres, Redis and an S3-compatible object
store behind it.

| Piece | Where it comes from |
| --- | --- |
| Relay | `relay/` — upstream chart `oci://ghcr.io/block/buzz/charts/buzz` |
| Object store | `minio/` — a MinIO dedicated to this namespace, bucket `buzz-media` |
| Postgres | Shared CNPG cluster; database/role in `kubernetes/apps/database/cnpg/postgres/db-buzz.yaml` |
| Redis | Shared Dragonfly at `dragonfly.database.svc:6379` |

The relay is reachable on the LAN only, at
`wss://buzz.int.<region>.<environment>.<domain>`, through the `traefik-private`
gateway. To publish it, point the `httproute` values in
`relay/app/helmrelease.yaml` at `traefik-public` and update `relayUrl` and
`relay.corsOrigins` to match — note that the public gateway runs over a
Cloudflare tunnel, whose request body limit is below the relay's 500 MiB
`git.maxPackBytes` default.

## Before this reconciles cleanly

**Owner pubkey.** `BUZZ_OWNER_PUBKEY` in `cluster-vars.yaml` is a placeholder of
64 zeroes. Buzz is closed-membership: this pubkey is the operator account, the
one member that cannot be removed. Replace it with the real 64-character
lowercase hex pubkey (not an `npub`) before the relay is of any use. The chart
fails to render on anything that is not 64 hex characters.

**Bitwarden Secrets Manager entries.** Both ExternalSecrets read these; create
them first, and back up the first two — losing either is unrecoverable.

| Key | What |
| --- | --- |
| `BUZZ_RELAY_PRIVATE_KEY` | 64 hex chars. The relay's own Nostr identity; rotating it makes it a different relay. |
| `BUZZ_GIT_HOOK_HMAC_SECRET` | 64 random chars. |
| `BUZZ_PG_PASSWORD` | Password for the `buzz` Postgres role. |
| `BUZZ_S3_ACCESS_KEY` | MinIO root user, also the relay's S3 access key. Minimum 3 characters. |
| `BUZZ_S3_SECRET_KEY` | MinIO root password, also the relay's S3 secret key. Minimum 8 characters. |

## Backups

The relay's Postgres database is the canonical event store, the `buzz-media`
bucket holds every uploaded blob, and `BUZZ_RELAY_PRIVATE_KEY` is the relay's
identity. The git PVC is scratch space — repos are hydrated from the object
store per request — and can be lost without data loss.
