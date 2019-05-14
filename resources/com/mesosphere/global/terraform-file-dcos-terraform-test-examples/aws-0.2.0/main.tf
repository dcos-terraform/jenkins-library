provider "aws" {
  # Change your default region here
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

  dcos_version = "${var.dcos_version}"

  dcos_oauth_enabled = "false"

  dcos_instance_os             = "centos_7.5"
  bootstrap_instance_type      = "t2.large"
  masters_instance_type        = "t2.large"
  private_agents_instance_type = "t2.large"
  public_agents_instance_type  = "t2.large"

  providers = {
    aws = "aws"
  }

  # dcos_variant              = "ee"
  # dcos_license_key_contents = "${file("./license.txt")}"
  dcos_variant = "open"
}

variable "dcos_version" {
  default     = "1.12.0"
  description = "specifies which dcos version instruction to use. Options: `1.9.0`, `1.8.8`, etc. _See [dcos_download_path](https://github.com/dcos-terraform/terraform-template-dcos-core/blob/master/open/download-variables.tf) or [dcos_version](https://github.com/dcos-terraform/terraform-template-dcos-core/tree/master/open/dcos-versions) tree for a full list._"
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
