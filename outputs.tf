# ============================================================================
# Docker Swarm Cluster Outputs
# ============================================================================

output "cluster_overview" {
  description = "Docker Swarm cluster overview"
  value = {
    cluster_type = "Docker Swarm (Single Cluster)"
    total_nodes  = length(var.app_nodes) + length(var.infra_nodes)
    app_nodes    = length(var.app_nodes)
    infra_nodes  = length(var.infra_nodes)
    storage      = var.storage_pool
    networks = {
      cluster = "VLAN ${var.vlan_id} (192.168.4.0/24)"
      storage = "VLAN ${var.vlan_id_storage} (192.168.12.0/24)"
    }
  }
}

output "app_nodes" {
  description = "Application node details"
  value = {
    for key, node in proxmox_virtual_environment_vm.app_nodes : node.name => {
      vm_id       = node.vm_id
      proxmox     = node.node_name
      ip_cluster  = var.app_nodes[key].ip_vlan4
      ip_storage  = var.app_nodes[key].ip_vlan12
      cpu         = "${var.app_node_cores} cores"
      memory      = "${var.app_node_memory / 1024} GB"
      disk        = "${var.app_node_disk_size} GB"
      role        = "Swarm Manager + Applications"
    }
  }
}

output "infra_nodes" {
  description = "Infrastructure node details"
  value = {
    for key, node in proxmox_virtual_environment_vm.infra_nodes : node.name => {
      vm_id       = node.vm_id
      proxmox     = node.node_name
      ip_cluster  = var.infra_nodes[key].ip_vlan4
      ip_storage  = var.infra_nodes[key].ip_vlan12
      cpu         = "${var.infra_node_cores} cores"
      memory      = "${var.infra_node_memory / 1024} GB"
      boot_disk   = "${var.infra_node_boot_disk_size} GB"
      data_disk   = "${var.infra_nodes[key].data_disk_size} GB"
      role        = "SeaweedFS + Patroni PostgreSQL"
    }
  }
}

output "ansible_inventory" {
  description = "IP addresses for Ansible inventory"
  value = {
    app_nodes = {
      for key, config in var.app_nodes : "${var.app_node_prefix}-${key}" => config.ip_vlan4
    }
    infra_nodes = {
      for key, config in var.infra_nodes : "${var.infra_node_prefix}-${key}" => config.ip_vlan4
    }
    all_vlan4 = concat(
      [for key, config in var.app_nodes : config.ip_vlan4],
      [for key, config in var.infra_nodes : config.ip_vlan4]
    )
    all_vlan12 = concat(
      [for key, config in var.app_nodes : config.ip_vlan12],
      [for key, config in var.infra_nodes : config.ip_vlan12]
    )
  }
}

output "storage_summary" {
  description = "Storage allocation summary"
  value = {
    app_total_disk   = "${length(var.app_nodes) * var.app_node_disk_size} GB"
    infra_boot_total = "${length(var.infra_nodes) * var.infra_node_boot_disk_size} GB"
    infra_data_total = "${sum([for k, v in var.infra_nodes : v.data_disk_size])} GB"
    total_allocated  = "${(length(var.app_nodes) * var.app_node_disk_size) + (length(var.infra_nodes) * var.infra_node_boot_disk_size) + sum([for k, v in var.infra_nodes : v.data_disk_size])} GB"
    storage_backend  = var.storage_pool
  }
}

output "next_steps" {
  description = "Post-Terraform deployment steps"
  value = [
    "1. Wait for cloud-init to complete on all VMs (~2-3 minutes)",
    "2. Verify SSH access: ssh ansible@192.168.4.30",
    "3. Run Ansible playbook to initialize Docker Swarm",
    "4. Configure overlay networks for storage VLAN",
    "5. Deploy SeaweedFS on infra nodes with placement constraints",
    "6. Deploy Patroni PostgreSQL cluster on infra nodes",
    "7. Deploy applications on app nodes"
  ]
}
