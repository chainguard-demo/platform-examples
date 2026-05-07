// vars/cgVerify.groovy
//
// Verifies an OCI image signature using the demo's public key. Pulls the
// public key from Jenkins's credentials store (registered by JCasC at boot
// from /tmp/cgjenkins-home/.secrets/cosign.pub), validates the registry
// signature against it, and fails the build if the signature is missing
// or invalid. Pair with cgSign() in the preceding stage to demonstrate
// the full sign-then-verify loop.
//
// Cosign runs in a one-shot container with --network host for the same
// reason cgSign does — see that file for the full rationale.
//
// Usage from a stage on `agent any`:
//
//   stage('Verify') {
//     agent any
//     steps { cgVerify(env.IMAGE) }
//   }
//
// Resolves the same image-by-digest as cgSign so verification targets
// the exact bytes that were signed (not whatever a mutable tag may now
// point at).

def call(String image) {
  if (!image?.trim()) {
    error('cgVerify: image argument is required')
  }
  def org = env.CHAINGUARD_ORG ?: 'smalls.xyz'
  withCredentials([
    file(credentialsId: 'cosign-public-key', variable: 'COSIGN_PUB_FILE'),
  ]) {
    sh """
      set -eu
      DIGEST=\$(docker image inspect --format '{{index .RepoDigests 0}}' '${image}')
      if [ -z "\$DIGEST" ]; then
        echo "cgVerify: could not resolve digest for ${image} (was it pushed?)." >&2
        exit 1
      fi
      # See cgSign.groovy for why we rewrite bare 'localhost' to 'localhost:80'.
      case "\$DIGEST" in
        localhost/*) DIGEST="localhost:80/\${DIGEST#localhost/}" ;;
      esac
      docker run --rm --network host \\
        -v "\$COSIGN_PUB_FILE:/cosign.pub:ro" \\
        -v "\$DOCKER_CONFIG:/jenkins-docker:ro" \\
        -e DOCKER_CONFIG=/jenkins-docker \\
        --entrypoint=/usr/bin/cosign \\
        cgr.dev/${org}/cosign:latest-dev \\
        verify --allow-http-registry --key /cosign.pub "\$DIGEST" >/dev/null
      echo "cgVerify: signature OK for \$DIGEST"
    """
  }
}
