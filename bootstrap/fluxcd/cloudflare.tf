locals {
  internal_lb = "int.${var.cluster_region}.${var.cluster_env}.${var.domain}"
}

data "cloudflare_zone" "main" {
  filter = {
    name = var.domain
  }
}

resource "cloudflare_dns_record" "internal_lb" {
  zone_id = data.cloudflare_zone.main.id
  name    = local.internal_lb
  content = var.interal_lb_ip
  type    = "A"
  ttl     = 3600
}

resource "cloudflare_dns_record" "internal_lb_wildcard" {
  zone_id = data.cloudflare_zone.main.id
  name    = "*.${local.internal_lb}"
  content = var.interal_lb_ip
  type    = "A"
  ttl     = 3600
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


