resource "random_password" "gh_webhook_secret" {
  length           = 32
  special          = true
  lower            = true
  upper            = true
  override_special = "!$_?-."
}

resource "bitwarden-secrets_secret" "FLUX_GITHUB_WEBHOOK_TOKEN" {
  key        = "FLUX_GITHUB_WEBHOOK_TOKEN"
  value      = random_password.gh_webhook_secret.result
  project_id = var.bw_project_id
  note       = "FluxCD/GitHub Webhook Token"
}
