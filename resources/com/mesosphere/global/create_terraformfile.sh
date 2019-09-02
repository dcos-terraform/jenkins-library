#!/usr/bin/env bash
set +o xtrace
set +o errexit

PROVIDER="${1}"
ln -sf ${WORKSPACE} symlink_to_workspace
if [ ${TF_MODULE_NAME} == "dcos" ] || [ ${TF_MODULE_NAME} == "windows-instance" ]; then
  TF_MODULE_SOURCE="./symlink_to_workspace"
else
  TF_MODULE_SOURCE="./../../../../symlink_to_workspace"
fi
# we overwrite here the source with the real content of the WORKSPACE as we can rebuild builds in that case
cat <<EOF | tee Terraformfile
{
  "dcos-terraform/${TF_MODULE_NAME}/${PROVIDER}": {
    "source": "${TF_MODULE_SOURCE}"
  }
}
EOF
