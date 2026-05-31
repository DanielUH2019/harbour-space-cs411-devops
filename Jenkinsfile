pipeline {
    agent any

    environment {
        IMAGE = 'ttl.sh/danieluh2019:2h'
        POD = 'myapp'
        // API server reachable from the Jenkins job, and the bearer token for
        // ServiceAccount default:jenkins-robot stored as a "Secret text"
        // credential in the Jenkins credential store.
        KUBE_SERVER = 'https://kubernetes:6443'
        KUBE_CRED = 'jenkins-robot-token'
    }

    stages {
        stage('Checkout') {
            steps {
                checkout scm
            }
        }

        stage('Docker Build and Push') {
            steps {
                sh 'docker buildx build --platform linux/amd64 -t ${IMAGE} --push .'
            }
        }

        stage('Deploy to Kubernetes') {
            steps {
                // The Kubernetes CLI plugin writes a temporary kubeconfig wired to
                // KUBE_SERVER and authenticated with the jenkins-robot bearer token.
                // With no caCertificate supplied it sets insecure-skip-tls-verify.
                withKubeConfig(serverUrl: env.KUBE_SERVER, credentialsId: env.KUBE_CRED) {
                    // The :2h tag is reused every build, so apply alone would be a
                    // no-op against an unchanged spec and never pull the new image.
                    // Recreate the Pod so imagePullPolicy: Always fetches the push.
                    sh 'kubectl delete pod ${POD} --ignore-not-found --wait'
                    sh 'kubectl apply -f pod.yaml'
                    sh 'kubectl apply -f service.yaml'
                    sh 'kubectl wait --for=condition=Ready pod/${POD} --timeout=90s'
                    sh 'kubectl get pod ${POD} -o wide'
                    sh 'kubectl get service ${POD} -o wide'
                }
            }
        }
    }
}
