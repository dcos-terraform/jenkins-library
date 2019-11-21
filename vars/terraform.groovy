#!/usr/bin/env groovy
def call() {
  pipeline {
    agent none
    environment {
      GIT_COMMITTER_NAME = 'dcos-sre-robot'
      GIT_COMMITTER_EMAIL = 'sre@mesosphere.io'
      TF_IN_AUTOMATION = '1'
      TF_LOG = 'DEBUG'
      TF_LOG_PATH = './terraform.log'
    }
    options {
      disableConcurrentBuilds()
    }
    stages {
      stage('Changelog') {
        agent { label 'terraform' }
        steps {
          script {
            def changeLogSets = currentBuild.changeSets
            for (int i = 0; i < changeLogSets.size(); i++) {
              def entries = changeLogSets[i].items
              for (int j = 0; j < entries.length; j++) {
                def entry = entries[j]
                echo "${entry.commitId} by ${entry.author} on ${new Date(entry.timestamp)}: ${entry.msg}"
                def files = new ArrayList(entry.affectedFiles)
                for (int k = 0; k < files.size(); k++) {
                  def file = files[k]
                  echo "  ${file.editType.name} ${file.path}"
                }
              }
            }
          }
        }
      }
      stage('Preparing') {
        parallel {
          stage('Terraform validate') {
            when {
              beforeAgent true
              not { changelog '.*^\\[ci-skip\\].+$' }
            }
            agent { label 'terraform' }
            steps {
              ansiColor('xterm') {
                sh """
                  #!/usr/bin/env sh
                  set +o xtrace
                  set -o errexit

                  terraform init -upgrade
                  terraform validate -check-variables=false
                """
              }
            }
          }
          stage('Download tfdescan tsv') {
            when {
              beforeAgent true
              not { changelog '.*^\\[ci-skip\\].+$' }
            }
            agent { label 'tfdescsan' }
            steps {
              ansiColor('xterm') {
                sh """
                  #!/usr/bin/env sh
                  set +o xtrace
                  set -o errexit

                  wget -O tfdescsan.tsv https://dcos-terraform-mappings.mesosphere.com/
                """
              }
              stash includes: 'tfdescsan.tsv', name: 'tfdescsan.tsv'
            }
          }
          stage("Build environment vars") {
            when {
              beforeAgent true
              not { changelog '.*^\\[ci-skip\\].+$' }
            }
            agent { label 'dcos-terraform-cicd' }
            steps {
              script {
                env.PROVIDER = sh (returnStdout: true, script: "#!/usr/bin/env sh\nset +o errexit\necho ${env.GIT_URL} | awk -F '-' '/terraform/ {print \$3}'").trim()
                env.MODULEPROVIDER = env.PROVIDER
                def m = env.PROVIDER ==~ /^(aws|azurerm|gcp)$/
                if (!m) {
                  env.PROVIDER = 'aws'
                }
                env.UNIVERSAL_INSTALLER_BASE_VERSION = sh (returnStdout: true, script: "#!/usr/bin/env sh\nset +o errexit\ngit describe --abbrev=0 --tags 2>/dev/null | sed -r 's/\\.([0-9]+)\$/.x/'").trim()
                if (!env.UNIVERSAL_INSTALLER_BASE_VERSION || env.UNIVERSAL_INSTALLER_BASE_VERSION.take(1).toInteger() >= 1) {
                  env.UNIVERSAL_INSTALLER_BASE_VERSION = getTargetBranch().tokenize('/').last()
                }
                env.IS_UNIVERSAL_INSTALLER = sh (returnStdout: true, script: "#!/usr/bin/env sh\nset +o errexit\nTFENV=\$(echo ${env.GIT_URL} | awk -F '-' '/terraform/ {print \$2}'); [ -z \$TFENV ] || echo 'YES'").trim()
                env.TF_MODULE_NAME = sh (returnStdout: true, script: "#!/usr/bin/env sh\nset +o errexit\necho ${env.GIT_URL} | grep -E -o 'terraform-\\w+-.*' | cut -d'.' -f 1 | cut -d'-' -f3-").trim()
                env.ADD_WINDOWS_AGENT = sh (returnStdout: true, script: "#!/usr/bin/env sh\nset +o errexit\nif [ ${env.TF_MODULE_NAME} == 'dcos' ] || [ ${env.TF_MODULE_NAME} == 'windows-instance' ]; then echo 'true'; else echo 'false'; fi").trim()
                if (env.PROVIDER == "gcp" || env.UNIVERSAL_INSTALLER_BASE_VERSION == "0.1.x") {
                  env.ADD_WINDOWS_AGENT = "false"
                }
              }
              ansiColor('xterm') {
                sh """
                  #!/usr/bin/env sh
                  set +o xtrace
                  set -o errexit

                  echo -e "\\e[34m Detected and set provider: ${env.PROVIDER} \\e[0m"
                  echo -e "\\e[34m Detected and set module provider: ${env.MODULEPROVIDER} \\e[0m"
                  echo -e "\\e[34m Detected universal install base version: ${env.UNIVERSAL_INSTALLER_BASE_VERSION} \\e[0m"
                  echo -e "\\e[34m Detected universal installer related build: ${env.IS_UNIVERSAL_INSTALLER} \\e[0m"
                  echo -e "\\e[34m Detected terraform module name: ${env.TF_MODULE_NAME} \\e[0m"
                  echo -e "\\e[34m Add windows agent and test it: ${env.ADD_WINDOWS_AGENT} \\e[0m"
                """
              }
            }
          }
        }
      }
      stage('Terraform FMT') {
        when {
          beforeAgent true
          not { changelog '.*^\\[ci-skip\\].+$' }
        }
        agent { label 'terraform' }
        steps {
          ansiColor('xterm') {
            sh """
              #!/usr/bin/env sh
              set +o xtrace
              set -o errexit

              for tf in *.tf; do
                echo -e "\\e[34m FMT \${tf} \\e[0m"
                terraform fmt \${tf}
              done
            """
          }
          stash includes: '*.tf', name: 'fmt'
        }
      }
      stage('Sanitize descriptions') {
        when {
          not { changelog '.*^\\[ci-skip\\].+$' }
        }
        agent { label 'tfdescsan' }
        steps {
          unstash 'fmt'
          unstash 'tfdescsan.tsv'
          ansiColor('xterm') {
            sh """
              #!/usr/bin/env sh
              set +o xtrace
              set -o errexit

              CLOUD=\$(echo \${JOB_NAME##*/terraform-} | sed -E \"s/(rm)?-.*//\")
              echo -e "\\e[34m Detected cloud: \${CLOUD} \\e[0m"
              FILES=\$(egrep -H -r '^(variable \")|^(output \")' *.tf | cut -d: -f1 | uniq | sed 's/:.*//')

              for tf in \$FILES; do
                echo -e "\\e[34m Scanning \${tf} \\e[0m"
                tfdescsan --inplace --tsv tfdescsan.tsv --var \${tf} --cloud \"\${CLOUD}\"
              done
            """
          }
          stash includes: '*.tf', name: 'tfdescsan'
        }
      }
      stage('Finishing') {
        parallel {
          stage('README.md') {
            when {
              beforeAgent true
              not { changelog '.*^\\[ci-skip\\].+$' }
            }
            agent { label 'terraform' }
            steps {
              unstash 'tfdescsan'
              ansiColor('xterm') {
                sh """
                  #!/usr/bin/env sh
                  set +o xtrace
                  set -o errexit

                  terraform-docs --sort-inputs-by-required md ./ > README.md
                """
              }
              stash includes: 'README.md', name: 'readme'
            }
          }
          stage('Integration Test') {
            when {
              beforeAgent true
              expression { env.UNIVERSAL_INSTALLER_BASE_VERSION != "null" }
              expression { env.UNIVERSAL_INSTALLER_BASE_VERSION != "" }
              environment name: 'IS_UNIVERSAL_INSTALLER', value: 'YES'
              not { changelog '.*^\\[ci-skip\\].+$' }
            }
            agent { label 'dcos-terraform-cicd' }
            environment {
              DCOS_VERSION = '2.0.0'
              // DCOS_VERSION_UPGRADE = '2.0.0'
              GOOGLE_APPLICATION_CREDENTIALS = credentials('dcos-terraform-ci-gcp')
              GOOGLE_PROJECT = 'massive-bliss-781'
              GOOGLE_REGION = 'us-west1'
              TF_VAR_dcos_license_key_contents = credentials('dcos-license')
            }
            steps {
              ansiColor('xterm') {
                withCredentials([
                  [$class: 'AmazonWebServicesCredentialsBinding', credentialsId: 'dcos-terraform-ci-aws'],
                  azureServicePrincipal(
                    credentialsId: 'dcos-terraform-ci-azure',
                    subscriptionIdVariable: 'ARM_SUBSCRIPTION_ID',
                    clientIdVariable: 'ARM_CLIENT_ID',
                    clientSecretVariable: 'ARM_CLIENT_SECRET',
                    tenantIdVariable: 'ARM_TENANT_ID'
                  )
                ]) {
                  sh """
                    #!/usr/bin/env sh
                    set +o xtrace
                    set -o errexit

                    mkdir -p ${WORKSPACE}/${PROVIDER}-${UNIVERSAL_INSTALLER_BASE_VERSION}
                  """
                  script {
                    def main_tf = ""
                    if (env.ADD_WINDOWS_AGENT.toBoolean() == true) {
                      main_tf = libraryResource "com/mesosphere/global/terraform-file-dcos-terraform-test-examples/${PROVIDER}-windows-agent-0.2.x/main.tf"
                    } else {
                      main_tf = libraryResource "com/mesosphere/global/terraform-file-dcos-terraform-test-examples/${PROVIDER}-${UNIVERSAL_INSTALLER_BASE_VERSION}/main.tf"
                    }
                    writeFile file: "${PROVIDER}-${UNIVERSAL_INSTALLER_BASE_VERSION}/main.tf", text: main_tf
                  }
                  script {
                    def integration_test = libraryResource 'com/mesosphere/global/integration_test.sh'
                    writeFile file: 'integration_test.sh', text: integration_test
                    def create_terraformfile = libraryResource 'com/mesosphere/global/create_terraformfile.sh'
                    writeFile file: 'create_terraformfile.sh', text: create_terraformfile
                    def setup_dcoscli = libraryResource 'com/mesosphere/global/setup_dcoscli.sh'
                    writeFile file: 'setup_dcoscli.sh', text: setup_dcoscli
                    def install_marathon_lb = libraryResource 'com/mesosphere/global/install_marathon-lb.sh'
                    writeFile file: 'install_marathon-lb.sh', text: install_marathon_lb
                    def agent_app_test = libraryResource 'com/mesosphere/global/agent_app_test.sh'
                    writeFile file: 'agent_app_test.sh', text: agent_app_test
                    def windows_agent_app_test = libraryResource 'com/mesosphere/global/windows_agent_app_test.sh'
                    writeFile file: 'windows_agent_app_test.sh', text: windows_agent_app_test
                  }
                  sh """
                    #!/usr/bin/env sh
                    set +o xtrace
                    set -o errexit

                    bash ./integration_test.sh --build ${MODULEPROVIDER} ${UNIVERSAL_INSTALLER_BASE_VERSION}
                  """
                }
              }
            }
            post {
              always {
                ansiColor('xterm') {
                  withCredentials([
                    [$class: 'AmazonWebServicesCredentialsBinding', credentialsId: 'dcos-terraform-ci-aws'],
                    azureServicePrincipal(
                      credentialsId: 'dcos-terraform-ci-azure',
                      subscriptionIdVariable: 'ARM_SUBSCRIPTION_ID',
                      clientIdVariable: 'ARM_CLIENT_ID',
                      clientSecretVariable: 'ARM_CLIENT_SECRET',
                      tenantIdVariable: 'ARM_TENANT_ID'
                    )
                  ]) {
                    script {
                      def integration_test = libraryResource 'com/mesosphere/global/integration_test.sh'
                      writeFile file: 'integration_test.sh', text: integration_test
                    }
                    sh """
                      #!/usr/bin/env sh
                      set +o xtrace
                      set -o errexit

                      bash ./integration_test.sh --post_build ${MODULEPROVIDER} ${UNIVERSAL_INSTALLER_BASE_VERSION}
                    """
                    archiveArtifacts artifacts: 'terraform.*.tfstate', fingerprint: true
                    archiveArtifacts artifacts: 'terraform.integration-test-step.log', fingerprint: true
                  }
                }
              }
            }
          }
        }
      }
      stage('Pushing') {
        when {
          beforeAgent true
          not { changeRequest() }
          not { changelog '.*^\\[ci-skip\\].+$' }
        }
        agent { label 'terraform' }
        environment {
          GITHUB_API_TOKEN = credentials('4082945c-6a9c-4a9d-8b46-b4a44462b082')
        }
        steps {
          unstash 'tfdescsan'
          unstash 'readme'
          ansiColor('xterm') {
            sh """
              #!/usr/bin/env sh
              set +o xtrace
              set -o errexit

              rm -f *.log

              git add .

              if ! git diff-index --quiet HEAD --; then
                git ls-files --other --modified --exclude-standard

                git config --local --add credential.helper 'store --file=${WORKSPACE}/.git-credentials'
                GITDOMAIN=\$(git config --get remote.origin.url | cut -f 3 -d "/")
                echo "https://${GIT_COMMITTER_NAME}:${GITHUB_API_TOKEN}@\${GITDOMAIN}" >> ${WORKSPACE}/.git-credentials
                git config --local user.name '${GIT_COMMITTER_NAME}'
                git config --local user.email '${GIT_COMMITTER_EMAIL}'

                GIT_COMMIT_HASH=\$(git --no-pager log -1 --pretty=format:'%H')
                AUTHOR=\$(git --no-pager log -1 --format='%an <%ae>' \${GIT_COMMIT_HASH})

                git commit --author="'\${AUTHOR}'" -m "CI - [ci-skip] - updated files"
                git push origin HEAD:${BRANCH_NAME}
              fi
            """
          }
        }
        post {
          always {
            ansiColor('xterm') {
              sh """
                #!/usr/bin/env sh
                set +o xtrace
                set +o errexit

                git config --local --remove-section credential
                rm -f ${WORKSPACE}/.git-credentials
              """
            }
          }
        }
      }
    }
  }
}
