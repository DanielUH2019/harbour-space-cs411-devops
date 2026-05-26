pipeline {
    agent any

    environment {
        IMAGE = 'ttl.sh/danieluh2019:2h'
    }

    stages {
        stage('Checkout') {
            steps {
                checkout scm
            }
        }

        stage('Docker Build') {
            steps {
                sh 'docker build -t ${IMAGE} .'
            }
        }

        stage('Docker Push') {
            steps {
                sh 'docker push ${IMAGE}'
            }
        }
    }
}
