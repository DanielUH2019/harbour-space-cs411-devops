// =============================================================================
// Jenkinsfile — build a small Go HTTP service and deploy it to a target host.
//
// This is a DECLARATIVE pipeline (the `pipeline { ... }` block). Declarative
// syntax is preferred over scripted pipelines for readability: the structure
// (agent, options, stages) is fixed and self-documenting.
//
// High-level flow:
//   Validate Inputs -> Checkout -> Provision (Terraform) -> Lint -> Build
//     -> Deploy -> Health Check
//
// The Provision stage runs Terraform (terraform/) to create the AWS EC2 target
// and feeds its public IP to the Deploy stage as TARGET_HOST. State lives in S3
// (terraform/main.tf backend), so it survives this pipeline's workspace wipe and
// a re-run will NOT create a second instance.
//
// The pipeline only ORCHESTRATES. The actual deploy/health-check logic lives in
// versioned, shellcheck-able scripts under scripts/ so it can be read, linted,
// and even run by hand outside Jenkins. See scripts/README.md for the details.
//
// AGENT PREREQUISITES: `terraform` (>= 1.10), `aws` CLI and `ssh-keygen` on PATH,
// plus `ssh`/`scp`/`curl` (already needed by the deploy). The Go toolchain comes
// from `tools`. The `aws` CLI is used once to create the S3 state bucket.
// =============================================================================
pipeline {
    // `agent any` lets Jenkins run this on any available executor. The build
    // uses the Go toolchain provisioned by the `tools` block below; the deploy
    // and health-check stages need `ssh`, `scp` and `curl` on that agent.
    agent any

    options {
        disableConcurrentBuilds()                      // never deploy two builds at once
        timeout(time: 10, unit: 'MINUTES')             // abort if something hangs
        buildDiscarder(logRotator(numToKeepStr: '20')) // keep only the last 20 builds
    }

    // The `tools` block makes Jenkins install/provision a named tool and put it
    // on PATH for every stage. This PINS the Go version so all agents build with
    // the same compiler (reproducible builds).
    //
    // PREREQUISITE: configure a Go installation named exactly 'go-1.24' under
    //   Manage Jenkins -> Tools -> Go installations (requires the "Go" plugin).
    tools {
        go '1.24.1'
    }

    // Build-time parameters. Jenkins shows these as a form on "Build with
    // Parameters", and they are also settable via the API / multibranch config.
    parameters {
        string(
            name: 'SSH_CREDENTIALS_ID',
            defaultValue: 'target-ssh-key',
            description: 'Jenkins "SSH Username with private key" credential ID. ' +
                'Username MUST be "ubuntu" (the Ubuntu AMI default login). The ' +
                'instance is provisioned to trust the PUBLIC half of this key.'
        )
        string(
            name: 'AWS_CREDENTIALS_ID',
            defaultValue: 'aws-deploy-keys',
            description: 'Jenkins "Username with password" credential holding the ' +
                'AWS access key ID (username) and secret access key (password), ' +
                'used by Terraform to provision the EC2 target.'
        )
    }

    // Values shared across stages. Exported as environment variables into every
    // `sh` step, which is how the scripts under scripts/ receive their config.
    environment {
        ARTIFACT = 'build/main-linux-static' // path to the built binary on the agent
        APP_PORT = '4444'                    // port the service listens on (see main.go)
        REMOTE_APP_DIR = '/opt/myapp'        // install dir on the target
        SERVICE_NAME = 'myapp'               // systemd service name
        SERVICE_USER = 'myapp'               // unprivileged user the service runs as
        TF_DIR = 'terraform'                 // directory holding the Terraform config
        TF_IN_AUTOMATION = 'true'            // quieter Terraform output in CI
        // S3 state backend. MUST match the backend "s3" block in terraform/main.tf.
        // The Provision stage creates this bucket if it does not exist yet, so the
        // whole flow is driven from Jenkins with no manual bootstrap.
        TF_STATE_BUCKET = 'danielc-cs411-tfstate'
        TF_STATE_REGION = 'us-east-1'
        // Passed to Terraform as TF_VAR_budget_alert_email so the billing-budget
        // resource is created when provisioning from the pipeline (the laptop
        // reads it from terraform.tfvars, which is gitignored / not in the checkout).
        BUDGET_ALERT_EMAIL = 'daniel.cardenas@student.harbour.space'
        // Common SSH/SCP flags. BatchMode prevents interactive prompts (so the
        // build fails fast instead of hanging); accept-new trusts a host's key on
        // first contact and pins it in a workspace-local known_hosts file.
        SSH_OPTIONS = '-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=.ssh/known_hosts'
        HEALTH_CHECK_RETRIES = '30'          // health-check: max attempts
        HEALTH_CHECK_SLEEP_SECONDS = '2'     // health-check: delay between attempts
    }

    stages {
        // --- Fail fast on bad input before doing any real work ---------------
        stage('Validate Inputs') {
            steps {
                script {
                    // Normalise the credential parameters. TARGET_HOST is no longer
                    // an input — the Provision stage derives it from Terraform.
                    env.SSH_CREDENTIALS_ID = params.SSH_CREDENTIALS_ID.trim()
                    env.AWS_CREDENTIALS_ID = params.AWS_CREDENTIALS_ID.trim()

                    if (!env.SSH_CREDENTIALS_ID) {
                        error('SSH_CREDENTIALS_ID must be set')
                    }
                    if (!env.AWS_CREDENTIALS_ID) {
                        error('AWS_CREDENTIALS_ID must be set')
                    }
                }
            }
        }

        // --- Get the source. For multibranch/SCM jobs this is implicit, but an
        //     explicit checkout keeps a plain pipeline job reproducible too. ---
        stage('Checkout') {
            steps {
                checkout scm
            }
        }

        // --- Provision the EC2 target with Terraform -------------------------
        // Runs FIRST (before lint/build) so the instance is booting while those
        // run, leaving it ready for SSH by the time Deploy starts. Sets
        // env.TARGET_HOST from the Terraform output for the downstream scripts.
        stage('Provision') {
            steps {
                withCredentials([
                    // AWS keys for Terraform (and the S3 state backend).
                    usernamePassword(
                        credentialsId: env.AWS_CREDENTIALS_ID,
                        usernameVariable: 'AWS_ACCESS_KEY_ID',
                        passwordVariable: 'AWS_SECRET_ACCESS_KEY'
                    ),
                    // The deploy key: we derive its PUBLIC half so the instance
                    // authorizes exactly the key Jenkins later logs in with.
                    sshUserPrivateKey(
                        credentialsId: env.SSH_CREDENTIALS_ID,
                        keyFileVariable: 'SSH_KEY',
                        usernameVariable: 'SSH_USER'
                    )
                ]) {
                    dir(env.TF_DIR) {
                        sh '''#!/usr/bin/env bash
                            set -euo pipefail

                            # Ensure the S3 state bucket exists (one-time, idempotent)
                            # so the whole flow is self-contained in Jenkins. Terraform
                            # cannot create its own backend bucket, so we do it here
                            # with the AWS CLI before `terraform init`.
                            if ! aws s3api head-bucket --bucket "$TF_STATE_BUCKET" 2>/dev/null; then
                                echo "Creating state bucket $TF_STATE_BUCKET ..."
                                # us-east-1 must NOT pass a LocationConstraint.
                                if [ "$TF_STATE_REGION" = "us-east-1" ]; then
                                    aws s3api create-bucket --bucket "$TF_STATE_BUCKET" --region "$TF_STATE_REGION"
                                else
                                    aws s3api create-bucket --bucket "$TF_STATE_BUCKET" --region "$TF_STATE_REGION" \
                                        --create-bucket-configuration "LocationConstraint=$TF_STATE_REGION"
                                fi
                                aws s3api put-bucket-versioning --bucket "$TF_STATE_BUCKET" \
                                    --versioning-configuration Status=Enabled
                                aws s3api put-public-access-block --bucket "$TF_STATE_BUCKET" \
                                    --public-access-block-configuration \
                                    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
                            fi

                            # Derive the public key from the Jenkins SSH credential.
                            # Single source of truth: the box trusts the same key
                            # the Deploy stage authenticates with.
                            ssh-keygen -y -f "$SSH_KEY" > deploy.pub
                            chmod 600 deploy.pub

                            export TF_VAR_public_key_path="deploy.pub"
                            export TF_VAR_budget_alert_email="$BUDGET_ALERT_EMAIL"

                            terraform init -input=false
                            terraform apply -auto-approve -input=false
                        '''
                        // Capture the public IP for the deploy/health-check scripts.
                        script {
                            env.TARGET_HOST = sh(
                                script: 'terraform output -raw public_ip',
                                returnStdout: true
                            ).trim()
                            echo "Provisioned EC2 target at ${env.TARGET_HOST}"
                        }
                    }

                    // A freshly booted instance may not accept SSH yet; wait for
                    // port 22 so the Deploy stage's ssh-keyscan does not fail.
                    sh '''#!/usr/bin/env bash
                        set -euo pipefail
                        echo "Waiting for sshd on ${TARGET_HOST}:22 ..."
                        for i in $(seq 1 40); do
                            if (exec 3<>"/dev/tcp/${TARGET_HOST}/22") 2>/dev/null; then
                                exec 3>&-
                                echo "sshd is accepting connections."
                                exit 0
                            fi
                            sleep 5
                        done
                        echo "Timed out waiting for sshd on ${TARGET_HOST}" >&2
                        exit 1
                    '''
                }
            }
        }

        // --- Static checks: cheap, run before the (slower) build -------------
        stage('Lint') {
            steps {
                sh '''#!/usr/bin/env bash
                    set -euo pipefail

                    # Verify Go formatting. `gofmt -l` lists files that are NOT
                    # formatted; if it prints anything, fail with a hint.
                    unformatted="$(gofmt -l main.go)"
                    if [ -n "$unformatted" ]; then
                        echo "These files need 'gofmt -w': $unformatted" >&2
                        exit 1
                    fi

                    # Lint the deploy scripts if shellcheck is available. We skip
                    # (rather than fail) when it is not installed, so the pipeline
                    # still works on a minimal agent — install shellcheck to enable.
                    if command -v shellcheck >/dev/null 2>&1; then
                        shellcheck scripts/*.sh
                    else
                        echo "shellcheck not installed on agent; skipping shell lint"
                    fi
                '''
            }
        }

        // --- Compile the binary statically for Linux -------------------------
        stage('Build') {
            steps {
                sh '''#!/usr/bin/env bash
                    set -euo pipefail

                    # `go vet` catches suspicious constructs the compiler accepts.
                    go vet main.go

                    mkdir -p build
                    # CGO_ENABLED=0 -> fully static binary (no libc dependency), so
                    #   it runs on any Linux regardless of glibc version.
                    # -trimpath       -> strip local paths from the binary (reproducible).
                    # -ldflags='-s -w'-> drop debug/symbol info to shrink the binary.
                    CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
                        go build -trimpath -ldflags='-s -w' -o "$ARTIFACT" main.go
                '''
                // Keep the binary with the build for traceability / rollback.
                archiveArtifacts artifacts: env.ARTIFACT, fingerprint: true
            }
        }

        // --- Ship the binary to the target and (re)start the service ---------
        stage('Deploy') {
            steps {
                // `withCredentials` injects the SSH private key as a temp file
                // ($SSH_KEY) and the username ($SSH_USER) for the duration of the
                // block, and masks them in the build log. NEVER hard-code secrets.
                withCredentials([
                    sshUserPrivateKey(
                        credentialsId: env.SSH_CREDENTIALS_ID,
                        keyFileVariable: 'SSH_KEY',
                        usernameVariable: 'SSH_USER'
                    )
                ]) {
                    // All the heavy lifting lives in the script (see scripts/).
                    sh 'bash scripts/deploy.sh'
                }
            }
        }

        // --- Confirm the freshly deployed service actually serves traffic ----
        stage('Health Check') {
            steps {
                sh 'bash scripts/health-check.sh'
            }
        }
    }

    // `post` runs after the stages regardless of outcome. Use it for
    // notifications and cleanup. Extend the `failure`/`success` blocks with
    // Slack/email notifiers as needed.
    post {
        success {
            echo "Deploy of ${env.SERVICE_NAME} to ${env.TARGET_HOST} succeeded."
        }
        failure {
            echo "Pipeline FAILED for ${env.SERVICE_NAME} -> ${env.TARGET_HOST}. Check the stage logs above."
        }
        always {
            // Wipe the workspace so secrets/known_hosts/artifacts/deploy.pub do
            // not linger on the agent between builds. This is SAFE because the
            // Terraform state lives in S3, not the workspace — wiping it does not
            // lose track of the instance (re-init pulls state back from S3).
            deleteDir()
        }
    }
}
