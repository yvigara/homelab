# mcp

MCP servers behind agentgateway, published at `https://mcp.${DOMAIN}/mcp`.

| Backend target | Where it runs |
| --- | --- |
| `searxng` | `mcp-searxng` in this namespace |
| `linkedin` | `${OLLAMA_SRV1_IP}:9080` |
| `memini` | `memini.ai.svc.cluster.local:8080`, bearer from the `memini` secret |
| `obsidian` | `${OLLAMA_SRV1_IP}:27124`, bearer from the `obsidian-mcp` secret (Bitwarden `OBSIDIAN_API_KEY`); read and write |
| `konflate` | `konflate.flux-system:8080/mcp`, rendered Flux diffs for open PRs (read-only) |
| `radar` | `radar.radar:9280/mcp-readonly`; Radar runs with `--mcp-read-only` |
| `flux` | `flux-operator-mcp.flux-system:9090/mcp`; `readonly: true`, `view` RBAC |

The backend uses `failureMode: FailOpen`: a target that is down or rejects a call is
skipped and the rest keep working. Without it one dead target fails `initialize` for
all of them. A skipped target is silent, so check the gateway logs if a server's
tools go missing.

## Authentication

`mcp.${DOMAIN}` is protected by **Cloudflare Access with Managed OAuth**. There is
no auth policy in agentgateway.

```
Claude Web ── OAuth (DCR, PKCE) ──► Cloudflare Access ──► cloudflared ──► traefik ──► agentgateway
                                      │ policy: you        │ validates Cf-Access-Jwt-Assertion
                                      └ IdP login          └ teamName + audTag from Bitwarden
```

- Access is the OAuth authorization server. Clients receive an opaque token; the
  origin only ever sees the signed `Cf-Access-Jwt-Assertion` header.
- cloudflared enforces `access.required` for this hostname, so a request that
  reaches the tunnel without a valid Access JWT is refused rather than served.
- agentgateway cannot do this check itself: it reads JWTs from `Authorization`,
  which carries the opaque token here.
- `mcp.int.${REGION}.${ENVIRONMENT}.${DOMAIN}` (private) and the in-cluster
  `agentgateway-proxy-int` service are **not** authenticated; they are only
  reachable from the LAN and the cluster.

The Access application is configured by hand in the Zero Trust dashboard (Access
is not managed in this repo):

1. **Access controls → Applications → Add → Self-hosted.** Name `mcp`, public
   hostname `mcp.${DOMAIN}` (no path), an Allow policy for yourself.
2. **Advanced settings → Managed OAuth: on.** Allowed redirect URIs:
   `https://claude.ai/api/mcp/auth_callback`. Access token lifetime `15m`, grant
   session `2 weeks`.
3. Copy the application's **AUD tag** and your **team name** (the part before
   `.cloudflareaccess.com`).
4. Store them in Bitwarden Secrets Manager as `CF_ACCESS_TEAM_NAME` and
   `CF_ACCESS_MCP_AUD`. They feed the `cloudflare-tunnel-config` ExternalSecret.

Create the two Bitwarden secrets **before** merging a change to the tunnel: the
cloudflared pod mounts the rendered Secret, and a rollout without it stays
pending while the old pod keeps serving.

If the Access application is recreated, its AUD changes; update
`CF_ACCESS_MCP_AUD` and the tunnel restarts (reloader).

## Connecting

Claude Web: **Customize → Connectors → Add custom connector**, URL
`https://mcp.${DOMAIN}/mcp`. Team/Enterprise: an owner adds it under
**Organization settings → Connectors**.

Quick check without a browser, using an Access service token (add a Service Auth
policy for it on the application):

```sh
curl -s https://mcp.${DOMAIN}/mcp \
  -H "CF-Access-Client-Id: $ID" -H "CF-Access-Client-Secret: $SECRET" \
  -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" \
  --data '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}'
```

Unauthenticated, the same request returns `401` with a `WWW-Authenticate` header
pointing at Access's resource metadata. A `302` means Managed OAuth is off.

## Leftovers

`bootstrap/auth0` still defines the MCP API (`auth0_resource_server.mcp`), its scope,
the `MCP Client` M2M app and its grant. Nothing in the cluster uses them any more;
remove them in a separate change once Access is confirmed working.
