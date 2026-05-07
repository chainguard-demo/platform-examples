// vars/cgSign.groovy
//
// Signs a freshly-pushed OCI image with cosign using the demo's static
// keypair. The private key + password live in Jenkins's encrypted
// credentials store (registered by JCasC at boot from
// /tmp/cgjenkins-home/.secrets/) and are pulled in by `withCredentials`,
// which writes the key to a temp file in the build workspace and exposes
// the password as a masked env var. The signature is uploaded to the same
// registry the image lives in, as a sibling OCI artifact at
// <repo>:sha256-<digest>.sig — no Sigstore Fulcio/Rekor calls.
//
// Cosign runs as a one-shot container with --network host so that the
// `localhost` references used in Mode C (Harbor) resolve to the host's
// ingress instead of the Jenkins controller container's own loopback. We
// cannot run cosign in-process on the controller for the same reason. For
// Modes A/B the registry is ttl.sh (public DNS), so --network host is a
// no-op there but still consistent.
//
// Auth to the destination registry: cosign reads $DOCKER_CONFIG just like
// docker push does. We mount the controller's DOCKER_CONFIG dir read-only
// into the cosign container so it inherits whatever credentials cgLogin()
// wrote earlier in the pipeline (Harbor admin creds in Mode C; nothing
// needed in A/B since signatures push anonymously to ttl.sh).
//
// Usage from a stage on `agent any`:
//
//   stage('Sign') {
//     agent any
//     steps { cgSign(env.IMAGE) }
//   }
//
// Cosign needs an immutable digest reference, not a mutable tag, so we
// resolve $IMAGE → $IMAGE@sha256:<digest> via `docker image inspect`
// first. (Pipelines push the tag-only ref; the digest is what cosign
// signs.) `--allow-http-registry` is set because Mode C's localhost
// registry is HTTP-only — see harbor/cg/helm/values.template for why.

def call(String image) {
  if (!image?.trim()) {
    error('cgSign: image argument is required')
  }
  def org = env.CHAINGUARD_ORG
  if (!org) error('cgSign: env.CHAINGUARD_ORG is empty — JCasC globalNodeProperties should set it from the controller env (jenkins/casc/jenkins.yaml). Re-run setup.sh.')
  withCredentials([
    file(credentialsId: 'cosign-private-key', variable: 'COSIGN_KEY_FILE'),
    string(credentialsId: 'cosign-password',  variable: 'COSIGN_PASSWORD'),
  ]) {
    sh """
      set -eu
      DIGEST=\$(docker image inspect --format '{{index .RepoDigests 0}}' '${image}')
      if [ -z "\$DIGEST" ]; then
        echo "cgSign: could not resolve digest for ${image} (was it pushed?)." >&2
        exit 1
      fi
      # cosign's reference parser (via go-containerregistry) doesn't accept
      # bare 'localhost' as a registry hostname — it falls back to treating
      # the whole ref as a Docker Hub path (index.docker.io/localhost/...).
      # Adding ':80' forces the host:port split, so the parser recognizes
      # localhost:80 as the registry. Other hostnames (ttl.sh, harbor.foo.bar)
      # contain a '.' and parse correctly without modification.
      case "\$DIGEST" in
        localhost/*) DIGEST="localhost:80/\${DIGEST#localhost/}" ;;
      esac
      docker run --rm --network host \\
        -v "\$COSIGN_KEY_FILE:/cosign.key:ro" \\
        -v "\$DOCKER_CONFIG:/jenkins-docker:ro" \\
        -e "COSIGN_PASSWORD=\$COSIGN_PASSWORD" \\
        -e DOCKER_CONFIG=/jenkins-docker \\
        --entrypoint=/usr/bin/cosign \\
        cgr.dev/${org}/cosign:latest-dev \\
        sign --yes --allow-http-registry --key /cosign.key "\$DIGEST"
      echo "cgSign: signed \$DIGEST"
    """
  }
}
