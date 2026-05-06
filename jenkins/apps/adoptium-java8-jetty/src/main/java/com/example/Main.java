package com.example;

import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.net.URL;
import java.net.URLClassLoader;
import java.security.ProtectionDomain;
import java.util.ArrayList;
import java.util.Enumeration;
import java.util.List;
import java.util.jar.JarEntry;
import java.util.jar.JarFile;

/**
 * Bootstraps an embedded Jetty server that serves this WAR file.
 * Lives at the WAR root (not WEB-INF/classes) so that `java -jar app.war` finds it.
 * Uses only JDK classes so it compiles without Jetty on the classpath; Jetty is
 * loaded reflectively at runtime from WEB-INF/lib/ inside the WAR.
 */
public class Main {
    public static void main(String[] args) throws Exception {
        int port = Integer.parseInt(System.getenv().getOrDefault("PORT", "8080"));

        ProtectionDomain pd = Main.class.getProtectionDomain();
        File warFile = new File(pd.getCodeSource().getLocation().toURI());

        File tmpLibDir = new File(System.getProperty("java.io.tmpdir"),
                "jetty-war-libs-" + System.currentTimeMillis());
        if (!tmpLibDir.mkdirs()) {
            throw new IllegalStateException("Could not create " + tmpLibDir);
        }

        List<URL> libUrls = new ArrayList<>();
        try (JarFile jar = new JarFile(warFile)) {
            Enumeration<JarEntry> entries = jar.entries();
            while (entries.hasMoreElements()) {
                JarEntry e = entries.nextElement();
                String name = e.getName();
                if (e.isDirectory() || !name.startsWith("WEB-INF/lib/") || !name.endsWith(".jar")) {
                    continue;
                }
                File out = new File(tmpLibDir, name.substring("WEB-INF/lib/".length()));
                try (InputStream in = jar.getInputStream(e);
                     FileOutputStream o = new FileOutputStream(out)) {
                    byte[] buf = new byte[8192];
                    int n;
                    while ((n = in.read(buf)) > 0) o.write(buf, 0, n);
                }
                libUrls.add(out.toURI().toURL());
            }
        }

        URLClassLoader cl = new URLClassLoader(
                libUrls.toArray(new URL[0]),
                Main.class.getClassLoader());
        Thread.currentThread().setContextClassLoader(cl);

        Class<?> serverCls  = cl.loadClass("org.eclipse.jetty.server.Server");
        Class<?> webappCls  = cl.loadClass("org.eclipse.jetty.webapp.WebAppContext");
        Class<?> handlerCls = cl.loadClass("org.eclipse.jetty.server.Handler");
        Class<?> configCls  = cl.loadClass("org.eclipse.jetty.webapp.Configuration");
        Class<?> annotConfigCls = cl.loadClass("org.eclipse.jetty.annotations.AnnotationConfiguration");

        Object server = serverCls.getConstructor(int.class).newInstance(port);
        Object webapp = webappCls.getDeclaredConstructor().newInstance();
        webappCls.getMethod("setContextPath", String.class).invoke(webapp, "/");
        webappCls.getMethod("setWar", String.class).invoke(webapp, warFile.getAbsolutePath());
        // Allow JSPs to compile despite the unusual classloader hierarchy.
        webappCls.getMethod("setParentLoaderPriority", boolean.class).invoke(webapp, true);

        // Install the default Jetty configurations plus AnnotationConfiguration.
        // The latter triggers ServletContainerInitializer scanning so apache-jsp's
        // JettyJasperInitializer runs and installs the InstanceManager Jasper needs.
        String[] defaults = (String[]) webappCls.getMethod("getDefaultConfigurationClasses").invoke(webapp);
        String[] withAnnotations = new String[defaults.length + 1];
        System.arraycopy(defaults, 0, withAnnotations, 0, defaults.length);
        withAnnotations[defaults.length] = annotConfigCls.getName();
        webappCls.getMethod("setConfigurationClasses", String[].class)
                 .invoke(webapp, (Object) withAnnotations);

        serverCls.getMethod("setHandler", handlerCls).invoke(server, webapp);
        serverCls.getMethod("start").invoke(server);
        System.out.println("Jetty listening on http://0.0.0.0:" + port + "/");
        serverCls.getMethod("join").invoke(server);
    }
}
