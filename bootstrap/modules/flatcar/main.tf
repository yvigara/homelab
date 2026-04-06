locals {
  profiles_path  = "${var.matchbox_data_path}/profiles"
  groups_path    = "${var.matchbox_data_path}/groups"
  ignition_path  = "${var.matchbox_data_path}/ignition"
  baseurl        = "http://${var.os_channel}.release.flatcar-linux.net/amd64-usr/${var.os_version}"
  config_base    = "${var.node_name}-config"
  provision_base = "${var.node_name}-provision"
}

data "ct_config" "provision" {
  content = templatefile("${path.module}/config/flatcar-provision.yaml", {
    ssh_keys          = jsonencode(var.ssh_keys)
    install_disk      = var.install_disk
    kernel_console    = join(" ", var.kernel_console)
    kernel_args       = join(" ", var.kernel_args)
    os_channel        = var.os_channel
    os_version        = var.os_version
    ignition_endpoint = "${var.matchbox_http_endpoint}/ignition"
    mac_address       = var.node_mac
    cluster_token     = var.cluster_token
  })
  pretty_print = true
  strict       = true
}

data "ct_config" "config" {
  content = templatefile("${path.module}/config/flatcar-config.yaml", {
    ssh_keys      = jsonencode(var.ssh_keys)
    hostname      = var.node_name
    update_group  = var.flatcar_update_group
    update_server = var.flatcar_update_server
    dns_servers   = join(" ", var.dns_servers)
  })
  pretty_print = true
  strict       = true
  snippets     = var.clc_snippets
}

resource "local_file" "provision_ignition" {
  filename = "${local.ignition_path}/${local.provision_base}.ign"
  content  = data.ct_config.provision.rendered
}

resource "local_file" "config_ignition" {
  filename = "${local.ignition_path}/${local.config_base}.ign"
  content  = data.ct_config.config.rendered
}

resource "local_file" "provision_profile" {
  count    = var.installed ? 0 : 1
  filename = "${local.profiles_path}/${local.provision_base}.json"
  content = jsonencode({
    id   = local.provision_base
    name = local.provision_base
    boot = {
      kernel = "${local.baseurl}/flatcar_production_pxe.vmlinuz"
      initrd = [
        "${local.baseurl}/flatcar_production_pxe_image.cpio.gz"
      ]
      args = flatten([
        "initrd=flatcar_production_pxe_image.cpio.gz",
        "flatcar.first_boot=1",
        "ignition.config.url=${var.matchbox_http_endpoint}/ignition?uuid=$${uuid}&mac=$${mac:hexhyp}",
        var.kernel_console,
        var.kernel_args,
      ])
    }
    ignition_id = "${local.provision_base}.ign"
  })
}

# resource "local_file" "boot_profile" {
#   count    = var.installed ? 1 : 0
#   filename = "${local.profiles_path}/${local.provision_base}.json"
#   content = jsonencode({
#     id   = local.provision_base
#     name = local.provision_base
#     boot = {
#       # sanboot = "--no-describe --drive 0x80"
#       # exit    = 1
#     }
#     ignition_id = "${local.provision_base}.ign"
#   })
# }
resource "local_file" "config_profile" {
  filename = "${local.profiles_path}/${local.config_base}.json"
  content = jsonencode({
    id          = local.config_base
    name        = local.config_base
    ignition_id = "${local.config_base}.ign"
  })
}

resource "local_file" "provision_group" {
  filename = "${local.groups_path}/${local.provision_base}.json"
  content = jsonencode({
    id      = local.provision_base
    name    = local.provision_base
    profile = local.provision_base
    selector = {
      mac = var.node_mac
    }
    metadata = {
      ignition_endpoint = "${var.matchbox_http_endpoint}/ignition"
      install_disk      = var.install_disk
      hostname          = var.node_name
      mac_address       = var.node_mac
    }
  })
}

resource "local_file" "config_group" {
  filename = "${local.groups_path}/${local.config_base}.json"
  content = jsonencode({
    id      = local.config_base
    name    = local.config_base
    profile = local.config_base
    selector = {
      cfg = "true"
      mac = var.node_mac
    }
    metadata = {
      hostname      = var.node_name
      update_group  = var.flatcar_update_group
      update_server = var.flatcar_update_server
    }
  })
}
