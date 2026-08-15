locals {
  acme_email                    = data.bitwarden-secrets_secret.acme_email.value
  github_app_id                 = data.bitwarden-secrets_secret.github_app_id.value
  github_app_pem                = data.bitwarden-secrets_secret.github_app_pem.value
  github_app_installation_owner = data.bitwarden-secrets_secret.github_app_installation_owner.value

  has_github_app = local.github_app_id != ""
  git_auth_secret = local.has_github_app ? yamlencode({
    apiVersion = "v1"
    kind       = "Secret"
    metadata = {
      name = "flux-system"
    }
    type = "Opaque"
    stringData = merge(
      local.has_github_app ? {
        githubAppID                = local.github_app_id
        githubAppInstallationOwner = local.github_app_installation_owner
        githubAppPrivateKey        = local.github_app_pem
      } : {},
    )
  }) : ""
}

module "flux_operator_bootstrap" {
  source  = "controlplaneio-fluxcd/flux-operator-bootstrap/kubernetes"
  version = "0.8.0"

  revision = var.bootstrap_revision

  gitops_resources = {
    instance_yaml = file("../../kubernetes/clusters/${var.cluster_env}/${var.cluster_name}/flux-system/flux-instance.yaml")
    operator_chart = {
      values_yaml = file("../../kubernetes/clusters/${var.cluster_env}/${var.cluster_name}/flux-system/flux-operator-values.yaml")
    }
  }

  managed_resources = {
    secrets_yaml = local.git_auth_secret
    runtime_info = {
      labels = {
        "reconcile.fluxcd.io/watch" = "Enabled"
      }
      data = {
        CLUSTER_REGION     = var.cluster_region
        CLUSTER_ENV        = var.cluster_env
        CLUSTER_NAME       = var.cluster_name
        ENVIRONMENT        = var.cluster_env
        DATACENTER         = var.cluster_region
        REGION             = var.cluster_region
        OLLAMA_SRV1_IP     = data.bitwarden-secrets_secret.ollama_srv1_ip.value
        DOMAIN             = var.domain
        LB_INT_IP          = var.interal_lb_ip
        AG_INT_IP          = var.ag_lb_ip
        BGP_CIDR           = var.bgp_cidr
        BGP_PEER_ADDR      = var.bgp_peer_addr
        ACME_EMAIL         = local.acme_email
        BW_ORGANIZATION_ID = var.bw_organization_id
        BW_PROJECT_ID      = var.bw_project_id
      }
    }
  }
}

