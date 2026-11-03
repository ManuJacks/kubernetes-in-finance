terraform {
  required_version = ">= 1.6.0"
}

variable "ubuntu_image" {
  description = "Ubuntu image used for the Kubernetes nodes"
  type        = string
  default     = "26.04"
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
