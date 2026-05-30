// =============================================================================
// Jenkinsfile — build a small Go HTTP service and deploy it to a target host.
//
// This is a DECLARATIVE pipeline (the `pipeline { ... }` block). Declarative
// syntax is preferred over scripted pipelines for readability: the structure
// (agent, options, stages) is fixed and self-documenting.
//
// High-level flow:
//   Validate Inputs -> Checkout -> Lint -> Build -> Deploy -> Health Check
//
// The pipeline only ORCHESTRATES. The actual deploy/health-check logic lives in
// versioned, shellcheck-able scripts under scripts/ so it can be read, linted,
// and even run by hand outside Jenkins. See scripts/README.md for the details.
// =============================================================================
pipeline {
    // `agent any` lets Jenkins run this on any available executor. The build
    // uses the Go toolchain provisioned by the `tools` block below; the deploy
    // and health-check stages need `ssh`, `scp` and `curl` on that agent.
    agent any

    options {
        timestamps()                                   // prefix log lines with a timestamp
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
        go 'go-1.24'
    }

    // Build-time parameters. Jenkins shows these as a form on "Build with
    // Parameters", and they are also settable via the API / multibranch config.
    parameters {
        string(
            name: 'TARGET_HOST',
            defaultValue: '',
            description: 'Target machine DNS name or IP address'
        )
        string(
            name: 'SSH_CREDENTIALS_ID',
            defaultValue: 'target-ssh-key',
            description: 'Jenkins "SSH Username with private key" credential ID'
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
                    // Normalise the parameters and surface them as env vars so the
                    // downstream scripts (which read $TARGET_HOST) see clean values.
                    env.TARGET_HOST = params.TARGET_HOST.trim()
                    env.SSH_CREDENTIALS_ID = params.SSH_CREDENTIALS_ID.trim()

                    if (!env.TARGET_HOST) {
                        error('TARGET_HOST must be set')
                    }
                    if (!env.SSH_CREDENTIALS_ID) {
                        error('SSH_CREDENTIALS_ID must be set')
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
            // Wipe the workspace so secrets/known_hosts/artifacts do not linger
            // on the agent between builds.
            cleanWs()
        }
    }
}
