<%@ page contentType="text/html;charset=UTF-8" %>
<!DOCTYPE html>
<html>
<head><title>Chainguard Jetty Demo</title></head>
<body>
<h1>Hello from Jetty on Chainguard</h1>
<h2>Runtime info</h2>
<table border="1" cellpadding="4">
  <tr><th>Property</th><th>Value</th></tr>
  <tr><td>java.version</td><td><%= System.getProperty("java.version") %></td></tr>
  <tr><td>java.vendor</td><td><%= System.getProperty("java.vendor") %></td></tr>
  <tr><td>java.runtime.name</td><td><%= System.getProperty("java.runtime.name") %></td></tr>
  <tr><td>os.name</td><td><%= System.getProperty("os.name") %></td></tr>
  <tr><td>os.arch</td><td><%= System.getProperty("os.arch") %></td></tr>
  <tr><td>servlet container</td><td><%= application.getServerInfo() %></td></tr>
  <tr><td>JAVA_HOME</td><td><%= System.getenv("JAVA_HOME") %></td></tr>
  <tr><td>HOSTNAME</td><td><%= System.getenv("HOSTNAME") %></td></tr>
</table>
</body>
</html>
