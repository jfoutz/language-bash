pipeline {
  agent any
  stages {
    stage('stuff') {
      steps {
        parallel(
          "stuff": {
            sh 'echo hello'
            
          },
          "things": {
            sh 'echo things'
            
          }
        )
      }
    }
    stage('ask') {
      steps {
        parallel(
          "ask": {
            input(message: 'is stuff ok?', id: 'this is an id', ok: 'this is an ok')
            
          },
          "error": {
            sh 'sleep 30'
            
          }
        )
      }
    }
    stage('error') {
      steps {
        echo 'job\'s done'
      }
    }
  }
}