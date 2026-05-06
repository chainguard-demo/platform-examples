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
// To add a new token: append a row to the catalog below. Pipelines pick up
// changes after a controller restart (JCasC re-applies the library config).

def call(String token) {
  def reg = "cgr.dev/${env.CHAINGUARD_ORG}"
  def catalog = [
    'corretto-java17': [build: 'maven:3-jdk17-dev',  test: 'amazon-corretto-jre:17-dev'],
    'adoptium-java8':  [build: 'maven:3-jdk8-dev',   test: 'adoptium-jre:adoptium-openjdk-8-dev'],
    'openjdk21':       [build: 'jdk:openjdk-21-dev', test: 'jre:openjdk-21-dev'],
    'python-3.14':     [build: 'python:3.14-dev',    runtime: 'python:3.14'],
    'python-3.12':     [build: 'python:3.12-dev',    runtime: 'python:3.12'],
    'node-22':         [build: 'node:22-dev',        runtime: 'node:22'],
    'node-25':         [build: 'node:25-dev',        runtime: 'node:25-slim'],
  ]
  if (!catalog.containsKey(token)) {
    error("Unknown cgImage token '${token}'. Valid tokens: ${catalog.keySet().sort().join(', ')}")
  }
  return catalog[token].collectEntries { k, v -> [(k): "${reg}/${v}"] }
}
