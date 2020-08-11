#!/usr/bin/env bash
set +o xtrace
set +o errexit

PROVIDER="${1}"
UNIVERSAL_EXACT_VERSION="${2}"
ln -sf ${WORKSPACE} symlink_to_workspace
if [ ${TF_MODULE_NAME} == "dcos" ]; then
  TF_MODULE_SOURCE="./symlink_to_workspace"
else
  TF_MODULE_SOURCE="./../../../../symlink_to_workspace"
fi


# we overwrite here the source with the real content of the WORKSPACE as we can rebuild builds in that case
cat <<EOF | tee Terraformfile
{
  "dcos-terraform/${TF_MODULE_NAME}/${PROVIDER}": {
    "source": "${TF_MODULE_SOURCE}",
    "set_version": "${UNIVERSAL_EXACT_VERSION}"
  }
}
EOF
