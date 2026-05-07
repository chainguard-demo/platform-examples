# openjdk21-gradle

Hello-world standalone runnable JAR built with Gradle on Chainguard's OpenJDK 21.

> `$CHAINGUARD_ORG` below stands in for your configured Chainguard org — see the top-level [README](../../README.md#configuration) for how that gets set.

## Pipeline images

| Stage | Image |
|-------|-------|
| Build | `cgr.dev/$CHAINGUARD_ORG/jdk:openjdk-21-dev` |
| Test  | `cgr.dev/$CHAINGUARD_ORG/jre:openjdk-21-dev` |

The intended runtime / deploy target is `cgr.dev/$CHAINGUARD_ORG/jre:openjdk-21` (shell-less). The `-dev` variant is used in the Test stage only because Jenkins' `docker { image ... }` agent invokes `sh` steps, which require a shell.

## Gradle setup

The build image (`jdk:openjdk-21-dev`) ships only the JDK, not Gradle, so the project uses the **Gradle wrapper** (`gradlew` + `gradle/wrapper/`). On first invocation, `gradlew` downloads the Gradle distribution declared in `gradle/wrapper/gradle-wrapper.properties`. The pipeline runs `./gradlew --no-daemon clean jar` so the daemon doesn't outlive the build container.

## Artifact

The runnable JAR (`build/libs/app.jar`) is archived to Jenkins. Run it with:

```sh
java -jar app.jar
```

It prints `Hello from Gradle on Chainguard` followed by JDK / OS info and a couple of selected env vars.
