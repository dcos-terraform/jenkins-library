#!/usr/bin/env bash
set +o xtrace
set -o errexit

build_task() {
  cd "${TMP_DCOS_TERRAFORM}" || exit 1
  # shellcheck source=./create_terraformfile.sh
  source ${WORKSPACE}/create_terraformfile.sh ${MODULEPROVIDER}
  eval "$(ssh-agent)";
  if [ ! -f "$PWD/ssh-key" ]; then
    rm -f ssh-key.pub; ssh-keygen -t rsa -b 4096 -f "${PWD}"/ssh-key -P '';
  fi
  ssh-add "${PWD}"/ssh-key
  terraform version
  terraform init -upgrade

  # Deploy
  LINENUMBER_TF_LOG=0
  export TF_VAR_dcos_version="${DCOS_VERSION}"
  terraform apply -auto-approve
  return_code=$?
  echo -e "\e[34m terraform apply return code is: ${return_code} \e[0m"
  if [ $return_code -ne 0 ]; then
    echo -e "\e[34m There was an error within 'terraform apply' ... repeat it once more"
    terraform apply -auto-approve
    return_code=$?
    echo -e "\e[34m terraform apply second run return code is: ${return_code} \e[0m"
  fi
  if [ $return_code -ne 0 ]; then echo -e "\e[31m Check the console output and terraform.log for the error! \e[0m"; exit 1; fi
  echo -e "\e[32m Finished terraform apply! \e[0m"
  LINENUMBER_TF_LOG="$(wc -l ./terraform.log)"

  # shellcheck source=./setup_dcoscli.sh
  source ${WORKSPACE}/setup_dcoscli.sh
  return_code=$?
  if [ $return_code -ne 0 ]; then exit 1; fi
  echo -e "\e[32m Finished setup_dcoscli.sh! \e[0m"

  # shellcheck source=./install_marathon-lb.sh
  source ${WORKSPACE}/install_marathon-lb.sh
  return_code=$?
  if [ $return_code -ne 0 ]; then exit 1; fi
  echo -e "\e[32m Finished install_marathon-lb.sh! \e[0m"

  # shellcheck source=./agent_app_test.sh
  source ${WORKSPACE}/agent_app_test.sh
  return_code=$?
  if [ $return_code -ne 0 ]; then exit 1; fi
  echo -e "\e[32m Finished agent_app_test.sh! \e[0m"

  echo -e "\e[32m Finished app deploy test! \e[0m"
  # Expand
  echo -e "\e[32m Starting adding more agents! \e[0m"
  export TF_VAR_num_public_agents="${EXPAND_NUM_PUBLIC_AGENTS:-2}"
  export TF_VAR_num_private_agents="${EXPAND_NUM_PRIVATE_AGENTS:-2}"
  terraform apply -auto-approve
  return_code=$?
  echo -e "\e[34m terraform apply return code is: ${return_code} \e[0m"
  if [ $return_code -ne 0 ]; then
    echo -e "\e[34m There was an error within 'terraform apply' ... repeat it once more"
    terraform apply -auto-approve
    return_code=$?
    echo -e "\e[34m terraform apply second run return code is: ${return_code} \e[0m"
  fi
  if [ $return_code -ne 0 ]; then echo -e "\e[31m Check the console output and terraform.log for the error! \e[0m"; exit 1; fi
  echo -e "\e[32m Finished adding more agents! \e[0m"
  LINENUMBER_TF_LOG="$(wc -l ./terraform.log)"

  # Upgrade, only if DCOS_VERSION_UPGRADE not empty and not matching DCOS_VERSION
  if [ ! -z "${DCOS_VERSION_UPGRADE}" ] && [ "${DCOS_VERSION_UPGRADE}" != "${DCOS_VERSION}" ]; then
    export TF_VAR_dcos_version="${DCOS_VERSION_UPGRADE}"
    if [ "${UNIVERSAL_INSTALLER_BASE_VERSION}" == "0.1.x" ]; then
      export TF_VAR_dcos_install_mode="upgrade"
    fi
    echo -e "\e[32m Starting cluster upgrade! \e[0m"
    terraform apply -auto-approve
    return_code=$?
    echo -e "\e[34m terraform apply return code is: ${return_code} \e[0m"
    if [ $return_code -ne 0 ]; then
      echo -e "\e[34m There was an error within 'terraform apply' ... repeat it once more"
      terraform apply -auto-approve
      return_code=$?
      echo -e "\e[34m terraform apply second run return code is: ${return_code} \e[0m"
    fi
    if [ $return_code -ne 0 ]; then echo -e "\e[31m Check the console output and terraform.log for the error! \e[0m"; exit 1; fi
    echo -e "\e[32m Finished cluster upgrade! \e[0m"
  fi
}

post_build_task() {
  cd "${TMP_DCOS_TERRAFORM}" || exit 1

  if [ -f ./terraform.tfstate ]; then
    cp ./terraform.tfstate ${WORKSPACE}/terraform.pre-destroy.tfstate
    terraform destroy -auto-approve
    cp ./terraform.tfstate ${WORKSPACE}/terraform.post-destroy.tfstate
  fi

  if [ -f ./terraform.log ]; then
    mv ./terraform.log ${WORKSPACE}/terraform.integration-test-step.log
  fi

  rm -fr "${CI_DEPLOY_STATE}" "${TMP_DCOS_TERRAFORM}"
}

main() {
  if [ $# -eq 4 ]; then
    if [ -f "ci-deploy.state"  ]; then
      eval "$(cat ci-deploy.state)"
    fi

    if [ -z "${WORKSPACE}" ]; then
      echo "Updating ENV for non-Jenkins env";
      WORKSPACE=$PWD;
      GIT_URL=$(git -C "${WORKSPACE}" remote -v | grep origin | tail -1 | awk '{print "${2}"}');
    fi

    if [ -z "${TMP_DCOS_TERRAFORM}" ] || [ ! -d "${TMP_DCOS_TERRAFORM}" ] ; then
      PROVIDER=${2};
      UNIVERSAL_INSTALLER_BASE_VERSION=${3};
      MODULEPROVIDER=${4};
      TMP_DCOS_TERRAFORM=$(mktemp -d -p ${WORKSPACE});
      echo "TMP_DCOS_TERRAFORM=${TMP_DCOS_TERRAFORM}" > ci-deploy.state
      CI_DEPLOY_STATE=$PWD/ci-deploy.state;
      echo "CI_DEPLOY_STATE=$PWD/ci-deploy.state" >> ci-deploy.state
      DCOS_CONFIG=${TMP_DCOS_TERRAFORM};
      echo "DCOS_CONFIG=${TMP_DCOS_TERRAFORM}" >> ci-deploy.state
      export LOG_STATE=${TMP_DCOS_TERRAFORM}/log_state;
      echo "LOG_STATE=${TMP_DCOS_TERRAFORM}/log_state" >> ci-deploy.state
      echo "${DCOS_CONFIG}"
      cp -fr ${WORKSPACE}/"${PROVIDER}"-"${UNIVERSAL_INSTALLER_BASE_VERSION}"/. "${TMP_DCOS_TERRAFORM}" || exit 1
    fi
  fi

  case "${1}" in
    --build) build_task; exit 0;;
    --post_build) post_build_task; exit 0;;
  esac
  echo "invalid parameter ${1}. Must be one of --build or --post_build <provider> <version> <moduleprovider>"
  exit 1
}

main "$@"
