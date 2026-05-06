# adoptium-java8-jetty

Hello-world Jetty/JSP web app, built with Maven on Adoptium JDK 8 and packaged as a self-executing WAR.

## Pipeline images

| Stage | Image |
|-------|-------|
| Build | `cgr.dev/smalls.xyz/maven:3-jdk8-dev` |
| Test  | `cgr.dev/smalls.xyz/adoptium-jre:adoptium-openjdk-8-dev` |

The intended runtime / deploy target is `cgr.dev/smalls.xyz/adoptium-jre:adoptium-openjdk-8` (shell-less). The `-dev` variant is used in the Test stage only because Jenkins' `docker { image ... }` agent invokes `sh` steps, which require a shell.

## Artifact

The runnable WAR (`target/app.war`) is archived to Jenkins. Run it with:

```sh
java -jar app.war
# Visit http://localhost:8080/
```

The WAR self-bootstraps: a small `com.example.Main` class lives at the WAR root and uses only JDK classes to extract `WEB-INF/lib/*.jar` to a temp dir, then reflectively boots an embedded Jetty 9.4 server pointed at the WAR itself.

## Smoke test

The Test stage starts the WAR, waits for it to listen on port 8080, fetches `index.jsp`, and asserts the rendered HTML contains the expected greeting. Then it shuts the server down.
