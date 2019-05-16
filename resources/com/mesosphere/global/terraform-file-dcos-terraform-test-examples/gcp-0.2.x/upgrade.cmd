#!/bin/sh

terraform apply -var num_private_agents=2 -var num_public_agents=2 -var dcos_version=1.12.3 -auto-approve || exit 1 # Upgrade
