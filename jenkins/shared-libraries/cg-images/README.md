# cgImages — Jenkins shared library

Resolves logical Chainguard image tokens (e.g. `corretto-java17`, `python-3.14`) into the concrete `cgr.dev/<org>/<image>:<tag>` strings that pipelines hand to `agent { docker { image '...' } }` blocks. The `<org>` segment comes from `env.CHAINGUARD_ORG`, so org overrides flow through automatically.

The library is auto-loaded into every pipeline via JCasC ([jenkins/casc/jenkins.yaml](../../jenkins/casc/jenkins.yaml) → `unclassified.globalLibraries.libraries`, sourced via the `filesystem_scm` plugin from this directory). No `@Library('cgImages')` annotation is required.

## Usage

```groovy
def img = cgImage('corretto-java17')

pipeline {
  agent none
  stages {
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

The map returned by `cgImage(<token>)` has some subset of these keys:

| Key       | Meaning |
|-----------|---------|
| `build`   | The `*-dev` variant used in the Build stage. |
| `test`    | The `*-dev` variant used in the Test stage (Java apps that test via `agent docker`). |
| `runtime` | The shell-less production target (Python/Node OCI-image apps reference this from their Dockerfile). |

## Adding a new token

Append a row to the `catalog` map in [vars/cgImage.groovy](vars/cgImage.groovy). **No Jenkins restart required** — the next pipeline run picks up the change automatically (see [Caveats](#caveats) below).

## Why this layout

The `vars/` subdirectory is the standard Jenkins shared-library convention for "global variables / steps" — files named `vars/foo.groovy` become a callable `foo(...)` in every pipeline. `src/` is the corresponding location for class definitions; this library doesn't need any.

## Caveats

- **Edits to `cgImage.groovy` apply on the next pipeline run, no Jenkins restart needed.** This is because the retriever is `legacySCM` → `FSSCM` (filesystem_scm plugin) pointed at the bind-mounted source dir. Filesystem-SCM "checks out" the library by copying from the source path at the start of each build, so disk changes propagate immediately. The shared-library version label (`master` in our config) is a placeholder here; for filesystem sources it does not gate caching the way Git refspecs do. If we ever switched the retriever to a real Git source, semantics would change — Jenkins would cache the library by commit and only re-fetch when the version label resolves to a new commit, unless `Fresh clone per build` (the `clone: true` flag on `SCMRetriever`) is set.
- **A Groovy syntax error in `cgImage.groovy` fails every pipeline that uses it, immediately, with no graceful fallback.** The library is `implicit: true`, so all pipelines load it whether they call `cgImage(...)` or not. Worth a quick `groovyc` lint or trial run after substantive edits.
- **All pipelines see the same version of the library at any moment.** To test a change against a single pipeline without affecting the others, flip `implicit` to `false` in JCasC, restart Jenkins, then add an explicit `@Library('cgImages@<branch-or-tag>') _` annotation to the pipeline you want to opt into a different version. (For the filesystem-SCM case, "branch" is just any value — there's no real version control. The annotation is mostly meaningful when the source is Git.)
