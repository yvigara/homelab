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
