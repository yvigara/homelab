data "cloudflare_zone" "main" {
  filter = {
    name = var.domain
  }
}

data "cloudflare_account_api_token_permission_groups_list" "all" {
  account_id = data.cloudflare_zone.main.account.id
  name       = "DNS%20Write"
  scope      = "com.cloudflare.api.account.zone"
}

# Token allowed to edit DNS entries and TLS certs for specific zone.
resource "cloudflare_api_token" "external_dns" {
  name = "${var.domain} External-DNS - ${var.cluster_name}-${var.cluster_env}"

  policies = [{
    effect            = "allow"
    permission_groups = data.cloudflare_account_api_token_permission_groups_list.all.result

    resources = jsonencode({
      "com.cloudflare.api.account.zone.${data.cloudflare_zone.main.id}" = "*"
    })
  }]
}

resource "random_password" "cf_tunnel_secret" {
  length           = 32
  special          = true
  lower            = true
  upper            = true
  override_special = "!$_?-."
}

resource "bitwarden-secrets_secret" "cf_tunnel_secret" {
  key        = "CF_TUNNEL_SECRET"
  value      = base64encode(random_password.cf_tunnel_secret.result)
  note       = "Cloudflare Cluster Tunnel Secret"
  project_id = var.bw_project_id
}

resource "cloudflare_zero_trust_tunnel_cloudflared" "cluster" {
  account_id    = data.cloudflare_zone.main.account.id
  name          = var.cluster_name
  config_src    = "local"
  tunnel_secret = bitwarden-secrets_secret.cf_tunnel_secret.value
}

resource "bitwarden-secrets_secret" "cf_api_token" {
  key        = "CF_API_TOKEN"
  value      = cloudflare_api_token.external_dns.value
  note       = "Cloudflare API Token for ExternalDNS"
  project_id = var.bw_project_id
}

resource "bitwarden-secrets_secret" "cf_tunnel_id" {
  key        = "CF_TUNNEL_ID"
  value      = cloudflare_zero_trust_tunnel_cloudflared.cluster.id
  note       = "Cloudflare Cluster Tunnel ID"
  project_id = var.bw_project_id
}

resource "bitwarden-secrets_secret" "cf_account_tag" {
  key        = "CF_ACCOUNT_TAG"
  value      = cloudflare_zero_trust_tunnel_cloudflared.cluster.account_tag
  note       = "Cloudflare Account Tag"
  project_id = var.bw_project_id
}

resource "bitwarden-secrets_secret" "cf_account_id" {
  key        = "CF_ACCOUNT_ID"
  value      = data.cloudflare_zone.main.account.id
  note       = "Cloudflare Account ID"
  project_id = var.bw_project_id
}

# Dex's JWKS/discovery/token endpoints are hit by machine clients (e.g. hermes-agent's
# Python urllib), which Browser Integrity Check blocks as non-browser traffic.
resource "cloudflare_ruleset" "dex_bic_bypass" {
  zone_id     = data.cloudflare_zone.main.id
  name        = "Disable BIC for dex"
  description = "Dex is an OIDC provider queried by non-browser clients; Browser Integrity Check false-positives on them."
  kind        = "zone"
  phase       = "http_config_settings"

  rules = [{
    action = "set_config"
    action_parameters = {
      bic = false
    }
    expression  = "(http.host eq \"dex.${var.domain}\")"
    description = "Disable Browser Integrity Check for dex"
    enabled     = true
  }]
}
