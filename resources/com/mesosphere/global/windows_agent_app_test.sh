#!/usr/bin/env bash
set +o xtrace
set +o errexit

echo -e "\e[34m deploying dotnet-sample \e[0m"
"${TMP_DCOS_TERRAFORM}"/dcos marathon app add <<EOF
{
  "id": "/dotnet-sample",
  "constraints": [[ "os", "LIKE", "windows" ]],
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
  "labels": {
    "HAPROXY_GROUP": "external",
    "HAPROXY_0_VHOST": "dotnet-sample.d2iq.com"
  }
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
set +o xtrace
if [ $? -ne 0 ]; then
  echo -e "\e[31m curl with Host header dotnet-sample.d2iq.com failed \e[0m" && exit 1
else
  echo -e "\e[32m curl with Host header dotnet-sample.d2iq.com successful \e[0m"
fi
