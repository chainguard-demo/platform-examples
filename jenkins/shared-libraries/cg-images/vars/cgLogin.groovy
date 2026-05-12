// vars/cgLogin.groovy
//
// Sets up the controller's docker config so the rest of the pipeline can
// pull (and optionally push) Chainguard images. Behavior depends on the
// mode chosen at setup.sh time:
//
//   Mode A (HARBOR_ENABLED=false, PUSH_REGISTRY=ttl.sh/...):
//     Exchanges a per-build Jenkins-issued OIDC token for a short-lived
//     Chainguard session via `chainctl auth login` + `chainctl auth
//     configure-docker`. ttl.sh pushes don't need creds.
//
//   Mode B (HARBOR_ENABLED=true, PUSH_REGISTRY=ttl.sh/...):
//     Pulls go through Harbor's anonymous proxy cache project, so no
//     cgr.dev creds needed. ttl.sh pushes don't need creds either. The
//     Auth stage is effectively a no-op — we just print a status line.
//
//   Mode C (HARBOR_ENABLED=true, PUSH_REGISTRY=localhost/...):
//     Same as Mode B for pulls. For pushes, write Harbor admin/Harbor12345
//     into DOCKER_CONFIG/config.json so docker push to localhost/... works.
//
// Usage — call from a stage on `agent any` (the controller) BEFORE any
// stage that uses `agent { docker { image cgImage(...).build } }`:
//
//   stage('Auth') {
//     agent any
//     steps { cgLogin() }
//   }

def call() {
  def harborEnabled = (env.HARBOR_ENABLED ?: 'false') == 'true'
  def pushRegistry  = env.PUSH_REGISTRY ?: ''

  if (harborEnabled) {
    if (pushRegistry.startsWith('localhost/')) {
      // Mode C: write Harbor admin creds for push.
      // Two entries with the same auth: cosign's reference parser rejects
      // bare 'localhost' (treats it as a Docker Hub path), so cgSign rewrites
      // refs to 'localhost:80/...' before invoking cosign — which then looks
      // up auth keyed by 'localhost:80'. Docker push uses the bare 'localhost'
      // key. Keep both so both code paths find creds.
      sh '''
        set -eu
        mkdir -p "$DOCKER_CONFIG"
        # Pipe through `tr -d '\n'` so the base64 output is a single line
        # even when GNU coreutils wraps at 76 chars (or appends a trailing
        # newline that survives an internal wrap). $(...) already trims the
        # final trailing newline but not internal ones, so this is a
        # defensive guard for any future longer auth string.
        AUTH=$(printf 'admin:Harbor12345' | base64 | tr -d '\n')
        cat > "$DOCKER_CONFIG/config.json" <<EOF
{
  "auths": {
    "localhost":    { "auth": "$AUTH" },
    "localhost:80": { "auth": "$AUTH" }
  }
}
EOF
        echo "cgLogin: configured Harbor admin auth for localhost / localhost:80 (Mode C)."
      '''
    } else {
      // Mode B: anonymous everywhere, nothing to write. PUSH_REGISTRY is
      // typically ttl.sh/<prefix> but setup.sh accepts any non-localhost
      // value, so log the actual target rather than hardcoding ttl.sh.
      // Pass pushRegistry through the sh-step environment rather than
      // interpolating into the script body — defends against shell
      // metacharacters in a user-supplied PUSH_REGISTRY value.
      withEnv(["PUSH_DISPLAY=${pushRegistry ?: '(unset)'}"]) {
        sh 'echo "cgLogin: Harbor mode, anonymous pulls + pushes to $PUSH_DISPLAY (Mode B)."'
      }
    }
    return
  }

  // Mode A: OIDC chainctl flow.
  def identity = readFile('/tmp/cgjenkins-home/shared-libraries/cg-images/IDENTITY').trim()
  if (!identity) {
    error('cgLogin: shared-libraries/cg-images/IDENTITY is empty — run setup.sh first (or set HARBOR_ENABLED=true to use the Harbor proxy cache).')
  }
  withCredentials([string(credentialsId: 'jenkins-cgr-oidc', variable: 'OIDC_TOKEN')]) {
    sh """
      set -eu
      chainctl auth login --identity='${identity}' --identity-token=\"\$OIDC_TOKEN\"
      # configure-docker needs --identity and --identity-token too, otherwise
      # it falls through to the interactive browser flow after writing the
      # credential helper config.
      chainctl auth configure-docker --identity='${identity}' --identity-token=\"\$OIDC_TOKEN\"
      echo 'cgLogin: authenticated as identity ${identity} (Mode A).'
    """
  }
}
