# cgImages — Jenkins shared library

Resolves logical Chainguard image tokens (e.g. `corretto-java17`, `python-3.14`) into the concrete `cgr.dev/<org>/<image>:<tag>` strings that pipelines hand to `agent { docker { image '...' } }` blocks. The `<org>` segment comes from `env.CHAINGUARD_ORG`, so org overrides flow through automatically.

The library is auto-loaded into every pipeline via JCasC ([jenkins/casc/jenkins.yaml](../../jenkins/casc/jenkins.yaml) → `unclassified.globalLibraries.libraries`, sourced via the `filesystem_scm` plugin from this directory). No `@Library('cgImages')` annotation is required.

## Usage

```groovy
def img = cgImage('corretto-java17')

pipeline {
  agent none
  stages {
    stage('Auth') {
      agent any
      steps { cgLogin() }   // see vars/cgLogin.groovy
    }
    stage('Build') {
      agent { docker { image img.build; args '--entrypoint=' } }
      ...
    }
    stage('Test') {
      agent { docker { image img.test; args '--entrypoint=' } }
      ...
    }
  }
}
```

The `Auth` stage runs `cgLogin` — a sibling shared-library var that exchanges a per-build Jenkins OIDC token for a short-lived Chainguard session and writes a fresh docker config to `$DOCKER_CONFIG`. It must precede any `agent { docker { } }` stage so the docker-workflow plugin picks up the new creds when it pulls the agent image.

The map returned by `cgImage(<token>)` has some subset of these keys:

| Key       | Meaning |
|-----------|---------|
| `build`   | The `*-dev` variant used in the Build stage. |
| `test`    | The `*-dev` variant used in the Test stage (Java apps that test via `agent docker`). |
| `runtime` | The shell-less production target (Python/Node OCI-image apps reference this from their Dockerfile). |

## Image references are pinned by digest

Each entry uses `repo:tag@sha256:...` format. The tag is kept for human readability; the digest provides immutable identity so re-runs of a pipeline always pull the **same image bytes** even if the upstream `:dev` tag is later repointed to a newer build. This is the standard pattern for reproducible Chainguard image consumption.

To refresh the digests (e.g. to pick up a security patch in the underlying image), run:

```sh
./refresh-digests.sh
```

The script reads the current `repo:tag` portion of each pinned reference, calls `crane digest cgr.dev/$CHAINGUARD_ORG/<repo>:<tag>` for each, and rewrites the digest in place. Requires `crane`. It picks up `CHAINGUARD_ORG` from `../../.env` so refreshing matches the org the demo is configured for.

## Adding a new token

Append a row to the `catalog` map in [vars/cgImage.groovy](vars/cgImage.groovy) with the desired `repo:tag` and any digest (or none — leaving just `repo:tag` works too). Then run [refresh-digests.sh](refresh-digests.sh) to pin the entry to the current digest. **No Jenkins restart required** — the next pipeline run picks up the change automatically (see [Caveats](#caveats) below).

## Why this layout

The `vars/` subdirectory is the standard Jenkins shared-library convention for "global variables / steps" — files named `vars/foo.groovy` become a callable `foo(...)` in every pipeline. `src/` is the corresponding location for class definitions; this library doesn't need any.

## Caveats

- **Edits to `cgImage.groovy` (or `cgLogin.groovy`) apply on the next pipeline run, no Jenkins restart needed.** This is because the retriever is `legacySCM` → `FSSCM` (filesystem_scm plugin) pointed at the bind-mounted source dir, **with `clone: true`** (forces a fresh checkout per build). Without `clone: true` filesystem_scm caches the workspace and edits don't propagate. The shared-library version label (`master` in our config) is a placeholder here; for filesystem sources it does not gate caching the way Git refspecs do. If we ever switched the retriever to a real Git source, the cache key becomes the commit hash and `clone: true` would be costly — drop it then.
- **A Groovy syntax error in `cgImage.groovy` fails every pipeline that uses it, immediately, with no graceful fallback.** The library is `implicit: true`, so all pipelines load it whether they call `cgImage(...)` or not. Worth a quick `groovyc` lint or trial run after substantive edits.
- **All pipelines see the same version of the library at any moment.** To test a change against a single pipeline without affecting the others, flip `implicit` to `false` in JCasC, restart Jenkins, then add an explicit `@Library('cgImages@<branch-or-tag>') _` annotation to the pipeline you want to opt into a different version. (For the filesystem-SCM case, "branch" is just any value — there's no real version control. The annotation is mostly meaningful when the source is Git.)
- **Digest pins are org-specific.** `cgr.dev/<org-A>/maven:3-jdk17-dev` and `cgr.dev/<org-B>/maven:3-jdk17-dev` typically resolve to the same content (Chainguard mirrors are byte-identical for shared images), but that's not guaranteed. If you switch `CHAINGUARD_ORG`, re-run `refresh-digests.sh` to verify and re-pin against the new org. A wrong digest fails the pull at build time with a clear error message.
- **Digest pins are also frozen in time.** Chainguard rebuilds these images regularly with the latest CVE fixes. Pinning gives you reproducibility but it does not auto-update — for the demo this is fine, but for a production setup you'd want a higher-cadence refresh (e.g. via [`digestabotctl`](../../../digestabotctl/) elsewhere in this repo, Renovate, or a scheduled CI job that re-runs `refresh-digests.sh`).
