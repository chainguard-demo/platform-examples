const os = require('node:os');
const process = require('node:process');
const express = require('express');
const pc = require('picocolors');

const app = express();

app.get('/', (_req, res) => {
  res.type('html').send(`<!DOCTYPE html>
<html>
<head><title>Chainguard Node Demo</title></head>
<body>
<h1>Hello from Node on Chainguard</h1>
<h2>Runtime info</h2>
<table border="1" cellpadding="4">
  <tr><th>property</th><th>value</th></tr>
  <tr><td>node.version</td><td>${process.version}</td></tr>
  <tr><td>express.version</td><td>${require('express/package.json').version}</td></tr>
  <tr><td>os.platform</td><td>${process.platform}</td></tr>
  <tr><td>os.arch</td><td>${process.arch}</td></tr>
  <tr><td>os.release</td><td>${os.release()}</td></tr>
  <tr><td>HOSTNAME</td><td>${process.env.HOSTNAME || '?'}</td></tr>
</table>
</body>
</html>`);
});

if (require.main === module) {
  const port = parseInt(process.env.PORT || '8080', 10);
  app.listen(port, '0.0.0.0', () => {
    console.log(pc.green(`Listening on http://0.0.0.0:${port}/`));
  });
}

module.exports = app;
