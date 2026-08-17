terraform {
  required_version = ">= 1.15"

  required_providers {
    auth0 = {
      source  = "auth0/auth0"
      version = "1.55.0"
    }
    bitwarden-secrets = {
      source  = "bitwarden/bitwarden-secrets"
      version = "~> 1.0"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "5.23.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
  }
}

# Credentials come from the environment (provisioned by mise + fnox):
#   auth0            -> AUTH0_DOMAIN, AUTH0_CLIENT_ID, AUTH0_CLIENT_SECRET (Management API M2M app)
#   cloudflare       -> CLOUDFLARE_API_KEY/EMAIL or CF_API_TOKEN
#   bitwarden-secrets -> BWS_ACCESS_TOKEN
provider "auth0" {}

provider "cloudflare" {}

provider "bitwarden-secrets" {}
