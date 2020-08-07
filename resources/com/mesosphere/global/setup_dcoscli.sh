#!/usr/bin/env bash
set +o xtrace
set +o errexit

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
timeout 120 bash <<EOF || ( echo -e "\e[31m failed dcos cluster setup / login... \e[0m" && exit 1 )
while true; do
  ${TMP_DCOS_TERRAFORM}/dcos cluster setup "https://$(terraform output cluster-address)" --no-check --insecure --provider=dcos-users --username=bootstrapuser --password=deleteme
  if [ $? -eq 0 ]; then
    break
  fi
  echo -e "\e[34m waiting for dcos cluster setup / login to be done \e[0m"
  sleep 10
  done
EOF
return_code=$?

if [ $return_code -eq 0 ]; then
  "${TMP_DCOS_TERRAFORM}"/dcos package install dcos-enterprise-cli --yes || exit 1
  return_code=$?
fi

if [ $return_code -eq 0 ]; then return 0; else return 1; fi
