data "bitwarden-secrets_list_secrets" "secrets" {}
locals {
  bw_secrets = { for s in data.bitwarden-secrets_list_secrets.secrets.secrets : s.key => s.id }
}

data "bitwarden-secrets_secret" "github_app_id" {
  id = local.bw_secrets["FLUX_GH_APP_ID"]
}

data "bitwarden-secrets_secret" "github_app_pem" {
  id = local.bw_secrets["FLUX_GH_APP_PRIVATE_KEY"]
}

data "bitwarden-secrets_secret" "github_app_installation_owner" {
  id = local.bw_secrets["FLUX_GH_APP_INSTALLATION_OWNER"]
}

data "bitwarden-secrets_secret" "acme_email" {
  id = local.bw_secrets["ACME_EMAIL"]
}

data "bitwarden-secrets_secret" "cluster" {
  id = local.bw_secrets["bitwarden-eso-machine-key"]
}

data "bitwarden-secrets_secret" "ollama_srv1_ip" {
  id = local.bw_secrets["OLLAMA_SRV1_IP"]
}

data "bitwarden-secrets_secret" "dex_gh_client_id" {
  id = local.bw_secrets["DEX_GITHUB_CLIENT_ID"]
}

data "bitwarden-secrets_secret" "dex_gh_client_secret" {
  id = local.bw_secrets["DEX_GITHUB_CLIENT_SECRET"]
}

data "bitwarden-secrets_secret" "dex_hermes_dashboard_secret" {
  id = local.bw_secrets["HERMES_DASHBOARD_CLIENT_SECRET"]
}

data "bitwarden-secrets_secret" "dex_rustfs_client_secret" {
  id = local.bw_secrets["RUSTFS_OIDC_CLIENT_SECRET"]
}

data "bitwarden-secrets_secret" "buzz_owner_pubkey_secret" {
  id = local.bw_secrets["BUZZ_OWNER_PUBKEY"]
}

data "bitwarden-secrets_secret" "buzz_relay_private_key_secret" {
  id = local.bw_secrets["BUZZ_RELAY_PRIVATE_KEY"]
}

resource "kubernetes_secret_v1" "flux-runtime-info" {
  metadata {
    name      = "flux-runtime-info"
    namespace = "flux-system"
  }

  data = {
    BW_ORGANIZATION_ID = var.bw_organization_id
    BW_PROJECT_ID      = var.bw_project_id
    # FLUX_SLACK_NOTIFICATION_URL     = var.flux_slack_notification_url
    # FLUX_SLACK_NOTIFICATION_CHANNEL = var.flux_slack_notification_channel
    # FLUX_GITHUB_WEBHOOK_TOKEN       = random_password.github-webhook-token.result
    # FLUX_GITHUB_TOKEN               = base64encode(var.flux_github_token)
    # GITHUB_OWNER                    = local.github_owner
    # GHCR_TOKEN                      = base64encode(var.ghcr_token)
    #
    # OAUTH_CLUSTER_ADMIN_PROVIDER_URI = "https://sts.windows.net/${data.azuread_client_config.current.tenant_id}/"
    # OIDC_ISSUER_URL                  = local.auth0_provider_uri
    # OIDC_AUDIENCE                    = local.auth0_default_audience
    # OIDC_TOKEN_URL                   = "${local.auth0_provider_uri}/oauth/token"

  }

  type = "Opaque"
}

resource "kubernetes_secret_v1" "cluster-secrets" {
  metadata {
    name      = "cluster-secrets"
    namespace = "flux-system"
  }

  data = {
    BW_ORGANIZATION_ID             = var.bw_organization_id
    BW_PROJECT_ID                  = var.bw_project_id
    BUZZ_RELAY_PRIVATE_KEY         = data.bitwarden-secrets_secret.buzz_relay_private_key_secret.value
    CF_TUNNEL_ID                   = cloudflare_zero_trust_tunnel_cloudflared.cluster.id
    DEX_GITHUB_CLIENT_ID           = data.bitwarden-secrets_secret.dex_gh_client_id.value
    DEX_GITHUB_CLIENT_SECRET       = data.bitwarden-secrets_secret.dex_gh_client_secret.value
    HERMES_DASHBOARD_CLIENT_SECRET = data.bitwarden-secrets_secret.dex_hermes_dashboard_secret.value
    RUSTFS_OIDC_CLIENT_SECRET      = data.bitwarden-secrets_secret.dex_rustfs_client_secret.value
    BUZZ_OWNER_PUBKEY              = data.bitwarden-secrets_secret.buzz_owner_pubkey_secret.value

    # FLUX_SLACK_NOTIFICATION_URL     = var.flux_slack_notification_url
    # FLUX_SLACK_NOTIFICATION_CHANNEL = var.flux_slack_notification_channel
    # FLUX_GITHUB_WEBHOOK_TOKEN       = random_password.github-webhook-token.result
    # FLUX_GITHUB_TOKEN               = base64encode(var.flux_github_token)
    # GITHUB_OWNER                    = local.github_owner
    # GHCR_TOKEN                      = base64encode(var.ghcr_token)
    #
    # OAUTH_CLUSTER_ADMIN_PROVIDER_URI = "https://sts.windows.net/${data.azuread_client_config.current.tenant_id}/"
    # OIDC_ISSUER_URL                  = local.auth0_provider_uri
    # OIDC_AUDIENCE                    = local.auth0_default_audience
    # OIDC_TOKEN_URL                   = "${local.auth0_provider_uri}/oauth/token"

  }

  type = "Opaque"
}

resource "kubernetes_namespace_v1" "external_secrets" {
  metadata {
    name = "external-secrets"
  }
  lifecycle {
    ignore_changes = [
      metadata[0].labels,
      metadata[0].annotations
    ]
  }
}

resource "kubernetes_secret_v1" "bitwarden-sdk-server-secret" {
  metadata {
    name      = "bitwarden-sdk-server-secret"
    namespace = kubernetes_namespace_v1.external_secrets.id
  }

  data = {
    token = data.bitwarden-secrets_secret.cluster.value
  }

  type = "Opaque"
  lifecycle {
    ignore_changes = [
      metadata[0].labels,
      metadata[0].annotations
    ]
  }
}

resource "kubernetes_secret_v1" "eso-flux-runtime-info" {
  metadata {
    name      = "flux-runtime-info"
    namespace = kubernetes_namespace_v1.external_secrets.id
  }

  data = {
    BW_ORGANIZATION_ID = var.bw_organization_id
    BW_PROJECT_ID      = var.bw_project_id
  }
}

resource "kubernetes_secret_v1" "eso-cluster-secrets" {
  metadata {
    name      = "cluster-secrets"
    namespace = kubernetes_namespace_v1.external_secrets.id
  }

  data = {
    BW_ORGANIZATION_ID = var.bw_organization_id
    BW_PROJECT_ID      = var.bw_project_id
  }
}
