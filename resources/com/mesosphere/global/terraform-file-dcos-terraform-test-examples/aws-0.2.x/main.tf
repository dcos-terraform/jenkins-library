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

  dcos_version = "${var.dcos_version}"

  dcos_oauth_enabled = "false"
  dcos_security      = "strict"

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
  version = "0.0.1"

  providers = {
    aws = "aws"
  }

  cluster_name           = "${random_id.cluster_name.hex}"
  hostname_format        = "%[3]s-winagent%[1]d-%[2]s"
  aws_subnet_ids         = ["${module.dcos.infrastructure.vpc.subnet_ids}"]
  aws_security_group_ids = ["${aws_security_group.test_dotnet_sample.id}", "${module.dcos.infrastructure.security_groups.admin}"]
  aws_key_name           = "${module.dcos.infrastructure.aws_key_name}"
  aws_instance_type      = "m5.xlarge"

  # provide the number of windows agents that should be provisioned.
  num = "1"
}
resource "aws_security_group" "test_dotnet_sample" {
  name        = "dcos-test_dotnet_sample"
  description = "Allow incoming traffic to .NET application"
  vpc_id      = "${module.dcos.infrastructure.vpc.id}"

  ingress {
    from_port   = "${var.dotnet_sample_port}"
    to_port     = "${var.dotnet_sample_port}"
    protocol    = "tcp"
    cidr_blocks = ["${data.http.whatismyip.body}/32"]
  }
}

variable "dotnet_sample_port" {
  default = "33333"
}

variable "dcos_instance_os" {
  default = "centos_7.5"
}

variable "bootstrap_instance_type" {
  default = "m5.xlarge"
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
  default = "1.13.1"
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

output "winagent-ips" {
  value = "${module.winagent.public_ips}"
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
