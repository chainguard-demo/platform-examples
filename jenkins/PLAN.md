In this directory we will implement a simple Jenkins server demo with pipeline jobs to build applications on various languages (and various versions of them) and build tools.

All images should be Chainguard sourced and pulled from the cgr.dev/smalls.xyz repository.

Setup scripts should be provided to quickly stand up the Jenkins environment for future demonstrations.

Create sub-directories for the various sample applications with Jenkins pipeline files in them as if they were seperate repos in a real-world scenario.

## Sample applications to build (take these one at a time)
- For each, make a simple "hello world" type application for each that also outputs info about the runtime environment (i.e. language version, env vars, etc)
- Jenkins test stage for each should be simple smoke test, nothing fancy.
- Some pipelines will archive language artifacts, others OCI images, use jenkins archival plus any other remote archival destination mentioned per app.

### Corretto Java 17 + Maven
  - Use a Springboot app
  - Build stage: maven:3-jdk17-dev image and 
  - Test stage: amazon-corretto-jre:17 image
  - Artifact to archive is the springboot runnable jar

### Adoptium Java 8 + Maven Web app
  - Simple Jetty jsp page app
  - build with the maven:3-jdk-8-dev image
  - test on the adoptium-jre:adoptium-openjdk-8
  - Artifact to archive is the jetty runnable war

### OpenJDK 21 + Gradle standalone jar app
  - Executable jar that just prints out to stdout
  - build with the jdk:openjdk-21-dev image
  - test with the jre:openjre-21 image
  - Artifact to archive is the runnable jar

### Python 3.14 + uv app
  - Simple flask web site
  - Install flask with uv
  - build with the python:3.14-dev image
  - test with the python:3.14 image
  - Artifact to archive is a new image based on python:3.14 image and pushed to ttl.sh/smalls-pytest:3-14

### Python 3.12+ pip app
  - Simple django web site
  - Install django with pip
  - build with the python:3.12-dev image
  - test with the python:3.12 image
  - Artifact to archive is a new image based on python:3.12 image and pushed to ttl.sh/smalls-pytest:3-12

### NodeJs 21 + npm app
  - Simple npm built application (include some kind of npm library for the example)
  - build with the node:21-dev image
  - test with the node:21 image
  - Artifact to archive is a new image based on node:21 image and pushed to ttl.sh/smalls-nodetest:21

### NodeJs 25 + pnpm app (using slim variant)
  - Simple npm built application (include some kind of npm library for the example)
  - build with the node:25-dev image
  - test with the node:25-slim image
  - Artifact to archive is a new image based on node:25-slim image and pushed to ttl.sh/smalls-nodetest:25

## Future enhancements
- Decouple the demo from the smalls.xyz hard-coded org, make that configurable
- Add a harbor image registry option as a pull-through-mirror
- Use that harbor server as a destination for image pushes instead of ttl.sh

