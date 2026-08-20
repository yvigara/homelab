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

The relay is public, at `wss://buzz.<domain>`, through the `traefik-public`
gateway and the Cloudflare tunnel. `relay/app/httproute.yaml` holds the route
rather than the chart's `httproute` values, because that template renders no
annotations and external-dns needs `cloudflare-proxied` to point the record at
the tunnel. `relayUrl` and `relay.corsOrigins` follow the same hostname; NIP-42
auth challenges bind to it, so there is one hostname and no split-horizon
second route.

Public does not mean open: `requireRelayMembership` and `requireAuthToken` are
on, so only the owner and members the owner admits can use the relay.

Two things follow from being behind Cloudflare:

- **Request body limit.** Cloudflare caps proxied request bodies (100 MB on
  Free and Pro), well under the relay's 500 MiB `git.maxPackBytes` default. A
  git push above the cap is rejected at the edge, not by the relay. Lower
  `git.maxPackBytes` to sit under whatever the plan allows if large pushes
  matter.
- **Client addresses.** Buzz never records the network address of an upload
  unless `relay.uploadRecords` and `relay.uploadIpHeader` are set; behind this
  tunnel the header would be `cf-connecting-ip`. Whether to record it is an
  operator decision — upstream flags it for anyone hosting a community for
  other people.

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

## Configuration and secrets

Nothing in this directory carries a value that has to be edited by hand.

`${DOMAIN}` and `${BUZZ_OWNER_PUBKEY}` arrive through Flux post-build
substitution. `BUZZ_OWNER_PUBKEY` is the operator's Nostr public key — Buzz is
closed-membership and this is the one account that cannot be removed — and it
reaches the cluster from Bitwarden via `bootstrap/fluxcd/secrets.tf`, which
puts it in `cluster-secrets`. The chart hard-fails rendering on anything that
is not 64 lowercase hex characters, so a substitution that silently resolves
to empty shows up as a failed HelmRelease rather than a running relay.

The rest come from Bitwarden through External Secrets:

| Key | What |
| --- | --- |
| `BUZZ_RELAY_PRIVATE_KEY` | 64 hex chars. The relay's own Nostr identity; rotating it makes it a different relay. |
| `BUZZ_GIT_HOOK_HMAC_SECRET` | 64 hex chars, generated in `bootstrap/fluxcd/buzz.tf`. |
| `BUZZ_PG_PASSWORD` | Password for the `buzz` Postgres role. |
| `RUSTFS_ROOT_USER`, `RUSTFS_ROOT_PASSWORD` | Already required by RustFS; the relay reuses them. |

## Backups

The relay's Postgres database is the canonical event store, the `buzz-media`
bucket holds every uploaded blob, and `BUZZ_RELAY_PRIVATE_KEY` is the relay's
identity. The git PVC is scratch space — repos are hydrated from the object
store per request — and can be lost without data loss.
