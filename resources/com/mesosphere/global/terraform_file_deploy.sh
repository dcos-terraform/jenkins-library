#!/usr/bin/env bash
set +o xtrace
set -o errexit

build_task() {
  cd "${TMP_DCOS_TERRAFORM}" || exit 1
  generate_terraform_file "${GIT_URL}"
  eval "$(ssh-agent)";
  if [ ! -f "$PWD/ssh-key" ]; then
    rm -f ssh-key.pub; ssh-keygen -t rsa -b 4096 -f "${PWD}"/ssh-key -P '';
  fi
  ssh-add "${PWD}"/ssh-key
  terraform version
  terraform init -upgrade
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
  PROVIDER=$(echo "${1}" | awk -F '-' '/terraform/ {print $3}')
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
    *) echo -e "\e[31m sorry, there is no binary distribution of dcos-cli for your platform \e[0m";;
  esac
  if [ ! -f "${TMP_DCOS_TERRAFORM}/dcos" ]; then
    curl --silent -o "${TMP_DCOS_TERRAFORM}/dcos" https://downloads.dcos.io/binaries/cli/$system/latest/dcos
    chmod +x "${TMP_DCOS_TERRAFORM}/dcos"
  fi
  echo -e "\e[34m waiting for the cluster \e[0m"
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
  echo -e "\e[32m reached the cluster \e[0m"
  timeout -t 120 bash <<EOF || ( echo -e "\e[31m failed dcos cluster setup / login... \e[0m" && exit 1 )
while true; do
  ${TMP_DCOS_TERRAFORM}/dcos cluster setup "https://$(terraform output cluster-address)" --no-check --insecure --provider=dcos-users --username=bootstrapuser --password=deleteme
  if [ $? -eq 0 ]; then
    break
  fi
  echo -e "\e[34m waiting for dcos cluster setup / login to be done \e[0m"
  sleep 10
done
EOF
  "${TMP_DCOS_TERRAFORM}"/dcos package install dcos-enterprise-cli --yes || exit 1
  "${TMP_DCOS_TERRAFORM}"/dcos security org service-accounts show marathon-lb-sa --json > /dev/null 2>&1
  if [ $? -ne 0 ];then
    "${TMP_DCOS_TERRAFORM}"/dcos security org service-accounts keypair mlb-private-key.pem mlb-public-key.pem > /dev/null 2>&1 || exit 1
    "${TMP_DCOS_TERRAFORM}"/dcos security org service-accounts create -p mlb-public-key.pem -d "Marathon-LB service account" marathon-lb-sa > /dev/null 2>&1 || exit 1
    "${TMP_DCOS_TERRAFORM}"/dcos security org service-accounts show marathon-lb-sa --json > /dev/null 2>&1 || exit 1
    "${TMP_DCOS_TERRAFORM}"/dcos security secrets create-sa-secret --strict mlb-private-key.pem marathon-lb-sa marathon-lb/service-account-secret > /dev/null 2>&1 || exit 1
    rm -rf mlb-private-key.pem
    "${TMP_DCOS_TERRAFORM}"/dcos security org users grant marathon-lb-sa dcos:service:marathon:marathon:services:/ read > /dev/null 2>&1 || exit 1
    "${TMP_DCOS_TERRAFORM}"/dcos security org users grant marathon-lb-sa dcos:service:marathon:marathon:admin:events read --description "Allows access to Marathon events" > /dev/null 2>&1 || exit 1
  fi
  cat <<EOF > marathon-lb-options.json
{
    "marathon-lb": {
        "secret_name": "marathon-lb/service-account-secret",
        "marathon-uri": "https://marathon.mesos:8443"
    }
}
EOF
  "${TMP_DCOS_TERRAFORM}"/dcos package install --yes --options=marathon-lb-options.json marathon-lb > /dev/null 2>&1 || exit 1
  timeout -t 120 bash <<EOF || ( echo -e "\e[31m failed to deploy marathon-lb... \e[0m" && exit 1 )
while "${TMP_DCOS_TERRAFORM}"/dcos marathon task list --json | jq .[].healthCheckResults[].alive | grep -q -v true; do
  echo -e "\e[34m waiting for marathon-lb \e[0m"
  sleep 10
done
EOF
  echo -e "\e[32m marathon-lb alive \e[0m"
  echo -e "\e[34m deploying nginx \e[0m"
  "${TMP_DCOS_TERRAFORM}"/dcos marathon app add <<EOF
{
  "id": "nginx",
  "networks": [
    { "mode": "container/bridge" }
  ],
  "container": {
    "type": "DOCKER",
    "docker": {
      "image": "nginx:1.16.0-alpine",
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
    "gracePeriodSeconds": 10,
    "intervalSeconds": 2,
    "maxConsecutiveFailures": 1,
    "portIndex": 0,
    "timeoutSeconds": 10,
    "delaySeconds": 15,
    "protocol": "MESOS_HTTP",
    "path": "/",
    "ipProtocol": "IPv4"
  }],
  "labels":{
    "HAPROXY_GROUP":"external",
    "HAPROXY_0_VHOST": "testapp.mesosphere.com"
  }
}
EOF
  echo -e "\e[32m deployed nginx \e[0m"
  timeout -t 120 bash <<EOF || ( echo -e "\e[31m failed to reach nginx... \e[0m" && exit 1 )
while ${TMP_DCOS_TERRAFORM}/dcos marathon app show nginx | jq -e '.tasksHealthy != 1' > /dev/null 2>&1; do
  if [ "$?" -ne "0" ]; then
    echo -e "\e[34m waiting for nginx \e[0m"
    sleep 10
  fi
done
EOF
  echo -e "\e[32m healthy nginx \e[0m"
  echo -e "\e[34m curl testapp.mesosphere.com at http://$(terraform output public-agents-loadbalancer) \e[0m"
  curl -I \
    --silent \
    --connect-timeout 5 \
    --max-time 10 \
    --retry 5 \
    --retry-delay 0 \
    --retry-max-time 50 \
    --retry-connrefuse \
    -H "Host: testapp.mesosphere.com" \
    "http://$(terraform output public-agents-loadbalancer)" | grep -q -F "Server: nginx/1.16.0"
  if [ $? -ne 0 ]; then
    echo -e "\e[31m nginx not reached \e[0m" && exit 1
  else
    echo -e "\e[32m nginx reached \e[0m"
  if $WINDOWS; then
    windows_test_app
  fi
  echo -e "\e[32m Finished app deploy test! \e[0m"
}

windows_test_app(){
  "${TMP_DCOS_TERRAFORM}"/dcos marathon app remove /nginx  
  fi
  echo -e "\e[34m deploying dotnet-sample \e[0m"
  "${TMP_DCOS_TERRAFORM}"/dcos marathon app add <<EOF
{
  "labels": {
    "HAPROXY_DEPLOYMENT_GROUP": "dotnet-sample",
    "HAPROXY_0_REDIRECT_TO_HTTPS": "true",
    "HAPROXY_GROUP": "external",
    "HAPROXY_DEPLOYMENT_ALT_PORT": "80",
    "HAPROXY_0_VHOST": "dotnet-sample.mesosphere.com"
  },
  "id": "/dotnet-sample",
  "acceptedResourceRoles": [
    "*"
  ],
  "constraints": [
    [
      "os",
      "LIKE",
      "windows"
    ]
  ],
  "container": {
    "portMappings": [
      {
        "containerPort": 80,
        "hostPort": 33333,
        "protocol": "tcp",
        "servicePort": 80,
        "name": "http"
      }
    ],
    "type": "DOCKER",
    "volumes": [],
    "docker": {
      "image": "mcr.microsoft.com/dotnet/core/samples:aspnetapp",
      "forcePullImage": false,
      "privileged": false,
      "parameters": []
    }
  },
  "cpus": 1,
  "disk": 0,
  "healthChecks": [
    {
      "gracePeriodSeconds": 15,
      "ignoreHttp1xx": false,
      "intervalSeconds": 3,
      "maxConsecutiveFailures": 2,
      "portIndex": 0,
      "timeoutSeconds": 2,
      "delaySeconds": 15,
      "protocol": "HTTP",
      "path": "/",
      "ipProtocol": "IPv4"
    }
  ],
  "instances": 1,
  "maxLaunchDelaySeconds": 300,
  "mem": 1024,
  "gpus": 0,
  "networks": [
    {
      "mode": "container/bridge"
    }
  ]
}
EOF
  echo -e "\e[32m deployed dotnet-sample \e[0m"
  timeout -t 120 bash <<EOF || ( echo -e "\e[31m failed to reach dotnet-sample... \e[0m" && exit 1 )
while ${TMP_DCOS_TERRAFORM}/dcos marathon app show dotnet-sample | jq -e '.tasksHealthy != 1' > /dev/null 2>&1; do
  if [ "$?" -ne "0" ]; then
    echo -e "\e[34m waiting for dotnet-sample \e[0m"
    sleep 10
  fi
done
EOF
  echo -e "\e[32m healthy dotnet-sample \e[0m"
  echo -e "\e[34m curl dotnet-sample.mesosphere.com at http://$(terraform output public-agents-loadbalancer) \e[0m"
  curl -I -L \
  --silent \
  --connect-timeout 5 \
  --max-time 10 \
  --retry 10 \
  --retry-delay 0 \
  --retry-max-time 100 \
  --show-error \
  --retry-connrefuse \
  -H "Host: dotnet-sample.mesosphere.com" "http://$(terraform output public-agents-loadbalancer)" | grep -q -F "HTTP/1.1 200 OK"
  if [ $? -ne 0 ]; then
    echo -e "\e[31m dotnet-sample not reached \e[0m" && exit 1
  else
    echo -e "\e[32m dotnet-sample reached \e[0m"
  fi
}

main() {
  if [ $# -eq 3 ]; then
    if [ -f "ci-deploy.state"  ]; then
      eval "$(cat ci-deploy.state)"
    fi

    if [ -z "${WORKSPACE}" ]; then
      echo "Updating ENV for non-Jenkins env";
      WORKSPACE=$PWD;
      GIT_URL=$(git -C "${WORKSPACE}" remote -v | grep origin | tail -1 | awk '{print "${2}"}');
    fi

    if [ -z "${TMP_DCOS_TERRAFORM}" ] || [ ! -d "${TMP_DCOS_TERRAFORM}" ] ; then
      TMP_DCOS_TERRAFORM=$(mktemp -d -p ${WORKSPACE});
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
  fi

  WINDOWS_ARG="--windows"
  WINDOWS=false
  if [ -n "$4" -a "$4" = "$WINDOWS_ARG" ]; then
    WINDOWS=true
  fi

  case "${1}" in
    --build) build_task "${3}"; exit 0;;
    --post_build) post_build_task; exit 0;;
  esac
  echo "invalid parameter ${1}. Must be one of --build or --post_build <provider> <version>"
  exit 1
}

main "$@"
