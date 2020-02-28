provider "azurerm" {}

data "http" "whatismyip" {
  url = "http://whatismyip.akamai.com/"
}

resource "random_id" "cluster_name" {
  prefix      = "dcos-terraform-"
  byte_length = 4
}

module "dcos" {
  source  = "dcos-terraform/dcos/azurerm"
  version = "~> 0.2.0"

  dcos_instance_os    = "${var.dcos_instance_os}"
  cluster_name        = "${random_id.cluster_name.hex}"
  ssh_public_key_file = "./ssh-key.pub"
  admin_ips           = ["${data.http.whatismyip.body}/32"]
  location            = "West US"

  num_masters        = "${var.num_masters}"
  num_private_agents = "${var.num_private_agents}"
  num_public_agents  = "${var.num_public_agents}"

  ansible_bundled_container = "mesosphere/dcos-ansible-bundle:windows-beta-support"

  ansible_additional_config = <<EOF
connection_timeout: 600
dcos:
  download_win: "https://downloads.mesosphere.com/dcos-enterprise/testing/2.1.0-beta1/windows/dcos_generate_config_win.ee.sh"
EOF

  additional_windows_private_agent_ips       = ["${concat(module.winagent.private_ips)}"]
  additional_windows_private_agent_passwords = ["${concat(module.winagent.windows_passwords)}"]
  additional_windows_private_agent_os_user   = "${module.winagent.admin_username}"

  dcos_oauth_enabled = "false"
  dcos_security      = "permissive"

  dcos_config = <<EOF
enable_windows_agents: true
EOF

  providers = {
    azurerm = "azurerm"
  }

  #dcos_version = "${var.dcos_version}"
  dcos_version              = "2.1.0-beta1"
  custom_dcos_download_path = "${var.dcos_variant == "ee" ? "https://downloads.mesosphere.com/dcos-enterprise/testing/2.1.0-beta1/dcos_generate_config.ee.sh" : "https://downloads.dcos.io/dcos/testing/2.1.0-beta1/dcos_generate_config.sh"}"
  dcos_variant              = "${var.dcos_variant}"
  dcos_license_key_contents = "${var.dcos_license_key_contents}"
}

module "winagent" {
  source = "dcos-terraform/windows-instance/azurerm"

  providers = {
    azurerm = "azurerm"
  }

  location            = "West US"
  dcos_instance_os    = "windows_1809"
  cluster_name        = "${random_id.cluster_name.hex}"
  hostname_format     = "winagt-%[1]d-%[2]s"
  subnet_id           = "${module.dcos.infrastructure.subnet_id}"
  resource_group_name = "${module.dcos.infrastructure.resource_group_name}"
  vm_size             = "Standard_D2s_v3"
  admin_username      = "${module.dcos.infrastructure.private_agents.admin_username}"
  num                 = 1
}

variable "dcos_instance_os" {
  default = "centos_7.6"
}

variable "dcos_variant" {
  default = "ee"
}

variable "dcos_license_key_contents" {}

variable "dcos_version" {
  default = "2.0.0"
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

output "masters-ips" {
  value = "${module.dcos.masters-ips}"
}

output "cluster-address" {
  value = "${module.dcos.masters-loadbalancer}"
}

output "public-agents-loadbalancer" {
  value = "${module.dcos.public-agents-loadbalancer}"
}
