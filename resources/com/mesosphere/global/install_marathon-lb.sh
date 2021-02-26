#!/usr/bin/env bash
set +o xtrace
set +o errexit

"${TMP_DCOS_TERRAFORM}"/dcos security org service-accounts show marathon-lb-sa --json > /dev/null 2>&1
return_code=$?

if [ $return_code -ne 0 ]; then
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
return_code=$?

if [ $return_code -eq 0 ]; then
  timeout 120 bash <<EOF || ( echo -e "\e[31m failed to deploy marathon-lb... \e[0m" && exit 1 )
while "${TMP_DCOS_TERRAFORM}"/dcos marathon task list --json | jq .[].healthCheckResults[].alive | grep -q -v true; do
  echo -e "\e[34m waiting for marathon-lb \e[0m"
  sleep 10
  done
EOF
  return_code=$?

  if [ $return_code -eq 0 ]; then
    echo -e "\e[32m marathon-lb alive \e[0m" && return 0
  fi
fi
