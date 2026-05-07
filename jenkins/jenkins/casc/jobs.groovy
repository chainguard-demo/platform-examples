// Job-DSL seed: one pipelineJob per sample app under /sources/apps.
// To add an app: drop it into apps/<name>/ with a Jenkinsfile, then add a block here.
//
// The Jenkinsfile body is inlined into the job at seed time so we don't need an SCM.
// Each pipeline's first stage copies the app sources from /sources into the workspace
// (these come from the bind-mounted ./apps directory, available on both the controller
// and the DinD daemon at the same path).

def apps = [
  [
    name: 'corretto-java17-maven',
    description: 'Spring Boot built with Maven on Chainguard Corretto JDK 17 images',
  ],
  [
    name: 'adoptium-java8-jetty',
    description: 'Jetty/JSP runnable WAR built on Chainguard Adoptium JDK 8 images',
  ],
  [
    name: 'openjdk21-gradle',
    description: 'Standalone runnable JAR built with Gradle on Chainguard OpenJDK 21 images',
  ],
  [
    name: 'python314-uv-flask',
    description: 'Flask app on Chainguard Python 3.14 with uv; archived as OCI image to ttl.sh',
  ],
  [
    name: 'python312-pip-django',
    description: 'Django site on Chainguard Python 3.12 with pip; archived as OCI image to ttl.sh',
  ],
  [
    name: 'node22-npm-express',
    description: 'Express app on Chainguard Node 22 with npm; archived as OCI image to ttl.sh',
  ],
  [
    name: 'node25-pnpm-express',
    description: 'Express app on Chainguard Node 25 (slim runtime) with pnpm; archived as OCI image to ttl.sh',
  ],
]

apps.each { app ->
  pipelineJob(app.name) {
    description(app.description)
    definition {
      cps {
        script(new File("/sources/apps/${app.name}/Jenkinsfile").text)
        sandbox(true)
      }
    }
  }
}

// Ops jobs — internal Jenkins maintenance pipelines (not sample app builds).
pipelineJob('refresh-cgimages-digests') {
  description('Re-resolves cgImages catalog digests every 4 hours so sample-app pipelines stay current with upstream tag movements.')
  triggers {
    // H H/4 * * * — every 4 hours, randomized per controller.
    cron('H H/4 * * *')
  }
  definition {
    cps {
      script(new File('/sources/ops/refresh-cgimages-digests/Jenkinsfile').text)
      sandbox(true)
    }
  }
}
