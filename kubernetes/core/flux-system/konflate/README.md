# konflate

Rendered Flux diffs for every open PR, with an MCP endpoint (`/mcp`) that is also reached
through agentgateway (`kubernetes/apps/ai/mcp`).

## Who can reach what

`https://konflate-${CLUSTER_NAME}.${DOMAIN}` is public and proxied, so it is split in two:

| Path | Access | Enforced by |
| --- | --- | --- |
| `POST /hooks` | public | GitHub's HMAC signature (`KONFLATE_WEBHOOK_SECRET`); returns 501 if unset |
| everything else (UI, `/api`, `/ws`, `/mcp`) | Cloudflare Access login | Access at the edge, then cloudflared (`access.required`) |

cloudflared (kubernetes/core/network/cloudflare-tunnel) has two rules for the host: `/hooks` first with no
check, then the whole hostname requiring the Access JWT. A request that skips Access is
refused at the tunnel instead of served, which also covers the Access app being deleted.

Cloudflare side, configured by hand in Zero Trust:

1. **Applications → Add → Self-hosted**, name `konflate`, hostname `konflate-${CLUSTER_NAME}.${DOMAIN}` (no path),
   Allow policy for yourself. Copy its **AUD tag** into Bitwarden as `CF_ACCESS_KONFLATE_AUD`.
2. A second self-hosted app, `konflate-hooks`, same hostname with path `hooks`, one **Bypass** policy
   (Everyone). The more specific path wins, so GitHub can post without a login.
3. The GitHub webhook points at `https://konflate-${CLUSTER_NAME}.${DOMAIN}/hooks`, events `pull_request`,
   `check_run`, `check_suite`.

Create both apps and the Bitwarden secret **before** merging a tunnel change; with the secret
missing the new cloudflared pod stays pending and the old one keeps serving.

## Render inputs

konflate renders the cluster without cluster access, so objects created outside git are missing:
`flux-runtime-info` (terraform bootstrap) and `cluster-secrets`. `app/render-stubs.yaml` supplies fake
stand-ins, mounted at `/etc/konflate/stubs` and passed to flate with `FLATE_SUBSTITUTE_FROM`.
The values only need to exist so `${VAR}` expands identically on both sides of a diff.

If a PR still reports `dependency not found: ConfigMap/flux-system/flux-runtime-info`, konflate
is not forwarding the env var to flate; it would need a supply option upstream. When
terraform adds a key to either object, add a fake for it here.
