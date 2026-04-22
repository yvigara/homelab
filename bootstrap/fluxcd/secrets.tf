resource "random_password" "auth_secret" {
  length           = 32
  special          = true
  lower            = true
  upper            = true
  override_special = "!$_?-."
}

resource "bitwarden-secrets_secret" "cf_api_token" {
  key = "cf_api_token"
  value      = cloudflare_api_token.external_dns.value
  note       = "Cloudflare API Token for ExternalDNS"
  project_id = var.bw_project_id
}

resource "kubernetes_secret_v1" "flux-runtime-info" {
  metadata {
    name      = "flux-runtime-info"
    namespace = "flux-system"
  }

  data = {
    "cf_api_token" = cloudflare_api_token.external_dns.value
    "auth_secret" = random_password.auth_secret.result
  }

  type = "Opaque"
}

