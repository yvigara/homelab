terraform {
  required_version = ">= 1.14"

  required_providers {
    bitwarden-secrets = {
      source  = "bitwarden/bitwarden-secrets"
      version = "0.5.4-pre"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "5.18.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.8"
    }
  }
}

locals {
  has_git_token  = var.git_token != ""
  has_github_app = var.github_app_id != ""
  git_auth_secret = local.has_git_token || local.has_github_app ? yamlencode({
    apiVersion = "v1"
    kind       = "Secret"
    metadata = {
      name = "flux-system"
    }
    type = "Opaque"
    stringData = merge(
      local.has_git_token ? {
        username = "git"
        password = var.git_token
      } : {},
      local.has_github_app ? {
        githubAppID                = var.github_app_id
        githubAppInstallationOwner = var.github_app_installation_owner
        githubAppPrivateKey        = var.github_app_pem
      } : {},
    )
  }) : ""
}

module "flux_operator_bootstrap" {
  source  = "controlplaneio-fluxcd/flux-operator-bootstrap/kubernetes"
  version = "0.4.0"

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
        CLUSTER_REGION = var.cluster_region
        CLUSTER_ENV    = var.cluster_env
        CLUSTER_NAME   = var.cluster_name
        DOMAIN         = var.domain
        LB_INT_IP      = var.interal_lb_ip
        BGP_CIDR       = var.bgp_cidr
      }
    }
  }
}

