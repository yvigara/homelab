# Read existing secrets from Bitwarden Secrets Manager (same idiom as bootstrap/fluxcd).
data "bitwarden-secrets_list_secrets" "secrets" {}

locals {
  bw_secrets = { for s in data.bitwarden-secrets_list_secrets.secrets.secrets : s.key => s.id }
}

# Reused GitHub OAuth App credentials (originally provisioned for Dex).
data "bitwarden-secrets_secret" "github_client_id" {
  id = local.bw_secrets["AUTH0_GITHUB_CLIENT_ID"]
}

data "bitwarden-secrets_secret" "github_client_secret" {
  id = local.bw_secrets["AUTH0_GITHUB_CLIENT_SECRET"]
}

# Google Workspace OAuth client (Google Cloud console, type "Web application").
data "bitwarden-secrets_secret" "google_client_id" {
  id = local.bw_secrets["AUTH0_GOOGLE_CLIENT_ID"]
}

data "bitwarden-secrets_secret" "google_client_secret" {
  id = local.bw_secrets["AUTH0_GOOGLE_CLIENT_SECRET"]
}

# Bare Workspace domain (e.g. celest.io). Shared with the Dex google connector.
data "bitwarden-secrets_secret" "google_workspace_domain" {
  id = local.bw_secrets["GOOGLE_WORKSPACE_DOMAIN"]
}

# Publish the Auth0 application credentials back to Bitwarden so External Secrets
# Operator can serve them to the cluster (Hermes dashboard OIDC login + the Hermes
# MCP client_credentials app). Consumed later via ExternalSecrets by remoteRef.key.
resource "bitwarden-secrets_secret" "hermes_dashboard_client_id" {
  key        = "AUTH0_HERMES_DASHBOARD_CLIENT_ID"
  value      = auth0_client.hermes_dashboard.client_id
  note       = "Auth0 Hermes dashboard (regular web app) client id"
  project_id = var.bw_project_id
}

# resource "bitwarden-secrets_secret" "hermes_dashboard_client_secret" {
#   key        = "AUTH0_HERMES_DASHBOARD_CLIENT_SECRET"
#   value      = auth0_client.hermes_dashboard.client_secret
#   note       = "Auth0 Hermes dashboard (regular web app) client secret"
#   project_id = var.bw_project_id
# }

resource "bitwarden-secrets_secret" "mcp_client_id" {
  key        = "AUTH0_MCP_CLIENT_ID"
  value      = auth0_client.mcp.client_id
  note       = "Auth0 MCP client_credentials app client id"
  project_id = var.bw_project_id
}

# resource "bitwarden-secrets_secret" "mcp_client_secret" {
#   key        = "AUTH0_MCP_CLIENT_SECRET"
#   value      = auth0_client.hermes_mcp.client_secret
#   note       = "Auth0 MCP client_credentials app client secret"
#   project_id = var.bw_project_id
# }
