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
      build: 'maven:3-jdk17-dev@sha256:d95ab64eb7ce9b3016cc781c65025727b7287f048655ce2a33ec8b9500b4ba39',
      test:  'amazon-corretto-jre:17-dev@sha256:d00bd8b357f0481d9c9c2778d69b74312f01d582b04df1e296a76ee74714e8be',
    ],
    'adoptium-java8': [
      build: 'maven:3-jdk8-dev@sha256:cad0490a5f41c922e884d3cc11a810234b8661fe8b2becbcdc6a2d92e2708a9e',
      test:  'adoptium-jre:adoptium-openjdk-8-dev@sha256:f745cc893a988fd4065b21b318473315c6fab61607bc89d8fd656633d75fcd6d',
    ],
    'openjdk21': [
      build: 'jdk:openjdk-21-dev@sha256:8fccfbd701fe79dc6c53bba92b7d4e3387bd6b140cd69fccbc74109da59a470c',
      test:  'jre:openjdk-21-dev@sha256:5c7d9d0287cf9bd4c4d3df39f532a028a0f019d96b60a12862c2dc29d9c740fb',
    ],
    'python-3.14': [
      build:   'python:3.14-dev@sha256:3e01b7cc5c6ec2615546784c78e85ac6d1fefa5e07666515d8d32463952adc96',
      runtime: 'python:3.14@sha256:7d66fd00301532cfffae8baf4a00f4e590d8bb0a6a1efe5a468a38aacaf970f1',
    ],
    'python-3.12': [
      build:   'python:3.12-dev@sha256:c4205ab4b2e326c214f4d438c8cb7fffc093ffc95a4a1b67c40c8657b1851f47',
      runtime: 'python:3.12@sha256:0f0c12676d9e4cb87d20c7d88716003c914529f4793d1968c4fbc707ed504198',
    ],
    'node-22': [
      build:   'node:22-dev@sha256:4bc74862aec7fcfcf518e8606dbc0d7cdc294a1a062c6323a42bda40dd443969',
      runtime: 'node:22@sha256:2ac85f61d02a044683bf5904183d2215acf167773c4fdf091ff657f4acfc84be',
    ],
    'node-25': [
      build:   'node:25-dev@sha256:42011912b30c4ed6320a7c48cbec1571886ab57915f54cd6ed616958ae5d9857',
      runtime: 'node:25-slim@sha256:affd11bfb77c0d4cd5e87d0ab7b922f2833293d5c8e24e687323d14eb19136c6',
    ],
  ]
  if (!catalog.containsKey(token)) {
    error("Unknown cgImage token '${token}'. Valid tokens: ${catalog.keySet().sort().join(', ')}")
  }
  return catalog[token].collectEntries { k, v -> [(k): "${reg}/${v}"] }
}
