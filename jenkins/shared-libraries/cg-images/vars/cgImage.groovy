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
  def reg = "cgr.dev/${env.CHAINGUARD_ORG}"
  def catalog = [
    'corretto-java17': [
      build: 'maven:3-jdk17-dev@sha256:cd5d074f5f5989536cd320ff7c8e33ba345a11a113b2417234e16ec2045309bf',
      test:  'amazon-corretto-jre:17-dev@sha256:38425cf65c9ca627c44089d1b98525f813d3081fe74633c54c7e581080d3112a',
    ],
    'adoptium-java8': [
      build: 'maven:3-jdk8-dev@sha256:84acda5c8d76e33b24603b243e477130afbf8ff985c56fa99c923ab9da751495',
      test:  'adoptium-jre:adoptium-openjdk-8-dev@sha256:6a35f6882e2402f241a1d0efe057993463a714a542520aaeff4f4e3d4d28eefe',
    ],
    'openjdk21': [
      build: 'jdk:openjdk-21-dev@sha256:e300d1dd8eb0c98eb279ddf6fbda3174de8e2701877eabbf9aff994dd97118ec',
      test:  'jre:openjdk-21-dev@sha256:d146b274db34dcd9e42cbaec74fa94efa89c2f020bac6fd815d4526027f7e926',
    ],
    'python-3.14': [
      build:   'python:3.14-dev@sha256:af64d5af1a0fef64e4bfee8f49663628313f9d2de79083f19b8468f124d378c0',
      runtime: 'python:3.14@sha256:7d66fd00301532cfffae8baf4a00f4e590d8bb0a6a1efe5a468a38aacaf970f1',
    ],
    'python-3.12': [
      build:   'python:3.12-dev@sha256:e46278ee972ce5a066c10b3e78339d09e42ab480b3ebfb3d8b1937e90507f6a5',
      runtime: 'python:3.12@sha256:0f0c12676d9e4cb87d20c7d88716003c914529f4793d1968c4fbc707ed504198',
    ],
    'node-22': [
      build:   'node:22-dev@sha256:588335d09a93bf347108b5d686e3c6918c99c745cfe2853883890ee12a9db0ba',
      runtime: 'node:22@sha256:593ea898047d547e02471f48f3e51cacf1bec07f2c5d57d7943edcde16109d59',
    ],
    'node-25': [
      build:   'node:25-dev@sha256:b23770086e7e7eb49dcca3c7e2791ac517d2b3829cfc708121d79b8f2252b454',
      runtime: 'node:25-slim@sha256:affd11bfb77c0d4cd5e87d0ab7b922f2833293d5c8e24e687323d14eb19136c6',
    ],
  ]
  if (!catalog.containsKey(token)) {
    error("Unknown cgImage token '${token}'. Valid tokens: ${catalog.keySet().sort().join(', ')}")
  }
  return catalog[token].collectEntries { k, v -> [(k): "${reg}/${v}"] }
}
