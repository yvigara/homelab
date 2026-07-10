# AgentGateway MCP endpoint (Phase B)

Exposes multiple MCP servers behind **one public endpoint** (`https://mcp.${DOMAIN}/mcp`) with
auth delegated entirely to AgentGateway, validating **Auth0**-issued JWTs. Stacks on the Auth0
Terraform (`bootstrap/auth0/`).

## Pieces

| File | What |
|------|------|
| `../../../agentgateway-system/agentgateway/app/gateway.yaml` | adds an isolated `mcp` listener (:8080); Ollama `:80` untouched |
| `mcp-backends.yaml` | `AgentgatewayBackend` (`spec.mcp`) multiplexing MCP targets + gateway-side Auth0 `authentication`; `HTTPRoute` → `mcp` listener, path `/mcp` |
| `mcp-httproute-public.yaml` | Traefik-public route `mcp.${DOMAIN}` → `agentgateway-proxy:8080` + `ReferenceGrant` |

Flow: Cloudflare tunnel → traefik-public → `agentgateway-proxy` `mcp` listener → multiplexed MCP
backends. Clients discover Auth0 via Protected Resource Metadata, **DCR** against Auth0, and log in
with GitHub (`celest-io`, enforced by the Auth0 Action). Hermes will use the Auth0 M2M
`client_credentials` app — no k8s ServiceAccount token (wiring pending, see item 3 below).

## ⚠️ Confirm against the running cluster before relying on this

Authored without access to the AgentGateway v1.3 docs (proxy-blocked) or the cluster:

1. **AgentGateway MCP CRD shape** — verify how `spec.mcp` targets and `authentication` are
   expressed in the installed v1.3 CRDs:
   ```
   kubectl explain agentgatewaybackend.spec.mcp
   kubectl explain agentgatewaybackend.spec.mcp.authentication
   ```
   Confirm target fields (host/port vs Service ref, streamable-HTTP protocol) and whether MCP
   auth lives on the backend (as here) or a separate policy CRD on the `mcp` listener. The
   `authentication` **content** (issuer/jwks/audiences/resourceMetadata) is stable.
2. **MCP servers** — the first protected server is the in-cluster **searxng** MCP server
   (`kubernetes/apps/ai/searxng/mcp`, Service `mcp-searxng:3000`, path `/mcp`). Add more entries to
   `spec.mcp.targets` in `mcp-backends.yaml` to multiplex additional servers behind the same endpoint.
3. **Hermes MCP client — pending, not wired here.** The M2M client is `AUTH0_MCP_CLIENT_ID` in
   Bitwarden, but its **client secret write-back is commented out** in `bootstrap/auth0/secrets.tf`,
   so it isn't in the store yet. Before wiring: (i) enable that write-back (or add the secret to
   Bitwarden), (ii) add `AUTH0_MCP_CLIENT_ID`/`AUTH0_MCP_CLIENT_SECRET` to the Hermes `ExternalSecret`,
   (iii) set `mcp_servers` in `../../hermes/app/resources/config.yaml` once Hermes' MCP-client auth
   schema is confirmed (client_credentials vs static bearer). Endpoint: `https://mcp.${DOMAIN}/mcp`.

> Note: the token **audience** (`https://mcp.${DOMAIN}`, no path) equals the Auth0 API identifier in
> `bootstrap/auth0`; the endpoint URL path stays `/mcp`. These are intentionally different.

## Verify

- `curl https://mcp.${DOMAIN}/.well-known/oauth-protected-resource` → PRM pointing at Auth0.
- Unauthenticated `/mcp` → `401` + `WWW-Authenticate`.
- MCP Inspector against `https://mcp.${DOMAIN}/mcp` → DCR + GitHub login → `tools/list` shows tools
  from multiple backends.
- Ollama is unreachable on `mcp.${DOMAIN}` and unchanged on its internal path.
