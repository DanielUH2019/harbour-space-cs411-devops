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
                sh 'docker rm -f ${CONTAINER} || true'
                sh 'docker run -d --name ${CONTAINER} --restart unless-stopped -p 4444:4444 ${IMAGE}'
                sh '''
                    echo "Waiting for container to become healthy..."
                    for i in $(seq 1 15); do
                        STATUS=$(docker inspect --format="{{.State.Health.Status}}" ${CONTAINER} 2>/dev/null)
                        echo "  attempt $i: $STATUS"
                        if [ "$STATUS" = "healthy" ]; then
                            echo "Container is healthy"
                            exit 0
                        fi
                        sleep 2
                    done
                    echo "Container failed to become healthy within 30s"
                    docker logs ${CONTAINER}
                    exit 1
                '''
            }
        }
    }

    post {
        always {
            sh 'docker image prune -f || true'
        }
    }
}
