#!/usr/bin/env bash

function build_task() {
  set -x
  cd ${TMP_DCOS_TERRAFORM} || exit 1
  chmod +x *.cmd # make all cmd runnable
  generate_terraform_file $GIT_URL ${CHANGE_BRANCH:-$BRANCH_NAME}
  eval "$(ssh-agent)"; if [[ ! -f "$PWD/ssh-key" ]]; then rm ssh-key.pub; ssh-keygen -t rsa -b 4096 -f $PWD/ssh-key -P ''; fi; ssh-add $PWD/ssh-key
  terraform init
  ./deploy.cmd || exit 1 # Deploy
  # deploy_test_app # disabling the test for the time being
  ./expand.cmd || exit 1 # Expand
  ./upgrade.cmd || exit 1 # Upgrade
}

function generate_terraform_file() {
  set -x
  cd ${TMP_DCOS_TERRAFORM} || exit 1
  PROVIDER=$(echo $1 | egrep  -o 'terraform-\w+-.*' | cut -d'.' -f 1 | cut -d'-' -f2)
  TF_MODULE_NAME=$(echo $1 | egrep  -o 'terraform-\w+-.*' | cut -d'.' -f 1 | cut -d'-' -f3-)
  cat <<EOF | tee Terraformfile
{
  "dcos-terraform/${TF_MODULE_NAME}/${PROVIDER}": {
    "source":"git::$1?ref=$2"
  }
}
EOF
}

function post_build_task() {
  set -x
  cd ${TMP_DCOS_TERRAFORM} || exit 1
  chmod +x *.cmd # make all cmd runnable
  ./destroy.cmd || exit 1 # Destroy
  rm -fr ${CI_DEPLOY_STATE} ${TMP_DCOS_TERRAFORM} jenkins-library
}

function deploy_test_app() {
  set -x
  case "$(uname -s).$(uname -m)" in
    Linux.x86_64) system=linux/x86-64;;
    Darwin.x86_64) system=darwin/x86-64;;
    *) echo "sorry, there is no binary distribution of dcos-cli for your platform";;
  esac
  curl https://downloads.dcos.io/binaries/cli/$system/latest/dcos -o ${TMP_DCOS_TERRAFORM}/dcos
  chmod +x ${TMP_DCOS_TERRAFORM}/dcos
  until curl -k "https://$(terraform output cluster-address)" >/dev/null 2>&1; do echo "waiting for cluster"; sleep 60; done
  sleep 120
  ${TMP_DCOS_TERRAFORM}/dcos cluster setup "http://$(terraform output cluster-address)" --no-check
  ${TMP_DCOS_TERRAFORM}/dcos package install --yes marathon-lb
  while $(${TMP_DCOS_TERRAFORM}/dcos marathon task list --json | jq '.[].healthCheckResults[].alive' | grep -v true); do echo "waiting for marathon lb"; sleep 60; done
  ${TMP_DCOS_TERRAFORM}/dcos marathon app add <<EOF
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
  while $(${TMP_DCOS_TERRAFORM}/dcos marathon app show nginx | jq -e '.tasksHealthy != 1'); do echo "waiting for nginx"; sleep 60; done
  curl -H "Host: testapp.mesosphere.com" "http://$(terraform output public-agents-loadbalancer)" -I | grep -F "Server: nginx/1.15.5"
}

function main() {
  set -x
  if [[ $# -eq 3 ]]; then
    # ENV variables
    if [[ ! -f "ci-deploy.state" ]]
    then
      TMP_DCOS_TERRAFORM=$(mktemp -d); echo "TMP_DCOS_TERRAFORM=${TMP_DCOS_TERRAFORM}" > ci-deploy.state
      LOG_STATE=${TMP_DCOS_TERRAFORM}/log_state; echo "LOG_STATE=${TMP_DCOS_TERRAFORM}/log_state" >> ci-deploy.state
      CI_DEPLOY_STATE=$PWD/ci-deploy.state; echo "CI_DEPLOY_STATE=$PWD/ci-deploy.state" >> ci-deploy.state
      DCOS_CONFIG=${TMP_DCOS_TERRAFORM}; echo "DCOS_CONFIG=${TMP_DCOS_TERRAFORM}" >> ci-deploy.state
      echo ${DCOS_CONFIG}
      git clone https://github.com/dcos-terraform/jenkins-library.git
      cp -fr jenkins-library/resources/com/mesosphere/global/terraform-file-dcos-terraform-test-examples/$2-$3/. "${TMP_DCOS_TERRAFORM}" || exit 1
    else
      eval "$(cat ci-deploy.state)"
    fi

    if [[ -z "${WORKSPACE}" ]]; then echo "Updating ENV for non-Jenkins env";
      WORKSPACE=$PWD;
      GIT_URL=$(git -C ${WORKSPACE} remote -v | grep origin | tail -1 | awk '{print $2}');
      CHANGE_BRANCH=$(git -C ${WORKSPACE} branch | awk '{print $2}');
    fi
    # End of ENV variables
  fi

  case $1 in
    --build) build_task; exit 0;;
    --post_build) post_build_task; exit 0;;
  esac
  echo "invalid parameter $1. Must be one of --build or --post_build <provider> <version>"
  exit 1
}

set +x
main "$@"
