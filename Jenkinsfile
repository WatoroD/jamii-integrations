// Jamii Savings integrations - ONE pipeline for all three APIs (+ bonus + API product).
//
// Build once, deploy many: the CAR and API archives produced in "Build" are archived and
// fingerprinted, and the very same files are promoted dev -> prod. The set of APIs is data
// (apim/apis.manifest), so adding a fourth API is a one-line change, not a new pipeline.
//
// Agent requirements: Linux, JDK 17, Maven 3.9, Python 3.10+, jq, zip, curl, Docker (for the
// ephemeral dev stack). apictl is installed by the pipeline if missing.

def apiProjects = []

pipeline {
  agent { label 'linux && docker' }

  options {
    timestamps()
    disableConcurrentBuilds()          // one deployment to an environment at a time
    buildDiscarder(logRotator(numToKeepStr: '30'))
    timeout(time: 90, unit: 'MINUTES')
  }

  parameters {
    booleanParam(name: 'PROVISION_DEV_STACK', defaultValue: true,
                 description: 'Spin up docker-compose (MySQL + MI + APIM) as the dev target')
    booleanParam(name: 'KEEP_DEV_STACK', defaultValue: false,
                 description: 'Leave the dev stack running after the build (for manual testing)')
    booleanParam(name: 'PROMOTE_TO_PROD', defaultValue: false,
                 description: 'After a green dev deployment, ask for approval and deploy to prod (main branch only)')
  }

  environment {
    APICTL_VERSION = '4.4.0'
    PATH = "${WORKSPACE}/.tools/apictl:${PATH}"
    MAVEN_ARGS = "-Dmaven.repo.local=${WORKSPACE}/.m2/repository"
  }

  stages {
    stage('Checkout') {
      steps {
        checkout scm
        script {
          apiProjects = readFile('apim/apis.manifest').split('\n').collect { it.trim() }.findAll { it && !it.startsWith('#') }
          currentBuild.description = "APIs: ${apiProjects.join(', ')}"
          echo "Pipeline will build/deploy ${apiProjects.size()} APIs: ${apiProjects}"
        }
      }
    }

    stage('Test (static, contract, mapping)') {
      steps { sh 'scripts/run-tests.sh' }
      post { always { junit allowEmptyResults: true, testResults: 'reports/*.xml' } }
    }

    stage('Build') {
      parallel {
        stage('MI composite app') {
          steps { sh 'scripts/build-mi.sh' }   // mvn clean install -> dist/mi/JamiiIntegrations_<v>.car
        }
        stage('APIM archives') {
          steps { sh 'scripts/package-apim.sh' }   // loops over apim/apis.manifest + API product
        }
      }
    }

    stage('Verify rollback logic (simulated)') {
      // Runs deploy.sh against a fake MI Management API + fake apictl and asserts that a
      // failure in the 3rd API import, a faulty CAR, or a half-applied API product import
      // restores the previous state exactly (and leaves nothing behind on an empty environment).
      steps { sh 'tests/sim/run-deploy-sim.sh' }
    }

    stage('Archive artifacts') {
      steps {
        archiveArtifacts artifacts: 'dist/**', fingerprint: true
        stash name: 'release', includes: 'dist/**'
      }
    }

    stage('Install apictl') {
      steps { sh 'scripts/install-apictl.sh' }
    }

    stage('Dev') {
      stages {
        stage('Provision dev stack') {
          when { expression { params.PROVISION_DEV_STACK } }
          steps { sh 'scripts/env-up.sh' }
        }
        stage('Deploy to dev') {
          // deploy.sh is all-or-nothing: MI CAR + every API + product, verified and smoke-tested;
          // any failure rolls the whole environment back and fails this stage.
          steps { sh 'scripts/deploy.sh dev' }
        }
      }
      post {
        always {
          sh 'scripts/collect-logs.sh || true'
          archiveArtifacts allowEmptyArchive: true, artifacts: 'reports/**'
        }
      }
    }

    stage('Approve prod') {
      when { allOf { branch 'main'; expression { params.PROMOTE_TO_PROD } } }
      steps {
        timeout(time: 1, unit: 'DAYS') {
          input message: "Promote build #${env.BUILD_NUMBER} (${apiProjects.size()} APIs) to PRODUCTION?",
                ok: 'Deploy', submitter: 'jamii-release-managers'
        }
      }
    }

    stage('Deploy to prod') {
      when { allOf { branch 'main'; expression { params.PROMOTE_TO_PROD } } }
      steps {
        unstash 'release'   // exactly the artifacts that passed dev
        withCredentials([
          usernamePassword(credentialsId: 'jamii-prod-apim', usernameVariable: 'APIM_USER', passwordVariable: 'APIM_PASSWORD'),
          usernamePassword(credentialsId: 'jamii-prod-mi',   usernameVariable: 'MI_USER',   passwordVariable: 'MI_PASSWORD')
        ]) {
          sh 'scripts/deploy.sh prod'
        }
      }
    }
  }

  post {
    always {
      script {
        if (params.PROVISION_DEV_STACK && !params.KEEP_DEV_STACK) {
          sh 'scripts/env-down.sh || true'
        }
      }
    }
    success { echo "Released ${apiProjects} (build #${env.BUILD_NUMBER})" }
    failure { echo 'Build failed. If a deployment stage failed, the environment was rolled back - see reports/deploy-*.json' }
  }
}
