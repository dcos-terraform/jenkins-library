#!/usr/bin/env bash
set +o xtrace
set +o errexit

echo -e "\e[34m deploying dotnet-sample \e[0m"
"${TMP_DCOS_TERRAFORM}"/dcos marathon app add <<EOF
{
  "id": "/dotnet-sample",
  "constraints": [[ "@region", "LIKE", "windows.*" ]],
  "networks": [
    { "mode": "container/bridge" }
  ],
  "container": {
    "type": "DOCKER",
    "docker": {
      "image": "mcr.microsoft.com/dotnet/core/samples:aspnetapp",
      "forcePullImage": true
    },
    "portMappings": [
      { "hostPort": 0, "containerPort": 80 }
    ]
  },
  "instances": 1,
  "cpus": 0.1,
  "mem": 128,
  "healthChecks": [{
    "gracePeriodSeconds": 20,
    "intervalSeconds": 2,
    "maxConsecutiveFailures": 1,
    "portIndex": 0,
    "timeoutSeconds": 10,
    "delaySeconds": 15,
    "ignoreHttp1xx": false,
    "protocol": "HTTP",
    "path": "/",
    "ipProtocol": "IPv4"
  }],
  "labels": {
    "HAPROXY_GROUP": "external",
    "HAPROXY_0_VHOST": "dotnet-sample.d2iq.com"
  }
}
EOF
echo -e "\e[32m deployed dotnet-sample \e[0m"

timeout -t 600 bash <<EOF || ( echo -e "\e[31m windows agent not active... \e[0m" && exit 1 )
until ${TMP_DCOS_TERRAFORM}/dcos node list --json | jq -e '.[] | select(.attributes.os == "windows") | .active == true' > /dev/null 2>&1; do
  echo -e "\e[34m waiting for windows agent to become active \e[0m"
  sleep 10
done
EOF
return_code=$?

if [ $return_code -ne 0 ]; then
  exit 1
else
  echo -e "\e[32m windows agent is active \e[0m"
fi

timeout -t 300 bash <<EOF || ( echo -e "\e[31m failed to reach dotnet-sample... \e[0m" && exit 1 )
until ${TMP_DCOS_TERRAFORM}/dcos marathon app show dotnet-sample | jq -e '.tasksHealthy == 1' > /dev/null 2>&1; do
  echo -e "\e[34m waiting for dotnet-sample app to be healthy \e[0m"
  ${TMP_DCOS_TERRAFORM}/dcos marathon app show dotnet-sample | jq '.tasks'
  sleep 10
done
EOF
return_code=$?

if [ $return_code -ne 0 ]; then
  ${TMP_DCOS_TERRAFORM}/dcos marathon app show dotnet-sample | jq '.'
  exit 1
else
  ${TMP_DCOS_TERRAFORM}/dcos marathon app show dotnet-sample | jq '.tasks'
  echo -e "\e[32m healthy dotnet-sample \e[0m"
fi

echo -e "\e[34m curl dotnet-sample.d2iq.com at http://$(terraform output public-agents-loadbalancer) \e[0m"
set -o xtrace
curl -I \
  --silent \
  --connect-timeout 5 \
  --max-time 10 \
  --retry 5 \
  --retry-delay 0 \
  --retry-max-time 50 \
  --retry-connrefuse \
  -H "Host: dotnet-sample.d2iq.com" \
  "http://$(terraform output public-agents-loadbalancer)" | grep -q -F "HTTP/1.1 200 OK"
return_code=$?
set +o xtrace

if [ $return_code -ne 0 ]; then
  curl -I \
    --silent \
    -H "Host: dotnet-sample.d2iq.com" \
    "http://$(terraform output public-agents-loadbalancer)"
  echo -e "\e[31m curl with Host header dotnet-sample.d2iq.com failed \e[0m" && exit 1
else
  echo -e "\e[32m curl with Host header dotnet-sample.d2iq.com successful \e[0m" && return 0
fi
