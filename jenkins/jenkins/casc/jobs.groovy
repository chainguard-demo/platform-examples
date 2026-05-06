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
