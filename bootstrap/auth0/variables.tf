variable "bw_project_id" {
  description = "Bitwarden SecretManager project ID"
  type        = string
  nullable    = false
}

variable "bw_organization_id" {
  description = "Bitwarden SecretManager Organization ID"
  type        = string
  nullable    = false
}

variable "domain" {
  description = "Cloudflare / base domain name (e.g. celestio.cloud)"
  type        = string
  nullable    = false
}

variable "cluster_env" {
  description = "Name of the environment (lab, dev, prd, ...)."
  type        = string
  nullable    = false
}

variable "cluster_region" {
  description = "Region segment used in internal hostnames (e.g. sed)."
  type        = string
  nullable    = false
}

variable "github_org" {
  description = "GitHub organization whose members are allowed to sign in."
  type        = string
  default     = "celest-io"
  nullable    = false
}
