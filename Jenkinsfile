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
        input(message: 'is stuff ok?', id: 'this is an id', ok: 'this is an ok')
      }
    }
  }
}