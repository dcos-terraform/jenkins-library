#!/usr/bin/env bash

if [[ ! -f "ci-deploy.state" ]]
then
	TMP_DCOS_TERRAFORM=$(mktemp -d); echo "TMP_DCOS_TERRAFORM=${TMP_DCOS_TERRAFORM}" > ci-deploy.state
	LOG_STATE=${TMP_DCOS_TERRAFORM}/log_state; echo "LOG_STATE=${TMP_DCOS_TERRAFORM}/log_state" >> ci-deploy.state
	CI_DEPLOY_STATE=$PWD/ci-deploy.state; echo "CI_DEPLOY_STATE=$PWD/ci-deploy.state" >> ci-deploy.state
	DCOS_CONFIG=${TMP_DCOS_TERRAFORM}; echo "DCOS_CONFIG=${TMP_DCOS_TERRAFORM}" >> ci-deploy.state
	echo ${DCOS_CONFIG}
	git clone --single-branch --branch terraform_file_method_ci_deploy https://github.com/dcos-terraform/jenkins-library.git
  cp -fr jenkins-library/resources/com/mesosphere/global/terraform-file-dcos-terraform-test-examples/$2-$3/ "${TMP_DCOS_TERRAFORM}"
else
	eval "$(cat ci-deploy.state)"
fi

if [[ -z "${WORKSPACE}" ]]; then echo "Updating ENV for non-Jenkins env"; WORKSPACE=$PWD; GIT_URL=$(git -C ${WORKSPACE} remote -v | grep origin | tail -1 | awk '{print $2}'); fi

function build_task() {
  set -x
	cd ${TMP_DCOS_TERRAFORM} || exit 1
	terraform init
	#rm -fr ${TMP_DCOS_TERRAFORM}/"$(grep "$(echo ${GIT_URL} | cut -d'/' -f 5 | cut -d'.' -f1)" ${TMP_DCOS_TERRAFORM}/.gitmodules -B1 | grep path | cut -d' ' -f3)"
	#cp -fr ${WORKSPACE} ${TMP_DCOS_TERRAFORM}/"$(grep "$(echo ${GIT_URL} | cut -d'/' -f 5 | cut -d'.' -f1)" ${TMP_DCOS_TERRAFORM}/.gitmodules -B1 | grep path | cut -d' ' -f3)"

	## Reuse existing state rather than create a new one
	#if [[ ! -f "${LOG_STATE}" ]]; then
	#	PROVIDER="$(git diff master --name-only | grep -E '^modules|^example' | cut -d'/' -f2 | grep -vE 'null|template|localfile|.git*' | sort | uniq | xargs)" make tenv | tee ${LOG_STATE}
	#fi

	#for i in $(grep -E '_output.*examples' ${LOG_STATE} | sort | uniq | cut -d' ' -f2); do
	#	cd $i || exit 1
	#	eval "$(ssh-agent)"; if [[ ! -f "$PWD/ssh-key" ]]; then rm ssh-key.pub; ssh-keygen -t rsa -b 4096 -f $PWD/ssh-key -P ''; fi; ssh-add $PWD/ssh-key
		./deploy.cmd # Deploy
		# deploy_test_app # disabling the test for the time being
		./expand.cmd # Expand
	  ./upgrade.cmd # Upgrade
	#	cd - || exit 1
	#done
}

function post_build_task() {
  set -x
	cd ${TMP_DCOS_TERRAFORM} || exit 1
	for i in $(grep -E '_output.*examples' ${LOG_STATE} | sort | uniq | cut -d' ' -f2); do
		cd $i || exit 1
		./destroy.cmd # Destroy
		cd - || exit 1
	done
	rm -fr ${CI_DEPLOY_STATE} ${TMP_DCOS_TERRAFORM}
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
		case $1 in
			--build) build_task; exit 0;;
			--post_build) post_build_task; exit 0;;
		esac
		echo "invalid parameter $1. Must be one of --build or --post_build"
		exit 1
	fi
}

set +x
main "$@"
