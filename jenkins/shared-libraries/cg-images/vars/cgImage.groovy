// vars/cgImage.groovy
//
// Shared-library entry point. Resolves a logical token like "corretto-java17"
// or "python-3.14" into a Map of fully-qualified Chainguard image references
// for use in `agent { docker { image '...' } }` blocks.
//
// Auto-loaded for every pipeline via JCasC (unclassified.globalLibraries with
// implicit: true). Pipelines do not need an `@Library('cgImages')` annotation.
//
// Usage:
//
//   def img = cgImage('corretto-java17')
//   pipeline {
//     stages {
//       stage('Build') {
//         agent { docker { image img.build; args '--entrypoint=' } }
//         ...
//       }
//       stage('Test') {
//         agent { docker { image img.test;  args '--entrypoint=' } }
//         ...
//       }
//     }
//   }
//
// Each token's map has some subset of these keys:
//   build    — the *-dev variant used in the Build stage
//   test     — the *-dev variant used in the Test stage (Java apps)
//   runtime  — the shell-less production target (referenced from Dockerfiles
//              that build OCI images for Python/Node apps)
//
// Image references are pinned by digest (the `@sha256:...` suffix) so that
// re-runs of a pipeline always pull the same bytes even if the upstream
// `:dev` tag is later repointed. The tag is retained alongside the digest
// for human readability — Docker accepts `repo:tag@digest` natively.
// Refresh the digests with refresh-digests.sh when you want to pick up
// newer image versions.

def call(String token) {
  // PULL_REGISTRY is set by JCasC globalNodeProperties (driven by setup.sh).
  // Defaults to cgr.dev/<org> for the no-Harbor case; switches to
  // localhost/cgr-proxy/<org> when Harbor is the active pull-through cache.
  // Guard against both being empty — otherwise the fallback evaluates to
  // the literal "cgr.dev/null" (Groovy stringifies a null reference inside
  // a GString) and pipelines fail with confusing "manifest not found"
  // errors instead of a clear "re-run setup.sh" message.
  if (!env.PULL_REGISTRY && !env.CHAINGUARD_ORG) {
    error('cgImage: both env.PULL_REGISTRY and env.CHAINGUARD_ORG are empty — JCasC globalNodeProperties should set at least one of these from the controller env (jenkins/jenkins/casc/jenkins.yaml). Re-run setup.sh.')
  }
  def reg = env.PULL_REGISTRY ?: "cgr.dev/${env.CHAINGUARD_ORG}"
  def catalog = [
    'corretto-java17': [
      build: 'maven:3-jdk17-dev@sha256:90e0bf8239086e814fc92090749f4f3b7b49a88107c655b0661509a2a4f2ee58',
      test:  'amazon-corretto-jre:17-dev@sha256:46883ffbb2b5e99cf52cb124d9fced7b4e3740cacd46c1913bc2e970b7613353',
    ],
    'adoptium-java8': [
      build: 'maven:3-jdk8-dev@sha256:9df83d553cef9c7bc3daabd51fcf993478516339c525eca0307f780f2ed3743a',
      test:  'adoptium-jre:adoptium-openjdk-8-dev@sha256:b06752d6781be20ef0ca4bc50459ef1c7518acec79122e4583ee9a24f6ed396a',
    ],
    'openjdk21': [
      build: 'jdk:openjdk-21-dev@sha256:22a0cda00ee2980c4e1c7c35f7ddfa4391e06a2a8806887bffb5e5283f149ee1',
      test:  'jre:openjdk-21-dev@sha256:c5bc29d25e88d244e7caaa344285007da619cd0bf83c350989398e1553775ecf',
    ],
    'python-3.14': [
      build:   'python:3.14-dev@sha256:aa69dcd8a8689f7584fd4e077a52c0f13812ec7f54ace6590ab31f4297b3129d',
      runtime: 'python:3.14@sha256:0d0af6d76f7caf6b0d21015b66089bef7f017d062652a3b297f211d07e319ec4',
    ],
    'python-3.12': [
      build:   'python:3.12-dev@sha256:6f0af8cc50dd3853ce3fb145874e2408c868ba50e7104691a43794efda509e57',
      runtime: 'python:3.12@sha256:c989e9a79d89581d777a9249444ebf7a9a64835188fe958d18ee3f19a98d25e1',
    ],
    'node-22': [
      build:   'node:22-dev@sha256:dd916e3ed5be3b662cb598ad02a9e8b31a5ab23964ac92db4f79378ffa9fccca',
      runtime: 'node:22@sha256:63323818cad51c97855be7c45a5ff8933983658b0b88051f7800368bcf5b938c',
    ],
    'node-25': [
      build:   'node:25-dev@sha256:cea252f9844fcaf7a224f009201e202e956d316976fe95df3c3c51d78ba10187',
      runtime: 'node:25-slim@sha256:c1c2a3206d54ce0d1e04f108de77429325fd50b3ad266f7fbf827536ffed0292',
    ],
  ]
  if (!catalog.containsKey(token)) {
    error("Unknown cgImage token '${token}'. Valid tokens: ${catalog.keySet().sort().join(', ')}")
  }
  return catalog[token].collectEntries { k, v -> [(k): "${reg}/${v}"] }
}
