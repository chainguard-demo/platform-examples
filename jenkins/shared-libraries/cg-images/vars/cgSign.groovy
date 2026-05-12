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
// The cosign helper image itself is pulled from $PULL_REGISTRY (not
// cgr.dev directly) — that's cgr.dev/<org> in Mode A but the anonymous
// Harbor proxy at localhost/cgr-proxy/<org> in Modes B/C, where the
// controller has no cgr.dev creds. Same routing as cgImage() uses for
// the application build/test agents.
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
  if (!env.CHAINGUARD_ORG) error('cgSign: env.CHAINGUARD_ORG is empty — JCasC globalNodeProperties should set it from the controller env (see jenkins/jenkins/casc/jenkins.yaml in the repo). Re-run setup.sh.')
  // Pass `image` through the sh step's environment rather than interpolating
  // it into the script body — otherwise an image ref containing a single
  // quote (or other shell metacharacter) could break out of the surrounding
  // quoting. CHAINGUARD_ORG and PULL_REGISTRY are already exposed to the
  // shell by Jenkins.
  withEnv(["IMAGE=${image}"]) {
    withCredentials([
      file(credentialsId: 'cosign-private-key', variable: 'COSIGN_KEY_FILE'),
      string(credentialsId: 'cosign-password',  variable: 'COSIGN_PASSWORD'),
    ]) {
      sh '''
        set -eu -o pipefail
        # pipefail so a failing `docker image inspect` is surfaced as the
        # pipeline's exit status rather than masked by the trailing
        # `head -1` returning 0. Split the inspect from the grep/head
        # filter so a grep-no-match (legitimate "no RepoDigest matches
        # this repo yet" case) doesn't abort under set -e/pipefail
        # before we can emit the friendly error below.
        # Pick the RepoDigest whose repo matches the image we just pushed.
        # The local image cache may have stale RepoDigests from prior runs
        # under different registries (e.g. localhost/library from a Mode C
        # session, ttl.sh from a Mode A session) — `{{index .RepoDigests 0}}`
        # returned whichever happened to be first and tripped cosign over.
        REPO="${IMAGE%:*}"
        ALL_DIGESTS=$(docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$IMAGE")
        DIGEST=$(printf '%s' "$ALL_DIGESTS" | grep -F "${REPO}@" | head -1 || true)
        if [ -z "$DIGEST" ]; then
          echo "cgSign: could not resolve digest for $IMAGE under repo $REPO (was it pushed?)." >&2
          exit 1
        fi
        # cosign's reference parser (via go-containerregistry) doesn't accept
        # bare 'localhost' as a registry hostname — it falls back to treating
        # the whole ref as a Docker Hub path (index.docker.io/localhost/...).
        # Adding ':80' forces the host:port split, so the parser recognizes
        # localhost:80 as the registry. Other hostnames (ttl.sh, harbor.foo.bar)
        # contain a '.' and parse correctly without modification.
        case "$DIGEST" in
          localhost/*) DIGEST="localhost:80/${DIGEST#localhost/}" ;;
        esac
        COSIGN_IMAGE="${PULL_REGISTRY:-cgr.dev/${CHAINGUARD_ORG}}/cosign:latest-dev"
        # Pass COSIGN_PASSWORD by NAME (no =value) so docker inherits it from
        # this shell's env instead of placing it on the docker-run command
        # line — where it would briefly be visible via `ps` / docker event
        # logs. withCredentials already exported COSIGN_PASSWORD into the
        # shell env for us.
        docker run --rm --network host \
          -v "$COSIGN_KEY_FILE:/cosign.key:ro" \
          -v "$DOCKER_CONFIG:/jenkins-docker:ro" \
          -e COSIGN_PASSWORD \
          -e DOCKER_CONFIG=/jenkins-docker \
          --entrypoint=/usr/bin/cosign \
          "$COSIGN_IMAGE" \
          sign --yes --allow-http-registry --key /cosign.key "$DIGEST"
        echo "cgSign: signed $DIGEST"
      '''
    }
  }
}
