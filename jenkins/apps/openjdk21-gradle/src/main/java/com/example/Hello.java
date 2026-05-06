package com.example;

public class Hello {
    public static void main(String[] args) {
        System.out.println("Hello from Gradle on Chainguard");
        System.out.println("--- runtime info ---");
        System.out.println("java.version : " + System.getProperty("java.version"));
        System.out.println("java.vendor  : " + System.getProperty("java.vendor"));
        System.out.println("java.runtime : " + System.getProperty("java.runtime.name"));
        System.out.println("os.name      : " + System.getProperty("os.name"));
        System.out.println("os.arch      : " + System.getProperty("os.arch"));
        System.out.println("--- env (selected) ---");
        for (String key : new String[]{"JAVA_HOME", "PATH", "HOSTNAME"}) {
            System.out.println(key + " : " + System.getenv(key));
        }
    }
}
