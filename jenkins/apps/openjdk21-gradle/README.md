# openjdk21-gradle

Hello-world standalone runnable JAR built with Gradle on Chainguard's OpenJDK 21.

> Image references below show the default org (`smalls.xyz`); see the demo's top-level [README](../../README.md#configuration) for how to switch.

## Pipeline images

| Stage | Image |
|-------|-------|
| Build | `cgr.dev/smalls.xyz/jdk:openjdk-21-dev` |
| Test  | `cgr.dev/smalls.xyz/jre:openjdk-21-dev` |

The intended runtime / deploy target is `cgr.dev/smalls.xyz/jre:openjdk-21` (shell-less). The `-dev` variant is used in the Test stage only because Jenkins' `docker { image ... }` agent invokes `sh` steps, which require a shell.

## Gradle setup

The build image (`jdk:openjdk-21-dev`) ships only the JDK, not Gradle, so the project uses the **Gradle wrapper** (`gradlew` + `gradle/wrapper/`). On first invocation, `gradlew` downloads the Gradle distribution declared in `gradle/wrapper/gradle-wrapper.properties`. The pipeline runs `./gradlew --no-daemon clean jar` so the daemon doesn't outlive the build container.

## Artifact

The runnable JAR (`build/libs/app.jar`) is archived to Jenkins. Run it with:

```sh
java -jar app.jar
```

It prints `Hello from Gradle on Chainguard` followed by JDK / OS info and a couple of selected env vars.
