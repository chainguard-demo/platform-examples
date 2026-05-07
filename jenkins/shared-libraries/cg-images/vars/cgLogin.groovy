// vars/cgLogin.groovy
//
// Per-build chainctl login. Exchanges a Jenkins-issued OIDC token for a
// short-lived (~30 min) Chainguard session, then writes a docker config
// that the rest of the pipeline (and any spawned `agent docker` agents)
// can use to pull from cgr.dev.
//
// Usage — call from a stage on `agent any` (the controller) BEFORE any
// stage that uses `agent { docker { image cgImage(...).build } }`:
//
//   stage('Auth') {
//     agent any
//     steps { cgLogin() }
//   }
//
// Auto-loaded for every pipeline via the same JCasC globalLibraries
// config that loads cgImage. No `@Library` annotation needed.
//
// Required environment / config (set up by setup.sh + jenkins.yaml):
//   - env.CHAINGUARD_IDENTITY       UIDP of the assumed identity
//                                   (set via JCasC globalNodeProperties)
//   - credential 'jenkins-cgr-oidc' an oidcCredential issued by the
//                                   oidc-provider plugin, audience cgr.dev
//   - DOCKER_CONFIG                 path the controller's docker CLI reads
//                                   (set in docker-compose.yml)

def call() {
  // Read the identity UIDP from a file rather than env.CHAINGUARD_IDENTITY.
  // The file is rewritten by setup.sh after each `terraform apply`, and the
  // shared-libraries dir is bind-mounted live into the controller, so a
  // Jenkins restart is NOT required to pick up a new identity. (Restarting
  // Jenkins would also regenerate its OIDC signing key and invalidate the
  // JWKS we just uploaded — avoiding that is the whole reason this is a
  // file lookup.)
  def identity = readFile('/tmp/cgjenkins-home/shared-libraries/cg-images/IDENTITY').trim()
  if (!identity) {
    error('cgLogin: shared-libraries/cg-images/IDENTITY is empty — run setup.sh first')
  }
  withCredentials([string(credentialsId: 'jenkins-cgr-oidc', variable: 'OIDC_TOKEN')]) {
    sh """
      set -eu
      chainctl auth login --identity='${identity}' --identity-token=\"\$OIDC_TOKEN\"
      # configure-docker needs --identity and --identity-token too, otherwise
      # it falls through to the interactive browser flow after writing the
      # credential helper config.
      chainctl auth configure-docker --identity='${identity}' --identity-token=\"\$OIDC_TOKEN\"
      echo 'cgLogin: authenticated as identity ${identity}'
    """
  }
}
