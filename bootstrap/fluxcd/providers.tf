terraform {
  required_version = ">= 1.15"

  required_providers {
    bitwarden-secrets = {
      source  = "bitwarden/bitwarden-secrets"
      version = "~> 1.0"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "5.21.1"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.2"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.2"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
  }
}

provider "kubernetes" {
  config_path    = "~/.kube/config"
  config_context = var.cluster_name
}

provider "helm" {
  kubernetes = {
    config_path    = "~/.kube/config"
    config_context = var.cluster_name
  }
}

provider "cloudflare" {}

provider "bitwarden-secrets" {}
