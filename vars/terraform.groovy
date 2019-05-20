#!/usr/bin/env groovy
def call() {
  pipeline {
    agent none
    environment { TARGET_BRANCH = getTargetBranch() }
    stages {
      stage('Run Tests') {
        parallel {
          stage('Terraform FMT') {
            agent { label 'terraform' }
            steps {
              ansiColor('xterm') { sh """
                  #!/usr/bin/env sh
                  set +o xtrace
                  set -o errexit

                  for tf in *.tf; do
                    echo "FMT checking \${tf}"
                    terraform fmt --check --diff \${tf}
                  done
                """ }
            }
          }
          stage('Terraform validate') {
            agent { label 'terraform' }
            steps {
              ansiColor('xterm') { sh """
                  #!/usr/bin/env sh
                  set +o xtrace
                  set -o errexit

                  terraform init --upgrade
                  terraform validate -check-variables=false
                """ }
            }
          }
          stage('Validate README go generated') {
            agent { label 'terraform' }
            steps {
              ansiColor('xterm') { sh """
                  #!/usr/bin/env sh
                  set +o xtrace
                  set -o errexit

                  terraform-docs --sort-inputs-by-required md ./ > README.md
                  git --no-pager diff --exit-code
                """ }
            }
          }
        }
      }
      stage('Download tfdescan tsv') {
        agent { label 'tfdescsan' }
        steps {
          ansiColor('xterm') {
            sh """
              #!/usr/bin/env sh
              set +o xtrace
              set -o errexit

              wget -O tfdescsan.tsv https://dcos-terraform-mappings.mesosphere.com/
            """
            stash includes: 'tfdescsan.tsv', name: 'tfdescsan.tsv'
          }
        }
      }
      stage('Validate descriptions') {
        agent { label 'tfdescsan' }
        steps {
          ansiColor('xterm') {
            unstash 'tfdescsan.tsv'
            sh """
              #!/usr/bin/env sh
              set +o xtrace
              set -o errexit

              CLOUD=\$(echo \${JOB_NAME##*/terraform-} | sed -E \"s/(rm)?-.*//\")
              echo "Detected cloud: \${CLOUD}"
              FILES=\$(egrep -H -r '^(variable \")|^(output \")' *.tf | cut -d: -f1 | uniq | sed 's/:.*//')

              for tf in \$FILES; do
                echo "Scanning \${tf}"
                tfdescsan --test --tsv tfdescsan.tsv --var \${tf} --cloud \"\${CLOUD}\"
              done
            """
          }
        }
      }
      stage("Check Environment Conditions") {
        agent { label 'dcos-terraform-cicd' }
        steps {
          script {
            env.PROVIDER = sh (returnStdout: true, script: "echo ${env.GIT_URL} | egrep -o 'terraform-\\w+-.*'| cut -d'-' -f2").trim()
            env.UNIVERSAL_INSTALLER_BASE_VERSION = sh (returnStdout: true, script: "echo ${env.TARGET_BRANCH} | cut -d'/' -f2 -s").trim()
            env.IS_UNIVERSAL_INSTALLER = sh (returnStdout: true, script: "TFENV=\$(echo ${env.GIT_URL} | egrep -o 'terraform-\\w+-.*'); [ -z \$TFENV ] || echo 'YES'").trim()
          }
        }
      }
      stage('Integration Test') {
        when {
          allOf {
            expression { env.UNIVERSAL_INSTALLER_BASE_VERSION != "null" }
            expression { env.UNIVERSAL_INSTALLER_BASE_VERSION != "" }
            environment name: 'IS_UNIVERSAL_INSTALLER', value: 'YES'
          }
        }
        agent { label 'dcos-terraform-cicd' }
        steps {
          ansiColor('xterm') {
            withCredentials([
              [$class: 'AmazonWebServicesCredentialsBinding', credentialsId: 'dcos-terraform-ci-aws'],
              azureServicePrincipal('dcos-terraform-ci-azure'),
              file(credentialsId: 'dcos-terraform-ci-gcp', variable: 'GOOGLE_APPLICATION_CREDENTIALS')
            ]) {
              script {
                def ci_script_bash = libraryResource 'com/mesosphere/global/terraform_file_deploy.sh'
                writeFile file: 'ci-deploy.sh', text: ci_script_bash
              }
              sh """
                #!/usr/bin/env sh
                set +o xtrace
                set -o errexit

                sh ./ci-deploy.sh --build ${PROVIDER} ${UNIVERSAL_INSTALLER_BASE_VERSION}
              """
            }
          }
        }
        post {
          always {
            ansiColor('xterm') {
              withCredentials([
                [$class: 'AmazonWebServicesCredentialsBinding', credentialsId: 'dcos-terraform-ci-aws'],
                azureServicePrincipal('dcos-terraform-ci-azure'),
                file(credentialsId: 'dcos-terraform-ci-gcp', variable: 'GOOGLE_APPLICATION_CREDENTIALS')
              ]) {
                script {
                  def ci_script_bash = libraryResource 'com/mesosphere/global/terraform_file_deploy.sh'
                  writeFile file: 'ci-deploy.sh', text: ci_script_bash
                }
                sh """
                  #!/usr/bin/env sh
                  set +o xtrace
                  set -o errexit

                  sh ./ci-deploy.sh --post_build ${PROVIDER} ${UNIVERSAL_INSTALLER_BASE_VERSION}
                """
              }
            }
          }
        }
      }
    }
  }
}

def getTargetBranch() {
  return env.CHANGE_TARGET ? env.CHANGE_TARGET : env.BRANCH_NAME
}
