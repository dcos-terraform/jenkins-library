#!/usr/bin/env bash
set +o xtrace
set +o errexit

echo -e "\e[34m deploying nginx \e[0m"
cat <<EOF > nginx-default.conf
server {
  listen       80;
  server_name  _;

  location / {
    root   /usr/share/nginx/html;
    index  index.html index.htm;
    add_header X-Testheader I-am-reachable;
  }

  error_page   500 502 503 504  /50x.html;
  location = /50x.html {
    root   /usr/share/nginx/html;
  }
}
EOF
BASE64_CONFIG=$(cat nginx-default.conf | base64 | sed ':a;N;$!ba;s/\n//g')
"${TMP_DCOS_TERRAFORM}"/dcos marathon app add <<EOF
{
  "id": "nginx",
  "cmd": "echo -n \${DEFAULT_CONF} | base64 -d > /etc/nginx/conf.d/default.conf; nginx -g 'daemon off;'",
  "env": {
    "DEFAULT_CONF": "${BASE64_CONFIG}"
  },
  "networks": [
    { "mode": "container/bridge" }
  ],
  "container": {
    "type": "DOCKER",
    "docker": {
      "image": "nginx:1.16.0-alpine",
      "forcePullImage": true
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
  "labels": {
    "HAPROXY_GROUP": "external",
    "HAPROXY_0_VHOST": "testapp.d2iq.com"
  }
}
EOF
echo -e "\e[32m deployed nginx \e[0m"
timeout 120 bash <<EOF || ( echo -e "\e[31m failed to reach nginx... \e[0m" && exit 1 )
while ${TMP_DCOS_TERRAFORM}/dcos marathon app show nginx | jq -e '.tasksHealthy != 1' > /dev/null 2>&1; do
  echo -e "\e[34m waiting for nginx \e[0m"
  sleep 10
done
EOF
return_code=$?

if [ $return_code -eq 0 ]; then
  echo -e "\e[32m healthy nginx \e[0m"
  echo -e "\e[34m curl testapp.d2iq.com at http://$(terraform output public-agents-loadbalancer) \e[0m"
  set -o xtrace
  curl -I \
    --silent \
    --connect-timeout 5 \
    --max-time 10 \
    --retry 5 \
    --retry-delay 0 \
    --retry-max-time 50 \
    --retry-connrefuse \
    -H "Host: testapp.d2iq.com" \
    "http://$(terraform output public-agents-loadbalancer)" | grep -q -F "x-testheader: I-am-reachable"
  return_code=$?
  set +o xtrace
fi

if [ $return_code -ne 0 ]; then
  curl -I \
    --silent \
    -H "Host: testapp.d2iq.com" \
    "http://$(terraform output public-agents-loadbalancer)"
  echo -e "\e[31m curl with Host header testapp.d2iq.com failed \e[0m" && exit 1
else
  echo -e "\e[32m curl with Host header testapp.d2iq.com successful \e[0m" && return 0
fi
