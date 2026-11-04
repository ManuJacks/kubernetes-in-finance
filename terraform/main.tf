terraform {
  required_version = ">= 1.6.0"
}

variable "ubuntu_image" {
  description = "Ubuntu image used for the Kubernetes nodes"
  type        = string
  default     = "26.04"
}

variable "load_balancers_to_create" {
  description = "Explicit requests to provision new load balancer VMs"
  type = map(object({
    name        = string
    zone        = string
    cpus        = number
    memory      = string
    disk        = string
    frontend_ip = string
  }))
  default = {}
}

locals {
  nodes = {
    control1 = {
      name   = "tf-ha-control1"
      role   = "control-plane"
      zone   = "zone1"
      cpus   = 2
      memory = "2G"
      disk   = "20G"
    }
    control2 = {
      name   = "tf-ha-control2"
      role   = "control-plane"
      zone   = "zone2"
      cpus   = 2
      memory = "2G"
      disk   = "20G"
    }
    control3 = {
      name   = "tf-ha-control3"
      role   = "control-plane"
      zone   = "zone3"
      cpus   = 2
      memory = "2G"
      disk   = "20G"
    }
    worker1 = {
      name   = "tf-ha-worker1"
      role   = "worker"
      zone   = "zone1"
      cpus   = 1
      memory = "1G"
      disk   = "20G"
    }
    worker2 = {
      name   = "tf-ha-worker2"
      role   = "worker"
      zone   = "zone2"
      cpus   = 1
      memory = "1G"
      disk   = "20G"
    }
  }

  # Existing load balancers.
  # These are declarative records only; Terraform does not create or destroy them.
  load_balancers = {
    api_lb1 = {
      name            = "api-lb1-new"
      zone            = "zone2"
      cpus            = 1
      memory_bytes    = 731987968
      disk_bytes      = 5120138752
      management_ip   = "10.97.1.141"
      frontend_ip     = "10.97.3.11"
      frontend_bridge = "br-api-frontend"
      api_vip         = "10.97.3.100"
    }
    api_lb2 = {
      name            = "api-lb2-new"
      zone            = "zone3"
      cpus            = 1
      memory_bytes    = 731987968
      disk_bytes      = 5120138752
      management_ip   = "10.97.2.242"
      frontend_ip     = "10.97.3.12"
      frontend_bridge = "br-api-frontend"
      api_vip         = "10.97.3.100"
    }
  }
}

resource "terraform_data" "kubernetes_node" {
  for_each = local.nodes

  input = each.value

  triggers_replace = [
    each.value.name,
    each.value.zone,
    each.value.cpus,
    each.value.memory,
    each.value.disk,
    var.ubuntu_image
  ]

  provisioner "local-exec" {
    command = "bash '${path.module}/../scripts/multipass-node.sh' create '${each.value.name}' '${each.value.zone}' '${each.value.cpus}' '${each.value.memory}' '${each.value.disk}' '${var.ubuntu_image}'"
  }

  provisioner "local-exec" {
    when    = destroy
    command = "bash '${path.module}/../scripts/multipass-node.sh' destroy '${self.input.name}'"
  }
}

# Records the existing load balancer topology without managing VM lifecycle.
resource "terraform_data" "load_balancer" {
  for_each = local.load_balancers

  input = each.value
}

# Explicitly requested VM provisioning.
# An empty load_balancers_to_create map means no VMs are created.
resource "terraform_data" "load_balancer_vm" {
  for_each = var.load_balancers_to_create

  input = each.value

  triggers_replace = [
    each.value.name,
    each.value.zone,
    each.value.cpus,
    each.value.memory,
    each.value.disk,
    each.value.frontend_ip,
    var.ubuntu_image
  ]

  lifecycle {
    prevent_destroy = true
  }

  provisioner "local-exec" {
    command = "bash '${path.module}/../scripts/multipass-load-balancer.sh' create '${each.value.name}' '${each.value.zone}' '${each.value.cpus}' '${each.value.memory}' '${each.value.disk}' '${var.ubuntu_image}' '${each.value.frontend_ip}'"
  }
}

output "load_balancers" {
  description = "Existing load balancer configuration; VMs are managed outside Terraform"

  value = {
    for key, lb in local.load_balancers : key => lb
  }
}

output "kubernetes_nodes" {
  description = "Terraform-managed Kubernetes VM definitions"

  value = {
    for key, node in local.nodes : key => {
      name = node.name
      role = node.role
      zone = node.zone
    }
  }
}
