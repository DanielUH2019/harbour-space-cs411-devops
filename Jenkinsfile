pipeline {
    agent any

    environment {
        IMAGE = 'ttl.sh/danieluh2019:2h'
        CONTAINER = 'myapp'
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

        stage('Deploy') {
            steps {
                sh 'docker pull ${IMAGE}'
                sh 'docker rm -f ${CONTAINER} || true'
                sh 'docker run -d --name ${CONTAINER} -p 4444:4444 ${IMAGE}'
            }
        }
    }
}
