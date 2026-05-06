plugins {
    application
    java
}

group = "com.example"
version = "0.0.1-SNAPSHOT"

java {
    toolchain {
        languageVersion.set(JavaLanguageVersion.of(21))
    }
}

application {
    mainClass.set("com.example.Hello")
}

tasks.jar {
    archiveBaseName.set("app")
    archiveVersion.set("")
    manifest {
        attributes("Main-Class" to "com.example.Hello")
    }
}
