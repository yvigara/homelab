locals {
  auth_domain     = "auth.${var.domain}"           # custom-domain issuer host
  mcp_audience    = "https://mcp.${var.domain}/mcp" # MCP API identifier (token aud)
  hermes_dash_url = "https://hermes.int.${var.cluster_region}.${var.cluster_env}.${var.domain}"
}

# --- Tenant ------------------------------------------------------------------
# Enable Dynamic Client Registration so MCP clients can self-register at
# POST /oidc/register. NOTE: this manages tenant-wide flags; intended for a
# freshly provisioned Auth0 tenant dedicated to this cluster.
resource "auth0_tenant" "this" {
  flags {
    enable_dynamic_client_registration = true
  }
}

# --- Custom domain (auth.<domain>) -------------------------------------------
resource "auth0_custom_domain" "auth" {
  domain     = local.auth_domain
  type       = "auth0_managed_certs"
  tls_policy = "recommended"
}

data "cloudflare_zone" "main" {
  filter = {
    name = var.domain
  }
}

# Verification CNAME must be DNS-only (unproxied) so Auth0 can serve the cert.
resource "cloudflare_dns_record" "auth0_verification" {
  zone_id = data.cloudflare_zone.main.id
  name    = auth0_custom_domain.auth.verification[0].methods[0].domain
  type    = upper(auth0_custom_domain.auth.verification[0].methods[0].name)
  content = auth0_custom_domain.auth.verification[0].methods[0].record
  ttl     = 1
  proxied = false
}

resource "auth0_custom_domain_verification" "auth" {
  depends_on       = [cloudflare_dns_record.auth0_verification]
  custom_domain_id = auth0_custom_domain.auth.id

  timeouts {
    create = "15m"
  }
}

# --- GitHub connection (reuses the existing OAuth App) -----------------------
# Domain-level so it is also available to third-party DCR clients.
resource "auth0_connection" "github" {
  name                 = "github"
  strategy             = "github"
  is_domain_connection = true

  options {
    client_id     = data.bitwarden-secrets_secret.github_client_id.value
    client_secret = data.bitwarden-secrets_secret.github_client_secret.value
    scopes        = ["email", "read_org"]
  }
}

# --- MCP API (resource server) -----------------------------------------------
resource "auth0_resource_server" "mcp" {
  name        = "MCP Gateway API"
  identifier  = local.mcp_audience
  signing_alg = "RS256"

  allow_offline_access                            = true
  token_lifetime                                  = 3600
  skip_consent_for_verifiable_first_party_clients = true
}

resource "auth0_resource_server_scopes" "mcp" {
  resource_server_identifier = auth0_resource_server.mcp.identifier

  scopes {
    name        = "mcp:invoke"
    description = "Invoke MCP tools through the gateway"
  }
}

# --- Applications ------------------------------------------------------------
# Hermes dashboard: browser SSO (authorization code + PKCE).
resource "auth0_client" "hermes_dashboard" {
  name            = "Hermes Dashboard"
  app_type        = "regular_web"
  oidc_conformant = true
  is_first_party  = true

  callbacks           = ["${local.hermes_dash_url}/auth/callback"]
  allowed_logout_urls = [local.hermes_dash_url]
  web_origins         = [local.hermes_dash_url]

  grant_types = ["authorization_code", "refresh_token"]
}

# Hermes MCP client: headless machine-to-machine (client_credentials).
resource "auth0_client" "hermes_mcp" {
  name            = "Hermes MCP Client"
  app_type        = "non_interactive"
  oidc_conformant = true
  is_first_party  = true

  grant_types = ["client_credentials"]
}

# Enable the GitHub connection for the dashboard app.
resource "auth0_connection_clients" "github" {
  connection_id   = auth0_connection.github.id
  enabled_clients = [auth0_client.hermes_dashboard.id]
}

# Grant the Hermes MCP client access to the MCP API.
resource "auth0_client_grant" "hermes_mcp" {
  client_id = auth0_client.hermes_mcp.id
  audience  = auth0_resource_server.mcp.identifier
  scopes    = ["mcp:invoke"]
}

# --- Org gate Action ---------------------------------------------------------
resource "auth0_action" "github_org_gate" {
  name    = "GitHub Org Gate"
  runtime = "node22"
  deploy  = true
  code    = file("${path.module}/actions/github-org-gate.js")

  secrets {
    name  = "GITHUB_ORG"
    value = var.github_org
  }

  supported_triggers {
    id      = "post-login"
    version = "v3"
  }
}

resource "auth0_trigger_actions" "post_login" {
  trigger = "post-login"

  actions {
    id           = auth0_action.github_org_gate.id
    display_name = auth0_action.github_org_gate.name
  }
}
