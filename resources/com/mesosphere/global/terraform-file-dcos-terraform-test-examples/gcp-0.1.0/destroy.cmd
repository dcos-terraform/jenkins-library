#!/bin/sh

terraform destroy -auto-approve || exit 1 # Destroy
