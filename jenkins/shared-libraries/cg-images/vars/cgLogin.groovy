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
//     Same as Mode B for pulls. For pushes, write Harbor admin creds
//     (password from $HARBOR_ADMIN_PASSWORD — defaults to the chart's
//     "Harbor12345") into DOCKER_CONFIG/config.json so docker push to
//     localhost/... works.
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
      //
      // The Harbor admin password comes from the HARBOR_ADMIN_PASSWORD env
      // var (set by JCasC globalNodeProperties → docker-compose → .env). It
      // defaults to "Harbor12345" — the chart's own default — when setup.sh
      // hasn't seen a user override. Reading from env (rather than hardcoding
      // the literal) keeps cgLogin in sync with the Helm chart and the
      // Terraform provider, both of which read the same value.
      if (!env.HARBOR_ADMIN_PASSWORD) error('cgLogin: env.HARBOR_ADMIN_PASSWORD is empty — JCasC should set it from the controller env in Mode C (see docker-compose.yml + .env). Re-run setup.sh.')
      sh '''
        set -eu
        mkdir -p "$DOCKER_CONFIG"
        # Pipe through `tr -d '\n'` so the base64 output is a single line
        # even when GNU coreutils wraps at 76 chars (or appends a trailing
        # newline that survives an internal wrap). $(...) already trims the
        # final trailing newline but not internal ones, so this is a
        # defensive guard for any future longer auth string. Pass the
        # password via env (not interpolated into the script body) so a
        # passphrase containing shell metacharacters round-trips cleanly.
        AUTH=$(printf '%s' "admin:$HARBOR_ADMIN_PASSWORD" | base64 | tr -d '\n')
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
      // Mode B: anonymous everywhere, no creds to write. We still mkdir
      // $DOCKER_CONFIG eagerly so it exists with uid-1000 ownership before
      // cgSign/cgVerify bind-mount it into a sibling cosign container — if
      // the dir doesn't exist when `docker run -v "$DOCKER_CONFIG":...` runs,
      // the host docker daemon auto-creates it as root, and a later switch
      // to Mode A would then fail when chainctl (uid 1000 inside the
      // controller) tries to write a fresh docker config there.
      //
      // PUSH_REGISTRY is typically ttl.sh/<prefix> but setup.sh accepts any
      // non-localhost value, so log the actual target rather than hardcoding
      // ttl.sh. Pass pushRegistry through the sh-step environment rather
      // than interpolating into the script body — defends against shell
      // metacharacters in a user-supplied PUSH_REGISTRY value.
      withEnv(["PUSH_DISPLAY=${pushRegistry ?: '(unset)'}"]) {
        sh '''
          set -eu
          mkdir -p "$DOCKER_CONFIG"
          echo "cgLogin: Harbor mode, anonymous pulls + pushes to $PUSH_DISPLAY (Mode B)."
        '''
      }
    }
    return
  }

  // Mode A: OIDC chainctl flow.
  // Guard the readFile with fileExists so a missing IDENTITY file (e.g.
  // pipeline run before setup.sh, or the shared-libraries bind mount not
  // present) surfaces a clear, actionable error instead of a low-level
  // Groovy exception from the readFile step.
  def identityFile = '/tmp/cgjenkins-home/shared-libraries/cg-images/IDENTITY'
  if (!fileExists(identityFile)) {
    error('cgLogin: ' + identityFile + ' is missing — run setup.sh first (or set HARBOR_ENABLED=true to use the Harbor proxy cache).')
  }
  def identity = readFile(identityFile).trim()
  if (!identity) {
    error('cgLogin: ' + identityFile + ' is empty — run setup.sh first (or set HARBOR_ENABLED=true to use the Harbor proxy cache).')
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
