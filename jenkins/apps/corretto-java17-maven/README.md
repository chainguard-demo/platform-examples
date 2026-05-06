# corretto-java17-maven

Hello-world Spring Boot console app, built with Maven on Amazon Corretto JDK 17.

## Pipeline images

| Stage | Image |
|-------|-------|
| Build | `cgr.dev/smalls.xyz/maven:3-jdk17-dev` |
| Test  | `cgr.dev/smalls.xyz/amazon-corretto-jre:17-dev` |

The intended runtime / deploy target is `cgr.dev/smalls.xyz/amazon-corretto-jre:17` (shell-less). The `-dev` variant is used in the Test stage only because Jenkins' `docker { image ... }` agent runs `sh` steps that require a shell.

## Artifact

The Spring Boot fat JAR (`target/app.jar`) is archived to Jenkins. Download it from the build's "Build Artifacts" link in the UI.

## Running locally

To produce and run the JAR outside Jenkins:

```sh
docker run --rm -v "$PWD":/work -w /work cgr.dev/smalls.xyz/maven:3-jdk17-dev \
  mvn -B -ntp clean package -DskipTests

docker run --rm -v "$PWD":/work -w /work cgr.dev/smalls.xyz/amazon-corretto-jre:17-dev \
  java -jar target/app.jar
```
