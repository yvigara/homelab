terraform {
  required_providers {
    ct = {
      source  = "poseidon/ct"
      version = "0.14.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
  }
  required_version = "~> 1.14"
}

locals {
  matchbox_url = var.matchbox_url
  ssh_key      = file("~/.ssh/id_ed25519.pub")
}

provider "ct" {}

module "node1" {
  source                 = "../modules/flatcar"
  matchbox_http_endpoint = local.matchbox_url
  matchbox_data_path     = "${path.module}/volumes/matchbox/var"
  node_mac               = var.node1_mac_addr
  node_name              = var.node1_hostname
  ssh_keys               = [local.ssh_key]
  install_disk           = "/dev/nvme0n1"
  cluster_token          = var.cluster_token
}

