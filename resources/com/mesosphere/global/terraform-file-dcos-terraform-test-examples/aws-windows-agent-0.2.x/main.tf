provider "aws" {
  region = "us-east-1"
}

data "http" "whatismyip" {
  url = "http://whatismyip.akamai.com/"
}

resource "random_id" "cluster_name" {
  prefix      = "dcos-terraform-"
  byte_length = 4
}

module "dcos" {
  source  = "dcos-terraform/dcos/aws"
  version = "~> 0.2.0"

  cluster_name        = "${random_id.cluster_name.hex}"
  ssh_public_key_file = "./ssh-key.pub"
  admin_ips           = ["${data.http.whatismyip.body}/32"]

  num_masters        = "${var.num_masters}"
  num_private_agents = "${var.num_private_agents}"
  num_public_agents  = "${var.num_public_agents}"

  ansible_bundled_container = "mesosphere/dcos-ansible-bundle:windows"

  #TO BE DELETED after Windows GA release
  dcos_version                      = "2.1.0-beta2"
  custom_dcos_download_path         = "${var.dcos_variant == "ee" ? "https://downloads.mesosphere.io/dcos-enterprise/testing/2.1.0-beta2/dcos_generate_config.ee.sh" : "https://downloads.dcos.io/dcos/testing/2.1.0-beta2/dcos_generate_config.sh"}"
  custom_dcos_windows_download_path = "${var.dcos_variant == "ee" ? "https://downloads.mesosphere.com/dcos-enterprise/testing/2.1.0-beta2/windows/dcos_generate_config_win.ee.sh" : "https://downloads.dcos.io/dcos/testing/2.1.0-beta2/windows/dcos_generate_config_win.sh"}"

  #TO BE DELETED after Windows GA release
  ansible_additional_config = <<EOF
connection_timeout: 60
EOF

  dcos_oauth_enabled         = "false"
  dcos_security              = "permissive"
  dcos_enable_windows_agents = "true"

  dcos_instance_os             = "${var.dcos_instance_os}"
  bootstrap_instance_type      = "${var.bootstrap_instance_type}"
  masters_instance_type        = "${var.masters_instance_type}"
  private_agents_instance_type = "${var.private_agents_instance_type}"
  public_agents_instance_type  = "${var.public_agents_instance_type}"

  providers = {
    aws = "aws"
  }

  dcos_variant              = "${var.dcos_variant}"
  dcos_license_key_contents = "${var.dcos_license_key_contents}"

  additional_windows_private_agent_ips       = ["${concat(module.winagent.private_ips)}"]
  additional_windows_private_agent_passwords = ["${concat(module.winagent.windows_passwords)}"]
}

module "winagent" {
  source  = "dcos-terraform/windows-instance/aws"
  version = "~> 0.0.1"

  providers = {
    aws = "aws"
  }

  cluster_name           = "${random_id.cluster_name.hex}"
  hostname_format        = "%[3]s-winagent%[1]d-%[2]s"
  aws_subnet_ids         = ["${module.dcos.infrastructure.vpc.subnet_ids}"]
  aws_security_group_ids = ["${module.dcos.infrastructure.security_groups.internal}", "${module.dcos.infrastructure.security_groups.admin}"]
  aws_key_name           = "${module.dcos.infrastructure.aws_key_name}"
  aws_instance_type      = "m5a.xlarge"
  num                    = 1
}

variable "dcos_instance_os" {
  default = "centos_7.6"
}

variable "bootstrap_instance_type" {
  default = "m5a.xlarge"
}

variable "masters_instance_type" {
  default = "t2.large"
}

variable "private_agents_instance_type" {
  default = "t2.large"
}

variable "public_agents_instance_type" {
  default = "t2.large"
}

variable "dcos_variant" {
  default = "ee"
}

variable "dcos_license_key_contents" {}

variable "dcos_version" {
  default = "2.1.0"
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
