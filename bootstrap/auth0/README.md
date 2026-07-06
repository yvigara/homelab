# `bootstrap/auth0` — Auth0 tenant configuration (Terraform)

Provisions the Auth0 objects that make Auth0 the cluster's Authorization Server for
**MCP** (and, going forward, the Hermes dashboard SSO — replacing Dex):

- **Custom domain** `auth.<domain>` (`auth0_managed_certs`) with the verification CNAME
  created in Cloudflare — Auth0 becomes the issuer `https://auth.<domain>/`.
- **Dynamic Client Registration** enabled tenant-wide (`/oidc/register`) for MCP clients.
- **GitHub** social connection, reusing the existing OAuth App creds (`DEX_GITHUB_CLIENT_ID/SECRET`).
- **MCP API** (`auth0_resource_server`, audience `https://mcp.<domain>/mcp`, RS256, scope `mcp:invoke`).
- **Hermes dashboard** app (regular web, auth-code + PKCE) and **Hermes MCP** app
  (`client_credentials`) + a client grant to the MCP API.
- **Post-login Action** restricting sign-in to members of the `celest-io` GitHub org
  (replaces Dex's native `orgs:` gate). Code in `actions/github-org-gate.js`.

Generated app credentials are written back to **Bitwarden Secrets Manager**
(`AUTH0_HERMES_DASHBOARD_CLIENT_ID/SECRET`, `AUTH0_HERMES_MCP_CLIENT_ID/SECRET`) so the
cluster consumes them later via ExternalSecrets. State is **local** (gitignored); commit
`.terraform.lock.hcl`.

## Prerequisites (one-time, manual)

1. **Auth0 tenant** dedicated to this cluster, plus a **Machine-to-Machine app authorized for
   the Auth0 Management API** (all scopes needed to manage clients, connections, resource
   servers, actions, custom domains, tenant settings).
2. Add its credentials to `fnox.toml` (age-encrypted) so `mise`/`fnox` export them as the
   env vars the provider reads:
   - `AUTH0_DOMAIN`  (the tenant canonical domain, e.g. `your-tenant.eu.auth0.com`)
   - `AUTH0_CLIENT_ID`
   - `AUTH0_CLIENT_SECRET`
3. Add the Auth0 callback to the **existing GitHub OAuth App** (OAuth Apps allow multiple
   callback URLs — keep the Dex one until cutover):
   `https://auth.<domain>/login/callback`
4. Ensure the Bitwarden keys `DEX_GITHUB_CLIENT_ID` and `DEX_GITHUB_CLIENT_SECRET` exist
   (they already do — reused from the Dex setup).

All Terraform inputs (`bw_project_id`, `bw_organization_id`, `domain`, `cluster_env`,
`cluster_region`) are already exported as `TF_VAR_*` by `mise.toml`; `github_org` defaults to
`celest-io`.

## Run

```sh
cd bootstrap/auth0
terraform init
terraform apply
```

The custom-domain verification can take a few minutes; the `auth0_custom_domain_verification`
resource waits (up to 15m) for the Cloudflare CNAME to propagate.

## Verify

- `terraform apply` clean; commit the resolved `.terraform.lock.hcl`.
- Auth0 shows the MCP API, both Hermes apps, the GitHub connection, DCR enabled, and the custom
  domain **Verified**.
- `curl https://auth.<domain>/.well-known/openid-configuration` returns metadata containing
  `registration_endpoint` and `jwks_uri`.
- A `client_credentials` token for the Hermes MCP app has `aud = https://mcp.<domain>/mcp`.
- Signing in as a non-`celest-io` GitHub user is denied by the org-gate Action.

## Notes

- **Third-party (DCR) access to the MCP API**: DCR clients are third-party apps. Confirm in the
  Auth0 dashboard that the MCP API allows the `mcp:invoke` scope to be requested by third-party
  applications (and configure default third-party permissions if your tenant requires it). The
  tenant DCR flag itself is managed here.
- **`auth0_tenant`** manages tenant-wide flags — intended for a tenant dedicated to this cluster.
- Phase B (separate change) points AgentGateway's `mcpAuthentication` at
  `issuer: https://auth.<domain>/`, `jwks.url: https://auth.<domain>/.well-known/jwks.json`,
  `audiences: [https://mcp.<domain>/mcp]`, and switches Hermes to the M2M `client_credentials` app.
