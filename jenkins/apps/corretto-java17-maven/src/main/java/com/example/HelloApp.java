package com.example;

import org.springframework.boot.CommandLineRunner;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

@SpringBootApplication
public class HelloApp implements CommandLineRunner {

    public static void main(String[] args) {
        SpringApplication.run(HelloApp.class, args);
    }

    @Override
    public void run(String... args) {
        System.out.println("Hello from Spring Boot on Chainguard");
        System.out.println("--- runtime info ---");
        System.out.println("java.version : " + System.getProperty("java.version"));
        System.out.println("java.vendor  : " + System.getProperty("java.vendor"));
        System.out.println("java.runtime : " + System.getProperty("java.runtime.name"));
        System.out.println("os.name      : " + System.getProperty("os.name"));
        System.out.println("os.arch      : " + System.getProperty("os.arch"));
        System.out.println("user.dir     : " + System.getProperty("user.dir"));
        System.out.println("--- env (selected) ---");
        for (String key : new String[]{"JAVA_HOME", "PATH", "HOSTNAME"}) {
            System.out.println(key + " : " + System.getenv(key));
        }
    }
}
