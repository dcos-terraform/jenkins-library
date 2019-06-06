#!/usr/bin/env bash
set +o xtrace
set -o errexit

build_task() {
  cd "${TMP_DCOS_TERRAFORM}" || exit 1
  generate_terraform_file "${GIT_URL}"
  eval "$(ssh-agent)";
  if [ ! -f "$PWD/ssh-key" ]; then
    rm ssh-key.pub; ssh-keygen -t rsa -b 4096 -f "${PWD}"/ssh-key -P '';
  fi
  ssh-add "${PWD}"/ssh-key
  terraform init
  # Deploy
  export TF_VAR_dcos_version="${DCOS_VERSION}"
  terraform apply -auto-approve
  # deploying mlb and nginx test
  set +o errexit
  deploy_test_app
  set -o errexit
  # Expand
  export TF_VAR_num_public_agents="${EXPAND_NUM_PUBLIC_AGENTS:-2}"
  export TF_VAR_num_private_agents="${EXPAND_NUM_PRIVATE_AGENTS:-2}"
  terraform apply -auto-approve
  # Upgrade, only if DCOS_VERSION_UPGRADE not empty and not matching DCOS_VERSION
  if [ ! -z "${DCOS_VERSION_UPGRADE}" ] && [ "${DCOS_VERSION_UPGRADE}" != "${DCOS_VERSION}" ]; then
    export TF_VAR_dcos_version="${DCOS_VERSION_UPGRADE}"
    if [ "${1}" == "0.1.x" ]; then
      export TF_VAR_dcos_install_mode="upgrade"
    fi
    terraform apply -auto-approve
  fi
}

generate_terraform_file() {
  cd "${TMP_DCOS_TERRAFORM}" || exit 1
  PROVIDER=$(echo "${1}" | grep -E -o 'terraform-\w+-.*' | cut -d'.' -f 1 | cut -d'-' -f2)
  TF_MODULE_NAME=$(echo "${1}" | grep -E -o 'terraform-\w+-.*' | cut -d'.' -f 1 | cut -d'-' -f3-)
  # we overwrite here the source with the real content of the WORKSPACE as we can rebuild builds in that case
  cat <<EOF | tee Terraformfile
{
  "dcos-terraform/${TF_MODULE_NAME}/${PROVIDER}": {
    "source":"./../../../../.."
  }
}
EOF
}

post_build_task() {
  cd "${TMP_DCOS_TERRAFORM}" || exit 1
  terraform destroy -auto-approve
  rm -fr "${CI_DEPLOY_STATE}" "${TMP_DCOS_TERRAFORM}"
}

deploy_test_app() {
  case "$(uname -s).$(uname -m)" in
    Linux.x86_64) system=linux/x86-64;;
    Darwin.x86_64) system=darwin/x86-64;;
    *) echo -e "\e[31msorry, there is no binary distribution of dcos-cli for your platform";;
  esac
  curl https://downloads.dcos.io/binaries/cli/$system/latest/dcos -o "${TMP_DCOS_TERRAFORM}/dcos"
  chmod +x "${TMP_DCOS_TERRAFORM}/dcos"
  echo -e "\e[34mwaiting for the cluster"
  curl --insecure \
    --location \
    --silent \
    --connect-timeout 5 \
    --max-time 10 \
    --retry 30 \
    --retry-delay 0 \
    --retry-max-time 310 \
    --retry-connrefuse \
    -w "Type: %{content_type}\nCode: %{response_code}\n" \
    -o /dev/null \
    "https://$(terraform output cluster-address)"
  echo -e "\e[32mreached the cluster"
  sleep 120
  "${TMP_DCOS_TERRAFORM}"/dcos cluster setup "https://$(terraform output cluster-address)" --no-check --insecure --provider=dcos-users --username=bootstrapuser --password=deleteme || exit 1
  "${TMP_DCOS_TERRAFORM}"/dcos package install --yes marathon-lb || exit 1
  timeout 5m bash <<EOF || ( echo -e "\e[31mfailed to deploy marathon-lb"... && exit 1 )
while ${TMP_DCOS_TERRAFORM}/dcos marathon task list --json | jq .[].healthCheckResults[].alive | grep -q -v true; do
  echo -e "\e[34mwaiting for marathon-lb"
  sleep 30
done
EOF
  echo -e "\e[32mmarathon-lb alive"
  echo -e "\e[34mdeploying nginx"
  "${TMP_DCOS_TERRAFORM}"/dcos marathon app add <<EOF
{
  "id": "nginx",
  "networks": [
    { "mode": "container/bridge" }
  ],
  "container": {
    "type": "DOCKER",
    "docker": {
      "image": "nginx:1.15.5",
      "forcePullImage":true
    },
    "portMappings": [
      { "hostPort": 0, "containerPort": 80 }
    ]
  },
  "instances": 1,
  "cpus": 0.1,
  "mem": 65,
  "healthChecks": [{
      "protocol": "HTTP",
      "path": "/",
      "portIndex": 0,
      "timeoutSeconds": 10,
      "gracePeriodSeconds": 10,
      "intervalSeconds": 2,
      "maxConsecutiveFailures": 10
  }],
  "labels":{
    "HAPROXY_GROUP":"external",
    "HAPROXY_0_VHOST": "testapp.mesosphere.com"
  }
}
EOF
  echo -e "\e[32mdeployed nginx"
  timeout 5m bash <<EOF || ( echo -e \e[31mfailed to reach nginx... && exit 1 )
while $(${TMP_DCOS_TERRAFORM}/dcos marathon app show nginx | jq -e '.tasksHealthy != 1' > /dev/null 2>&1); do
  echo -e "\e[34mwaiting for nginx"
  sleep 15
done
EOF
  echo -e "\e[32mhealthy nginx"
  echo -e "\e[34mcurl testapp.mesosphere.com at http://$(terraform output public-agents-loadbalancer)"
  curl -I \
    --silent \
    --connect-timeout 5 \
    --max-time 10 \
    --retry 5 \
    --retry-delay 0 \
    --retry-max-time 50 \
    --retry-connrefuse \
    -H "Host: testapp.mesosphere.com" \
    "http://$(terraform output public-agents-loadbalancer)" \
      | grep -F "Server: nginx/1.15.5" || echo -e "\e[31mNginx not reached" && exit 1
  echo -e "\e[32mNginx reached"
}

main() {
  if [ $# -eq 3 ]; then
    # ENV variables
    if [ -f "ci-deploy.state"  ]; then
      eval "$(cat ci-deploy.state)"
    fi

    if [ -z "${TMP_DCOS_TERRAFORM}" ] || [ ! -d "${TMP_DCOS_TERRAFORM}" ] ; then
      TMP_DCOS_TERRAFORM=$(mktemp -d --tmpdir=${WORKSPACE});
      echo "TMP_DCOS_TERRAFORM=${TMP_DCOS_TERRAFORM}" > ci-deploy.state
      CI_DEPLOY_STATE=$PWD/ci-deploy.state;
      echo "CI_DEPLOY_STATE=$PWD/ci-deploy.state" >> ci-deploy.state
      DCOS_CONFIG=${TMP_DCOS_TERRAFORM};
      echo "DCOS_CONFIG=${TMP_DCOS_TERRAFORM}" >> ci-deploy.state
      export LOG_STATE=${TMP_DCOS_TERRAFORM}/log_state;
      echo "LOG_STATE=${TMP_DCOS_TERRAFORM}/log_state" >> ci-deploy.state
      echo "${DCOS_CONFIG}"
      cp -fr ${WORKSPACE}/"${2}"-"${3}"/. "${TMP_DCOS_TERRAFORM}" || exit 1
    fi

    if [ -z "${WORKSPACE}" ]; then
      echo "Updating ENV for non-Jenkins env";
      WORKSPACE=$PWD;
      GIT_URL=$(git -C "${WORKSPACE}" remote -v | grep origin | tail -1 | awk '{print "${2}"}');
    fi
    # End of ENV variables
  fi

  case "${1}" in
    --build) build_task "${3}"; exit 0;;
    --post_build) post_build_task; exit 0;;
  esac
  echo "invalid parameter ${1}. Must be one of --build or --post_build <provider> <version>"
  exit 1
}

main "$@"
