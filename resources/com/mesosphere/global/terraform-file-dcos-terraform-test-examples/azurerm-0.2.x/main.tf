provider "azurerm" {}

data "http" "whatismyip" {
  url = "http://whatismyip.akamai.com/"
}
resource "random_id" "cluster_name" {
  prefix      = "dcos-terraform-"
  byte_length = 4
}

locals {
  cluster_name     = "${random_id.cluster_name.hex}"
  location         = "West US" 
  dcos_winagent_os = "windows_1809"
  vm_size          = "Standard_D2s_v3"
}
module "dcos" {
  source  = "dcos-terraform/dcos/azurerm"
  version = "~> 0.2.0"

  dcos_instance_os    = "${var.dcos_instance_os}"
  ssh_public_key_file = "${var.ssh_public_key_file}"
  admin_ips           = ["${data.http.whatismyip.body}/32"]
  location            = "${local.location}"

  num_masters        = "${var.num_masters}"
  num_private_agents = "${var.num_private_agents}"
  num_public_agents  = "${var.num_public_agents}"

  ansible_bundled_container = "mesosphere/dcos-ansible-bundle:feature-windows-support-039d79d"

  additional_windows_private_agent_os_user   = "${module.winagent.admin_username}"
  additional_windows_private_agent_passwords = "${module.winagent.windows_passwords}"
  additional_windows_private_agent_ips       = ["${concat(module.winagent.private_ips)}"]

  dcos_oauth_enabled = "false"
  dcos_security      = "strict"

  providers = {
    azure = "azurerm"
  }

  dcos_version = "${var.dcos_version}"

  dcos_variant              = "${var.dcos_variant}"
  dcos_license_key_contents = "${var.dcos_license_key_contents}"

}

module "winagent" {
  source  = "dcos-terraform/windows-instance/azurerm"

  providers = {
    azure = "azurerm"
  }

  location               = "${local.location}"
  dcos_instance_os       = "${local.dcos_winagent_os}"
  cluster_name           = "${local.cluster_name}"

  hostname_format        = "winagt-%[1]d-%[2]s"

  subnet_id              = "${module.dcos.infrastructure.subnet_id}"
  resource_group_name    = "${module.dcos.infrastructure.resource_group_name}"
  vm_size                = "${local.vm_size}"
  admin_username         = "dcosadmin"
  public_ssh_key         = "${var.ssh_public_key_file}"
  num                    = "${var.num_windows_agents}"
}
variable "dcos_instance_os" {
  default = "centos_7.6"
}


variable "dcos_variant" {
  default = "ee"
}

variable "dcos_license_key_contents" {}

variable "dcos_version" {
default = "1.13.1"
}
variable "ssh_public_key_file" {
default = "./ssh-key.pub"
}

variable "num_masters" {
  description = "Specify the amount of masters. For redundancy you should have at least 3"
  default     = 1
}

variable "num_private_agents" {
  description = "Specify the amount of private agents. These agents will provide your main resources"
  default     = 1
}

variable "num_public_agents" {
  description = "Specify the amount of public agents. These agents will host marathon-lb and edgelb"
  default     = 1
}

variable "num_windows_agents" {
  description = "Specify the amount of windows agents. These agents will provide your main resources"
  default     = 1
}

output "masters-ips" {
  value = "${module.dcos.masters-ips}"
}

output "cluster-address" {
  value = "${module.dcos.masters-loadbalancer}"
}

output "public-agents-loadbalancer" {
  value = "${module.dcos.public-agents-loadbalancer}"
}
output "public_ips" {
  description = "Windows IP"
  value = "${module.winagent.public_ips}"
}
output "windows_passwords" {
  description = "Windows Password for user ${module.winagent.admin_username}"
  value = "${module.winagent.windows_passwords}"
}
output "masters_dns_name" {
  description = "This is the load balancer address to access the DC/OS UI"
  value       = "${module.dcos.masters-loadbalancer}"
}
