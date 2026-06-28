variable "bootstrap_revision" {
  description = "Bump to trigger a new bootstrap run."
  type        = number
  default     = 1
  nullable    = false
}

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

variable "bgp_peer_addr" {
  description = "BGP MetalLB peer address"
  type        = string
  nullable    = false
}

variable "bgp_cidr" {
  description = "BGP MetalLB reserved CIDR"
  type        = string
  nullable    = false
}

variable "interal_lb_ip" {
  description = "Internal LoadBalancer IP address"
  type        = string
  nullable    = false
}

variable "ag_lb_ip" {
  description = "Agentgateway LoadBalancer IP address"
  type        = string
  nullable    = false
}

variable "domain" {
  description = "Cloudflare domain name"
  type        = string
  nullable    = false
}

variable "cluster_env" {
  description = "Name of the environment (lab, dev, prd,...)."
  type        = string
  nullable    = false
}

variable "cluster_name" {
  description = "Name of the cluster directory under clusters/ (e.g. staging)."
  type        = string
  nullable    = false
}

variable "cluster_region" {
  description = "Cloud provider region where the cluster runs (e.g. eu-west-2)."
  type        = string
  nullable    = false
}

